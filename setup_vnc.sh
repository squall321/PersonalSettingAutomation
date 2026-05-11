#!/bin/bash
# ============================================================
#  setup_vnc.sh  v4  —  항상 동작하는 VNC 원격 접속 자동화
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS
#
#  두 가지 모드 (기본: 둘 다 설치):
#    [A] x11vnc   — 로그인된 GNOME 세션 미러링 (포트 5900)
#    [B] TigerVNC — 독립 가상 디스플레이 + XFCE (포트 5901)
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
#    --port-tiger P   TigerVNC 포트 (기본: 5901)
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
TIGER_PORT=5901
INSTALL_X11VNC=true
INSTALL_TIGER=true
SKIP_FIREWALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password)    VNC_PASS="$2";        shift 2 ;;
    --port-x11)    X11VNC_PORT="$2";     shift 2 ;;
    --port-tiger)  TIGER_PORT="$2";      shift 2 ;;
    --x11vnc-only) INSTALL_TIGER=false;  shift ;;
    --tiger-only)  INSTALL_X11VNC=false; shift ;;
    --no-firewall) SKIP_FIREWALL=true;   shift ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

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

apt-get $APT_PROXY_OPTS install -y xauth dbus-x11 2>/dev/null || true
success "기본 패키지 완료"

if [[ "$INSTALL_X11VNC" == "true" ]]; then
  apt-get $APT_PROXY_OPTS install -y x11vnc \
    && success "x11vnc 설치 완료" || warn "x11vnc 설치 실패"
fi

if [[ "$INSTALL_TIGER" == "true" ]]; then
  apt-get $APT_PROXY_OPTS install -y \
    tigervnc-standalone-server tigervnc-common \
    && success "TigerVNC 설치 완료" || warn "TigerVNC 설치 실패"
  # GNOME 대신 XFCE: 가상 디스플레이에서 훨씬 안정적
  if ! dpkg -l xfce4 2>/dev/null | grep -q "^ii"; then
    info "XFCE 설치 중 (TigerVNC 가상 디스플레이용)..."
    apt-get $APT_PROXY_OPTS install -y xfce4 xfce4-goodies dbus-x11 \
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
# [B] TigerVNC 독립 서버 — 헤드리스/항상 동작 (포트 5901)
#
#  GNOME보다 XFCE가 가상 디스플레이에서 훨씬 안정적
#  loginctl enable-linger 으로 로그인 없이 부팅 후 자동 시작
# ════════════════════════════════════════════════════════════
if [[ "$INSTALL_TIGER" == "true" ]] && command -v vncserver &>/dev/null; then
  section "[B] TigerVNC 독립 서버 (XFCE 헤드리스, 포트 ${TIGER_PORT})"

  TIGER_DISP="${TIGER_PORT##590}"
  [[ -z "$TIGER_DISP" || "$TIGER_DISP" -le 0 ]] && TIGER_DISP=1

  # xstartup
  cat > "$VNC_DIR/xstartup" << 'STARTEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 0700 "$XDG_RUNTIME_DIR"

[ -x /usr/bin/xsetroot ] && xsetroot -solid grey &

# D-Bus 세션
command -v dbus-launch &>/dev/null && eval "$(dbus-launch --sh-syntax)"

# 데스크톱: XFCE → GNOME → xterm 폴백
if command -v startxfce4 &>/dev/null; then
  exec startxfce4
elif command -v gnome-session &>/dev/null; then
  export LIBGL_ALWAYS_SOFTWARE=1
  exec gnome-session
else
  exec xterm -geometry 80x24+0+0 -ls
fi
STARTEOF
  chmod +x "$VNC_DIR/xstartup"

  # TigerVNC 설정
  cat > "$VNC_DIR/config" << CFGEOF
geometry=1920x1080
depth=24
dpi=96
localhost=no
CFGEOF

  chown -R "$REAL_USER:$REAL_USER" "$VNC_DIR"

  # loginctl enable-linger: 로그인 없이도 user 서비스 실행
  loginctl enable-linger "$REAL_USER" && success "loginctl enable-linger 설정" \
    || warn "enable-linger 실패 — 로그인 후에만 자동 시작"

  # user systemd 서비스
  USER_SD_DIR="$REAL_HOME/.config/systemd/user"
  sudo -u "$REAL_USER" mkdir -p "$USER_SD_DIR"

  # 기존 vncserver 정리
  sudo -u "$REAL_USER" vncserver -kill ":${TIGER_DISP}" 2>/dev/null || true
  rm -f "/tmp/.X${TIGER_DISP}-lock" 2>/dev/null || true

  cat > "${USER_SD_DIR}/tigervnc.service" << TSVC
[Unit]
Description=TigerVNC Standalone VNC Server :${TIGER_DISP} (XFCE headless)
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/vncserver :${TIGER_DISP} -rfbport ${TIGER_PORT} -rfbauth ${PASSWD_FILE} -localhost no
ExecStop=/usr/bin/vncserver -kill :${TIGER_DISP}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
TSVC

  chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config"

  # user 서비스 활성화/시작
  # machinectl shell 이 sudo 컨텍스트에서 user systemd 접근하는 가장 신뢰성 높은 방법
  TIGER_STARTED=false
  if command -v machinectl &>/dev/null; then
    machinectl shell "${REAL_USER}@.host" /bin/bash -c \
      "systemctl --user daemon-reload && \
       systemctl --user enable tigervnc && \
       systemctl --user restart tigervnc" 2>/dev/null \
    && TIGER_STARTED=true && success "TigerVNC user 서비스 시작 (machinectl)"
  fi

  if [[ "$TIGER_STARTED" == "false" ]]; then
    # 폴백: 직접 vncserver 실행
    sudo -u "$REAL_USER" bash -c \
      "XDG_RUNTIME_DIR=/run/user/${REAL_UID} \
       vncserver :${TIGER_DISP} -rfbport ${TIGER_PORT} -rfbauth ${PASSWD_FILE} -localhost no" \
      2>/dev/null \
    && TIGER_STARTED=true && success "TigerVNC 직접 시작 완료 (포트 ${TIGER_PORT})"
  fi

  [[ "$TIGER_STARTED" == "false" ]] && \
    warn "TigerVNC 시작 실패 — 수동: sudo -u ${REAL_USER} vncserver :${TIGER_DISP} -rfbport ${TIGER_PORT} -rfbauth ${PASSWD_FILE} -localhost no"
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

sleep 3
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
[[ "$INSTALL_X11VNC" == "true" ]] && echo "  x11vnc:    sudo systemctl status/restart x11vnc-mirror"
[[ "$INSTALL_X11VNC" == "true" ]] && echo "  x11vnc 로그: sudo tail -f /var/log/x11vnc-${REAL_USER}.log"
[[ "$INSTALL_TIGER"  == "true" ]] && echo "  TigerVNC 시작: sudo -u ${REAL_USER} vncserver :${TIGER_DISP_FINAL} -rfbport ${TIGER_PORT} -rfbauth ${PASSWD_FILE} -localhost no"
[[ "$INSTALL_TIGER"  == "true" ]] && echo "  TigerVNC 중지: sudo -u ${REAL_USER} vncserver -kill :${TIGER_DISP_FINAL}"
echo ""
echo -e "${BOLD}▶ SSH 터널 (보안 접속 권장):${NC}"
[[ "$INSTALL_X11VNC" == "true" ]] && echo "  ssh -L 5900:localhost:${X11VNC_PORT} ${REAL_USER}@<서버IP>  → VNC: localhost:5900"
[[ "$INSTALL_TIGER"  == "true" ]] && echo "  ssh -L 5901:localhost:${TIGER_PORT}  ${REAL_USER}@<서버IP>  → VNC: localhost:5901"
echo ""
