#!/bin/bash
# ============================================================
#  setup_vnc.sh  v4  —  항상 동작하는 VNC 원격 접속 자동화
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS
#
#  두 가지 모드 (기본: 둘 다 설치):
#    [A] x11vnc   — 로그인된 GNOME 세션 미러링 (포트 5900)
#    [B] TigerVNC — 독립 가상 디스플레이 + XFCE (포트 5905, 디스플레이 :5)
#                   헤드리스/로그인 전에도 항상 접속 가능
#
#  핵심 수정 사항 (v3→v4):
#    - Wayland 강제 비활성화 (x11vnc는 X11 전용)
#    - x11vnc를 root 시스템 서비스로 실행 (XAUTH 문제 해결)
#    - /proc에서 직접 DISPLAY/XAUTHORITY 추출하는 폴링 루프
#    - TigerVNC + XFCE 헤드리스 모드 추가 (항상 동작 보장)
#    - gnome-remote-desktop D-Bus 문제 우회 (삭제)
#
#  사용법:
#    sudo bash setup_vnc.sh [옵션]
#
#  옵션:
#    --password PWD   VNC 비밀번호 비대화형 지정
#    --x11vnc-only    x11vnc 만 설치 (TigerVNC 건너뜀)
#    --tiger-only     TigerVNC 만 설치 (x11vnc 건너뜀)
#    --port-x11 P     x11vnc 포트 (기본: 5900)
#    --port-tiger P   TigerVNC 포트 (기본: 5905 → 디스플레이 :5)
#    --no-firewall    UFW 설정 건너뜀
# ============================================================

set -uo pipefail

# ── 색상 헬퍼 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── 권한 확인 ─────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "sudo 로 실행하세요:  sudo bash $0 $*"

REAL_USER="${SUDO_USER:-$USER}"
[[ "$REAL_USER" == "root" ]] && error "SUDO_USER 가 없습니다. 'sudo bash $0' 형태로 실행하세요."
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_UID=$(id -u "$REAL_USER")

info "대상 사용자: $REAL_USER (UID=$REAL_UID)"
info "홈 디렉토리: $REAL_HOME"

# ── 인수 파싱 ─────────────────────────────────────────────────
VNC_PASS=""
X11VNC_PORT=5900
# 기본 디스플레이를 :5(포트 5905)로 — 로컬 GUI 세션(보통 :0, :1=Xwayland)과 충돌 회피.
# 옛 기본(:1)은 데스크톱 세션 살아있는 환경에서 'server already running' 에러 유발.
TIGER_PORT=5905
INSTALL_X11VNC=true
INSTALL_TIGER=true
SKIP_FIREWALL=false
DESKTOP="gnome"   # gnome | xfce — TigerVNC 안에서 띄울 데스크톱

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password)    VNC_PASS="$2";        shift 2 ;;
    --port-x11)    X11VNC_PORT="$2";     shift 2 ;;
    --port-tiger)  TIGER_PORT="$2";      shift 2 ;;
    --x11vnc-only) INSTALL_TIGER=false;  shift ;;
    --tiger-only)  INSTALL_X11VNC=false; shift ;;
    --no-firewall) SKIP_FIREWALL=true;   shift ;;
    --desktop)     DESKTOP="$2";          shift 2 ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done
case "$DESKTOP" in
  gnome|xfce) ;;
  *) error "--desktop 은 gnome 또는 xfce 만 가능: $DESKTOP" ;;
esac

# 비밀번호가 없으면 대화형으로 받기
if [[ -z "$VNC_PASS" ]]; then
  echo ""
  read -rsp "VNC 비밀번호 입력 (최소 6자): " VNC_PASS
  echo ""
  [[ ${#VNC_PASS} -lt 6 ]] && error "비밀번호는 6자 이상이어야 합니다."
fi

# ── Ubuntu 버전 감지 ──────────────────────────────────────────
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "20.04")
UBUNTU_MAJOR=${UBUNTU_VER%%.*}
info "Ubuntu 버전: ${UBUNTU_VER}"

# ════════════════════════════════════════════════════════════
# 프록시 설정 로드
# ════════════════════════════════════════════════════════════
section "프록시 설정 로드"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_CONFIG="${SCRIPT_DIR}/proxy_config.yaml"

load_proxy_from_yaml() {
  python3 - "$1" << 'PYEOF'
import sys, re
def yaml_get(path, key_path):
    data = {}; section = None
    with open(path) as f:
        for line in f:
            line = line.rstrip()
            if not line or line.lstrip().startswith('#'): continue
            m = re.match(r'^(\w[\w-]*):\s*(.*)', line)
            if m:
                section = m.group(1)
                val = m.group(2).strip().strip('"\'').split('#')[0].strip()
                data[section] = val if val else {}
                continue
            m = re.match(r'^\s{2,}([\w-]+):\s*(.*)', line)
            if m and isinstance(data.get(section), dict):
                data[section][m.group(1)] = m.group(2).strip().strip('"\'').split('#')[0].strip()
    keys = key_path.split('.')
    val = data
    for k in keys:
        val = val.get(k, '') if isinstance(val, dict) else ''
    return val or ''
path = sys.argv[1]
http  = yaml_get(path, 'proxy.http')
https = yaml_get(path, 'proxy.https')
nop   = yaml_get(path, 'proxy.no_proxy')
if http or https:
    print(f"HTTP_PROXY={http}")
    print(f"HTTPS_PROXY={https}")
    print(f"NO_PROXY={nop}")
PYEOF
}

if [[ -f "$YAML_CONFIG" ]] && command -v python3 &>/dev/null; then
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    export "$key"="$val"
    export "${key,,}"="$val"
    info "  $key=$val"
  done < <(load_proxy_from_yaml "$YAML_CONFIG")
fi

APT_PROXY_OPTS=""
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY:-$HTTPS_PROXY} -o Acquire::https::Proxy=${HTTPS_PROXY}"
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY}"
fi

export DEBIAN_FRONTEND=noninteractive

# ════════════════════════════════════════════════════════════
# [0] 기존 VNC 잔여물 정리 — 반복 실행 안전성 (idempotency)
#     서비스 정지 → 좀비 프로세스 kill → lock/socket 삭제 → 권한 복구 → 포트 회수
#     이 단계를 거치면 어떤 더러운 상태에서 시작해도 클린한 셋업 가능
# ════════════════════════════════════════════════════════════
section "[0] 기존 VNC 잔여물 정리"

# 0-1. systemd 서비스 정지 (있을 때만)
for svc in "x11vnc-mirror" "tigervnc-${REAL_USER}"; do
  if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
    if systemctl is-active "$svc" &>/dev/null; then
      systemctl stop "$svc" 2>/dev/null && info "  서비스 정지: $svc" || true
    fi
  fi
done

# 0-2. 사용자 컨텍스트로 vncserver -kill 정상 종료 시도 (있을 때만)
#      "No matching VNC server running" 는 정상 안내 출력 → 통째로 silence
if command -v vncserver &>/dev/null; then
  for d in 1 2 "${TIGER_PORT##590}"; do
    sudo -u "$REAL_USER" vncserver -kill ":${d}" </dev/null >/dev/null 2>&1 || true
  done
fi

# 0-3. 좀비 Xvnc / x11vnc 프로세스 강제 종료 (root 권한)
if pgrep -f 'Xvnc' &>/dev/null; then
  pkill -9 -f 'Xvnc' 2>/dev/null && info "  Xvnc 좀비 프로세스 종료" || true
fi
if pgrep -x x11vnc &>/dev/null; then
  pkill -9 -x x11vnc 2>/dev/null && info "  x11vnc 좀비 프로세스 종료" || true
fi

# 0-4. lock 파일 / X11 소켓 강제 삭제 (root 권한 → /tmp sticky bit 우회)
for d in 1 2 "${TIGER_PORT##590}"; do
  for f in "/tmp/.X${d}-lock" "/tmp/.X11-unix/X${d}"; do
    if [[ -e "$f" ]]; then
      rm -f "$f" 2>/dev/null && info "  잔여 파일 삭제: $f" || \
        warn "  삭제 실패 (chattr +i?): $f"
    fi
  done
done

# 0-5. /tmp/.X11-unix 디렉토리 권한 보장 (1777)
mkdir -p /tmp/.X11-unix 2>/dev/null || true
if [[ "$(stat -c '%a' /tmp/.X11-unix 2>/dev/null)" != "1777" ]]; then
  chown root:root /tmp/.X11-unix 2>/dev/null || true
  chmod 1777 /tmp/.X11-unix 2>/dev/null && info "  /tmp/.X11-unix 권한 → 1777 복구" || \
    warn "  /tmp/.X11-unix chmod 실패 (lsattr -d 로 immutable 확인)"
fi

# 0-6. 점유 포트 강제 회수
for p in "${X11VNC_PORT}" "${TIGER_PORT}"; do
  if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
    fuser -k "${p}/tcp" 2>/dev/null && info "  포트 ${p} 회수" || true
  fi
done

# 0-7. 잔존 PID 파일 청소
rm -f "${REAL_HOME}/.vnc/"*.pid 2>/dev/null || true

sleep 1
success "사전 정리 완료 — 클린한 상태에서 셋업 진행"

# ════════════════════════════════════════════════════════════
# [1] Wayland 비활성화 — x11vnc는 X11 전용
#     Ubuntu 22.04+ 기본이 Wayland → x11vnc 연결 불가
# ════════════════════════════════════════════════════════════
section "[1] Wayland 비활성화 (GDM X11 강제)"

GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "$GDM_CONF" ]]; then
  if grep -q "WaylandEnable" "$GDM_CONF"; then
    sed -i 's/^#*WaylandEnable=.*/WaylandEnable=false/' "$GDM_CONF"
  else
    if grep -q '^\[daemon\]' "$GDM_CONF"; then
      sed -i '/^\[daemon\]/a WaylandEnable=false' "$GDM_CONF"
    else
      printf '\n[daemon]\nWaylandEnable=false\n' >> "$GDM_CONF"
    fi
  fi
  success "GDM Wayland 비활성화 완료 ($GDM_CONF)"
  # ※ GDM restart는 하지 않음 — 현재 GUI 세션을 강제 종료시키기 때문
  #   설정은 다음 로그인(또는 재부팅) 시 자동 적용됨
  # 현재 세션 타입 확인
  CURRENT_SESSION_TYPE=$(loginctl show-session \
    "$(loginctl | awk -v u="$REAL_USER" '$0 ~ u {print $1; exit}')" \
    -p Type --value 2>/dev/null || echo "unknown")
  if [[ "$CURRENT_SESSION_TYPE" == "wayland" ]]; then
    warn "현재 세션: Wayland → 로그아웃 후 재로그인하면 X11로 전환됩니다"
    warn "  (로그인 화면 우하단 ⚙️ 클릭 → 'Ubuntu on Xorg' 선택)"
  else
    success "현재 세션: ${CURRENT_SESSION_TYPE} (X11) — 즉시 적용 가능"
  fi
else
  warn "GDM 설정 파일 없음 — LightDM 등 사용 중이면 X11이 이미 기본값"
fi

# ════════════════════════════════════════════════════════════
# [2] 패키지 설치
# ════════════════════════════════════════════════════════════
section "[2] 필수 패키지 설치"

apt-get $APT_PROXY_OPTS update -y

# ── 공통 기반 패키지 ──────────────────────────────────────
# xauth          : X 인증 쿠키 관리
# dbus-x11       : D-Bus X11 세션 연동 (XFCE 필수)
# x11-xserver-utils : xsetroot, xrandr 등 X 유틸
# xserver-common : Xvnc 공통 파일 (폰트 경로 등)
# xfonts-base    : Xvnc -fp 옵션 폰트 (없으면 X Error 발생)
# xterm          : 최후 폴백 터미널
apt-get $APT_PROXY_OPTS install -y \
  xauth \
  dbus-x11 \
  x11-xserver-utils \
  xserver-common \
  xfonts-base \
  xterm \
  && success "공통 기반 패키지 설치 완료" || warn "일부 공통 패키지 설치 실패"

# ── x11vnc (GNOME 세션 미러링) ────────────────────────────
if [[ "$INSTALL_X11VNC" == "true" ]]; then
  apt-get $APT_PROXY_OPTS install -y \
    x11vnc \
    && success "x11vnc 설치 완료" || warn "x11vnc 설치 실패"
fi

# ── TigerVNC + 데스크톱 (헤드리스 독립 서버) ─────────────
# tigervnc-standalone-server : Xvnc 바이너리 포함
# tigervnc-common            : vncpasswd 등 공통 도구
# 데스크톱은 --desktop 옵션에 따라:
#   gnome → gnome-session (이미 데스크톱 호스트에 설치돼 있을 가능성 높음)
#   xfce  → xfce4 (가상 디스플레이에서 가볍고 안정적)
if [[ "$INSTALL_TIGER" == "true" ]]; then
  apt-get $APT_PROXY_OPTS install -y \
    tigervnc-standalone-server \
    tigervnc-common \
    && success "TigerVNC 설치 완료" || warn "TigerVNC 설치 실패"

  if [[ "$DESKTOP" == "gnome" ]]; then
    apt-get $APT_PROXY_OPTS install -y \
      gnome-session \
      gnome-shell \
      gnome-terminal \
      && success "GNOME 설치 완료" || warn "GNOME 설치 실패 — 이미 설치돼 있을 수 있음"
  else
    apt-get $APT_PROXY_OPTS install -y \
      xfce4 \
      xfce4-goodies \
      xfce4-terminal \
      && success "XFCE 설치 완료" || warn "XFCE 설치 실패 — xterm 폴백 사용"
  fi
fi

# ════════════════════════════════════════════════════════════
# [3] VNC 비밀번호 설정
# ════════════════════════════════════════════════════════════
section "[3] VNC 비밀번호 설정"

VNC_DIR="$REAL_HOME/.vnc"
sudo -u "$REAL_USER" mkdir -p "$VNC_DIR"
chmod 700 "$VNC_DIR"
chown "$REAL_USER:$REAL_USER" "$VNC_DIR"

PASSWD_FILE="$VNC_DIR/passwd"

if command -v x11vnc &>/dev/null; then
  x11vnc -storepasswd "$VNC_PASS" "$PASSWD_FILE" 2>/dev/null
elif command -v vncpasswd &>/dev/null; then
  printf '%s\n%s\n' "$VNC_PASS" "$VNC_PASS" | vncpasswd "$PASSWD_FILE" 2>/dev/null
fi
chown "$REAL_USER:$REAL_USER" "$PASSWD_FILE"
chmod 600 "$PASSWD_FILE"
success "VNC 비밀번호 설정 완료: $PASSWD_FILE"

# ════════════════════════════════════════════════════════════
# [A] x11vnc — 로그인된 GNOME 세션 미러링 (포트 5900)
#
#  v3 문제점:
#   - User= 시스템 서비스는 DISPLAY/XAUTHORITY 환경 없음
#   - sleep 5 만으로는 부족 (세션 없으면 즉시 실패)
#  v4 해결:
#   - root로 실행 → 모든 xauth 파일 직접 읽기 가능
#   - /proc/<pid>/environ 에서 DISPLAY+XAUTHORITY 추출
#   - 폴링 루프: X 세션 나타날 때까지 계속 대기
# ════════════════════════════════════════════════════════════
if [[ "$INSTALL_X11VNC" == "true" ]] && command -v x11vnc &>/dev/null; then
  section "[A] x11vnc 시스템 서비스 (GNOME 세션 미러링, 포트 ${X11VNC_PORT})"

  X11VNC_SERVICE="x11vnc-mirror"
  X11VNC_WRAPPER="/usr/local/bin/x11vnc-start-${REAL_USER}.sh"
  X11VNC_LOG="/var/log/x11vnc-${REAL_USER}.log"

  # 래퍼 스크립트: root 권한으로 X11 세션 감지 후 x11vnc 연결
  cat > "$X11VNC_WRAPPER" << WRAPEOF
#!/bin/bash
# x11vnc 래퍼 — root로 실행, GNOME X11 세션 감지 후 연결

TARGET_USER="${REAL_USER}"
TARGET_UID="${REAL_UID}"
PASSWD_FILE="${PASSWD_FILE}"
VNC_PORT="${X11VNC_PORT}"
LOG_FILE="${X11VNC_LOG}"
MAX_WAIT=600   # 최대 10분 대기
INTERVAL=5

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" | tee -a "\$LOG_FILE"; }

find_x11_session() {
  # gnome-shell / gnome-session / Xorg 프로세스의 environ 에서 추출
  for proc in gnome-shell gnome-session Xorg; do
    for pid in \$(pgrep -u "\$TARGET_USER" "\$proc" 2>/dev/null); do
      [[ ! -r "/proc/\$pid/environ" ]] && continue
      DISP=\$(tr '\0' '\n' < "/proc/\$pid/environ" | grep '^DISPLAY=' | cut -d= -f2-)
      XAUTH=\$(tr '\0' '\n' < "/proc/\$pid/environ" | grep '^XAUTHORITY=' | cut -d= -f2-)
      if [[ -n "\$DISP" && -n "\$XAUTH" && -f "\$XAUTH" ]]; then
        echo "\$DISP|\$XAUTH"
        return 0
      fi
      # XAUTHORITY 없어도 DISPLAY는 있는 경우
      if [[ -n "\$DISP" ]]; then
        # 후보 xauth 파일 시도
        for xauth_try in \
          "/run/user/\${TARGET_UID}/gdm/Xauthority" \
          "/home/\${TARGET_USER}/.Xauthority" \
          "\$(find /run/user/\${TARGET_UID} -name '*authority*' 2>/dev/null | head -1)"; do
          [[ -f "\$xauth_try" ]] || continue
          if DISPLAY="\$DISP" XAUTHORITY="\$xauth_try" xdpyinfo &>/dev/null 2>&1; then
            echo "\$DISP|\$xauth_try"
            return 0
          fi
        done
      fi
    done
  done

  # X 소켓만 있는 경우 (DISPLAY가 직접 안 잡힐 때)
  for disp_num in 0 1 2; do
    [[ -S "/tmp/.X11-unix/X\${disp_num}" ]] || continue
    for xauth_try in \
      "/run/user/\${TARGET_UID}/gdm/Xauthority" \
      "/home/\${TARGET_USER}/.Xauthority"; do
      [[ -f "\$xauth_try" ]] || continue
      if DISPLAY=":\${disp_num}" XAUTHORITY="\$xauth_try" xdpyinfo &>/dev/null 2>&1; then
        echo ":\${disp_num}|\$xauth_try"
        return 0
      fi
    done
  done

  return 1
}

log "x11vnc 래퍼 시작 (사용자: \$TARGET_USER, 포트: \$VNC_PORT)"
WAITED=0

while [[ \$WAITED -lt \$MAX_WAIT ]]; do
  SESSION=\$(find_x11_session)
  if [[ -n "\$SESSION" ]]; then
    DISP=\$(cut -d'|' -f1 <<< "\$SESSION")
    XAUTH=\$(cut -d'|' -f2 <<< "\$SESSION")
    log "X11 세션 발견: DISPLAY=\$DISP XAUTHORITY=\$XAUTH"
    log "x11vnc 시작..."
    /usr/bin/x11vnc \
      -display "\$DISP" \
      -auth "\$XAUTH" \
      -rfbauth "\$PASSWD_FILE" \
      -rfbport "\$VNC_PORT" \
      -forever \
      -shared \
      -noxrecord \
      -noxdamage \
      -noxfixes \
      -repeat \
      -o "\$LOG_FILE"
    log "x11vnc 종료 — 5초 후 재시도..."
    sleep 5
    WAITED=0   # 재연결 시도 시 카운터 리셋
  else
    (( WAITED % 60 == 0 )) && log "X11 세션 대기 중... \${WAITED}초 경과"
    sleep \$INTERVAL
    WAITED=\$(( WAITED + INTERVAL ))
  fi
done

log "최대 대기 시간(\${MAX_WAIT}초) 초과. 서비스 종료."
exit 1
WRAPEOF
  chmod +x "$X11VNC_WRAPPER"

  cat > "/etc/systemd/system/${X11VNC_SERVICE}.service" << SVCEOF
[Unit]
Description=x11vnc VNC Mirror for ${REAL_USER} (GNOME session)
After=graphical.target network.target
Wants=graphical.target

[Service]
Type=simple
User=root
ExecStart=${X11VNC_WRAPPER}
Restart=always
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=graphical.target
SVCEOF

  systemctl daemon-reload
  systemctl enable "${X11VNC_SERVICE}"
  systemctl restart "${X11VNC_SERVICE}" 2>/dev/null || true

  if systemctl is-active "${X11VNC_SERVICE}" &>/dev/null; then
    success "x11vnc 서비스 시작 완료 (포트 ${X11VNC_PORT})"
  else
    warn "x11vnc 서비스 시작됨 (X11 세션 감지 대기 중)"
    info "  상태 확인: systemctl status ${X11VNC_SERVICE}"
  fi
fi

# ════════════════════════════════════════════════════════════
# [B] TigerVNC 독립 서버 — 헤드리스/항상 동작 (기본: 포트 5905 / :5)
#
#  - 시스템 서비스(User=REAL_USER)로 실행 — user systemd/machinectl 불필요
#  - xstartup: dbus-launch로 세션 유지, XFCE exec으로 종료 방지
#  - 가상 디스플레이이므로 Wayland/X11 세션 상태와 무관하게 동작
# ════════════════════════════════════════════════════════════
if [[ "$INSTALL_TIGER" == "true" ]] && command -v vncserver &>/dev/null; then
  section "[B] TigerVNC 독립 서버 (XFCE 헤드리스, 포트 ${TIGER_PORT})"

  TIGER_DISP="${TIGER_PORT##590}"
  [[ -z "$TIGER_DISP" || "$TIGER_DISP" -le 0 ]] && TIGER_DISP=1

  # ── 빈 디스플레이 자동 선택 ──────────────────────────────
  # /tmp/.X11-unix/X{N} 이 살아있는 X 서버(Xwayland, Xorg 등)에 의해
  # 점유 중이면 우리가 rm 해도 즉시 다시 만들어짐 → 다음 번호로 우회.
  # 최대 10번까지 시도 (:1 → :2 → ... → :10).
  ORIG_DISP="$TIGER_DISP"
  attempts=0
  while (( attempts < 10 )); do
    # 한번 더 청소 시도
    rm -f "/tmp/.X${TIGER_DISP}-lock" "/tmp/.X11-unix/X${TIGER_DISP}" 2>/dev/null
    sleep 0.3
    if [[ ! -e "/tmp/.X${TIGER_DISP}-lock" && ! -e "/tmp/.X11-unix/X${TIGER_DISP}" ]]; then
      # 비어있음 — 사용 가능
      break
    fi
    # 점유자 확인
    HOLDER=$(lsof "/tmp/.X11-unix/X${TIGER_DISP}" 2>/dev/null | awk 'NR==2{print $1"(PID "$2")"}')
    warn "디스플레이 :${TIGER_DISP} 이미 점유 중 (${HOLDER:-unknown}) — 다음 번호 시도"
    TIGER_DISP=$((TIGER_DISP + 1))
    TIGER_PORT=$((5900 + TIGER_DISP))
    attempts=$((attempts + 1))
  done
  if [[ "$TIGER_DISP" != "$ORIG_DISP" ]]; then
    warn "원래 요청 :${ORIG_DISP} → 빈 :${TIGER_DISP} (포트 ${TIGER_PORT}) 로 자동 변경"
  else
    info "TigerVNC 디스플레이: :${TIGER_DISP} (포트 ${TIGER_PORT})"
  fi

  # ── ~/.vnc/xstartup (데스크톱 명시 실행) ─────────────────
  # session= 옵션은 TigerVNC 1.11+ 에서만 지원 → 버전 의존성 회피 위해
  # 명시적 xstartup 사용. 시스템 기본(Xtigervnc-session→GNOME) 폴백 방지.
  if [[ "$DESKTOP" == "gnome" ]]; then
    cat > "$VNC_DIR/xstartup" << 'XSEOF'
#!/bin/sh
# GNOME session inside Xvnc (X11 forced — GNOME 의 Wayland 분기 회피)
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME
export XDG_SESSION_DESKTOP=gnome
export GDK_BACKEND=x11
# GPU 가속 없는 VNC 환경 — Mutter 가 죽지 않도록 소프트웨어 렌더링 강제
export LIBGL_ALWAYS_SOFTWARE=1
export MUTTER_DEBUG_DISABLE_HW_CURSOR=1
# Ubuntu 의 X11 GNOME 세션 파일 우선순위로 시도
for s in ubuntu-xorg ubuntu gnome-xorg gnome; do
  [ -f "/usr/share/gnome-session/sessions/${s}.session" ] || continue
  if command -v dbus-launch >/dev/null 2>&1; then
    exec dbus-launch --exit-with-session gnome-session --session="$s"
  else
    exec gnome-session --session="$s"
  fi
done
# fallback: 세션명 없이 기본 시작
if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session gnome-session
else
  exec gnome-session
fi
XSEOF
  else
    cat > "$VNC_DIR/xstartup" << 'XSEOF'
#!/bin/sh
# XFCE session inside Xvnc
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session startxfce4
else
  exec startxfce4
fi
XSEOF
  fi
  chmod 755 "$VNC_DIR/xstartup"
  chown "$REAL_USER:$REAL_USER" "$VNC_DIR/xstartup"
  info "xstartup: ${DESKTOP} 데스크톱으로 설정"

  # ── ~/.vnc/config (vncserver 옵션) ──────────────────────
  # session= 제거 (xstartup 사용)
  # SecurityTypes=VncAuth : Ubuntu 22.04+ TLS 기본값 우회
  cat > "$VNC_DIR/config" << CFGEOF
geometry=1920x1080
depth=24
localhost=no
rfbport=${TIGER_PORT}
SecurityTypes=VncAuth
CFGEOF
  chown "$REAL_USER:$REAL_USER" "$VNC_DIR/config"

  # ── 잔여 인스턴스 정리 ──────────────────────────────────
  sudo -u "$REAL_USER" vncserver -kill ":${TIGER_DISP}" 2>/dev/null || true
  rm -f "/tmp/.X${TIGER_DISP}-lock" "/tmp/.X11-unix/X${TIGER_DISP}" 2>/dev/null || true
  # /tmp/.X11-unix 는 보통 이미 존재 — root여도 immutable/AppArmor로 막힐 수 있어 관대하게
  mkdir -p /tmp/.X11-unix 2>/dev/null || true
  chmod 1777 /tmp/.X11-unix 2>/dev/null || true
  sleep 1

  TIGER_SERVICE="tigervnc-${REAL_USER}"

  # ── 시스템 서비스 ────────────────────────────────────────
  # -fg 는 vncserver(perl)가 fork 하지 않고 Xvnc로 exec → foreground 모드
  # 따라서 systemd Type 은 반드시 'simple' (forking 으로 두면 fork 신호를
  # 기다리다 timeout → 서비스가 영원히 activating 상태에서 실패함).
  # 같은 이유로 PIDFile 불필요 — systemd가 main PID 직접 추적.
  cat > "/etc/systemd/system/${TIGER_SERVICE}.service" << TSVC
[Unit]
Description=TigerVNC Server for ${REAL_USER} (:${TIGER_DISP}, port ${TIGER_PORT})
After=network.target syslog.target

[Service]
Type=simple
User=${REAL_USER}
Group=${REAL_USER}
WorkingDirectory=${REAL_HOME}
Environment=HOME=${REAL_HOME}
Environment=USER=${REAL_USER}
Environment=SHELL=/bin/bash
Environment=XDG_RUNTIME_DIR=/run/user/${REAL_UID}
ExecStartPre=-/usr/bin/vncserver -kill :${TIGER_DISP}
# '+' 접두사 = User= 무시하고 root 로 실행. /tmp 의 sticky bit 때문에
# 일반유저는 자기가 만들지 않은 lock/socket 을 지울 수 없음 (이전 실패
# 시도의 흔적이 남아있으면 'Cannot establish any listening sockets' 에러).
# 또한 좀비 Xvnc 가 :${TIGER_DISP} 잡고 있을 수도 있어 같이 정리.
ExecStartPre=+/bin/bash -c 'pkill -9 -f "Xvnc.*:${TIGER_DISP}( |$)" 2>/dev/null; rm -f /tmp/.X${TIGER_DISP}-lock /tmp/.X11-unix/X${TIGER_DISP} 2>/dev/null; true'
ExecStart=/usr/bin/vncserver -fg :${TIGER_DISP} -geometry 1920x1080 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :${TIGER_DISP}
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
TSVC

  # XDG_RUNTIME_DIR 사전 생성 (부팅 직후 없을 수 있음)
  mkdir -p "/run/user/${REAL_UID}"
  chown "${REAL_USER}:${REAL_USER}" "/run/user/${REAL_UID}"
  chmod 700 "/run/user/${REAL_UID}"

  systemctl daemon-reload
  systemctl enable "${TIGER_SERVICE}"
  systemctl restart "${TIGER_SERVICE}" \
    && success "TigerVNC 서비스 시작 완료 (포트 ${TIGER_PORT})" \
    || warn "TigerVNC 시작 실패 — 로그: journalctl -u ${TIGER_SERVICE} -n 30 --no-pager"
fi

# ════════════════════════════════════════════════════════════
# UFW 방화벽
# ════════════════════════════════════════════════════════════
section "UFW 방화벽 설정"

if [[ "$SKIP_FIREWALL" == "true" ]]; then
  warn "방화벽 설정 건너뜀"
else
  apt-get $APT_PROXY_OPTS install -y ufw 2>/dev/null || true
  [[ "$INSTALL_X11VNC" == "true" ]] && \
    ufw allow "${X11VNC_PORT}/tcp" comment "VNC-x11vnc"  2>/dev/null || true
  [[ "$INSTALL_TIGER"  == "true" ]] && \
    ufw allow "${TIGER_PORT}/tcp"  comment "VNC-TigerVNC" 2>/dev/null || true
  ufw allow 22/tcp comment "SSH" 2>/dev/null || true
  ufw --force enable 2>/dev/null && success "UFW 활성화" || true
fi

# ════════════════════════════════════════════════════════════
# 동작 확인
# ════════════════════════════════════════════════════════════
section "동작 확인"

sleep 10
if [[ "$INSTALL_X11VNC" == "true" ]]; then
  if ss -tlnp 2>/dev/null | grep -q ":${X11VNC_PORT}"; then
    success "x11vnc 포트 ${X11VNC_PORT} LISTEN ✓"
  else
    warn "x11vnc 포트 ${X11VNC_PORT} 아직 LISTEN 안 됨 — X11 세션 대기 중 (정상)"
  fi
fi
if [[ "$INSTALL_TIGER" == "true" ]]; then
  if ss -tlnp 2>/dev/null | grep -q ":${TIGER_PORT}"; then
    success "TigerVNC 포트 ${TIGER_PORT} LISTEN ✓"
  else
    warn "TigerVNC 포트 ${TIGER_PORT} LISTEN 안 됨"
  fi
fi

SERVER_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -Ev '^$|^127\.' | head -5 || echo "")
TIGER_DISP_FINAL="${TIGER_PORT##590}"
[[ -z "$TIGER_DISP_FINAL" || "$TIGER_DISP_FINAL" -le 0 ]] && TIGER_DISP_FINAL=1

# ════════════════════════════════════════════════════════════
# 완료 안내
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  VNC 원격 접속 설정 완료 (v4)                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}▶ 접속 주소:${NC}"
while read -r ip; do
  [[ -z "$ip" ]] && continue
  [[ "$INSTALL_X11VNC" == "true" ]] && \
    echo -e "  ${CYAN}[A] GNOME 미러  (x11vnc)${NC}   →  ${ip}:${X11VNC_PORT}  (GNOME 로그인 후 활성화)"
  [[ "$INSTALL_TIGER"  == "true" ]] && \
    echo -e "  ${CYAN}[B] XFCE 헤드리스 (TigerVNC)${NC} →  ${ip}:${TIGER_PORT}  (항상 동작)"
done <<< "$SERVER_IPS"
echo ""

echo -e "${BOLD}▶ 서비스 관리:${NC}"
[[ "$INSTALL_X11VNC" == "true" ]] && echo "  x11vnc:      sudo systemctl status/restart x11vnc-mirror"
[[ "$INSTALL_X11VNC" == "true" ]] && echo "  x11vnc 로그: sudo tail -f /var/log/x11vnc-${REAL_USER}.log"
[[ "$INSTALL_TIGER"  == "true" ]] && echo "  TigerVNC:    sudo systemctl status/restart tigervnc-${REAL_USER}"
[[ "$INSTALL_TIGER"  == "true" ]] && echo "  TigerVNC 로그: journalctl -u tigervnc-${REAL_USER} -f"
echo ""
echo -e "${BOLD}▶ SSH 터널 (보안 접속 권장):${NC}"
[[ "$INSTALL_X11VNC" == "true" ]] && echo "  ssh -L 5900:localhost:${X11VNC_PORT} ${REAL_USER}@<서버IP>  → VNC: localhost:5900"
[[ "$INSTALL_TIGER"  == "true" ]] && echo "  ssh -L ${TIGER_PORT}:localhost:${TIGER_PORT} ${REAL_USER}@<서버IP>  → VNC: localhost:${TIGER_PORT}"
echo ""
