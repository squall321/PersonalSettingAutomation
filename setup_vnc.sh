#!/bin/bash
# ============================================================
#  setup_vnc.sh  v3  —  GNOME 기존 세션 원격 접속 자동화
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS
#
#  방식 선택 (자동):
#    Ubuntu 22.04+ : gnome-remote-desktop (GNOME 내장 RDP/VNC)
#    모든 버전      : x11vnc (현재 켜진 GNOME 화면 :0 미러링)
#
#  ※ TigerVNC 가상 디스플레이 방식 사용 안 함
#     → 이미 실행 중인 GNOME 세션에 그대로 붙는 방식
#
#  사용법:
#    sudo bash setup_vnc.sh [옵션]
#
#  옵션:
#    --port P        VNC 포트 (기본: 5900)
#    --password PWD  VNC 비밀번호 비대화형 지정
#    --x11vnc        gnome-remote-desktop 대신 x11vnc 강제 사용
#    --no-firewall   UFW 설정 건너뜀
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
VNC_PORT=5900
VNC_PASSWORD=""
FORCE_X11VNC=false
SKIP_FIREWALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       VNC_PORT="$2";     shift 2 ;;
    --password)   VNC_PASSWORD="$2"; shift 2 ;;
    --x11vnc)     FORCE_X11VNC=true; shift ;;
    --no-firewall) SKIP_FIREWALL=true; shift ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

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
elif [[ -f /etc/environment ]]; then
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d ' "'); val=$(echo "$val" | tr -d '"')
    case "$key" in
      http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|no_proxy|NO_PROXY)
        export "$key"="$val" ;;
    esac
  done < /etc/environment
fi

APT_PROXY_OPTS=""
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY:-$HTTPS_PROXY} -o Acquire::https::Proxy=${HTTPS_PROXY}"
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY}"
fi

# ════════════════════════════════════════════════════════════
# 방식 결정: gnome-remote-desktop vs x11vnc
# ════════════════════════════════════════════════════════════
section "원격 접속 방식 결정"

USE_GRD=false   # gnome-remote-desktop
USE_X11VNC=false

if [[ "$FORCE_X11VNC" == "true" ]]; then
  USE_X11VNC=true
  info "x11vnc 강제 사용 (--x11vnc 옵션)"
elif [[ "$UBUNTU_MAJOR" -ge 22 ]] && command -v gnome-remote-desktop-daemon &>/dev/null 2>&1 \
     || dpkg -l gnome-remote-desktop 2>/dev/null | grep -q "^ii"; then
  USE_GRD=true
  info "방식: gnome-remote-desktop (Ubuntu ${UBUNTU_VER} 내장)"
else
  USE_X11VNC=true
  info "방식: x11vnc (기존 GNOME 세션 미러링)"
fi

# ════════════════════════════════════════════════════════════
# 현재 X 디스플레이 감지
# ════════════════════════════════════════════════════════════
section "현재 X 디스플레이 감지"

# 사용자의 현재 DISPLAY 찾기
CURRENT_DISPLAY=""
# /proc 에서 해당 유저의 DISPLAY 환경변수 탐색
for pid in $(pgrep -u "$REAL_USER" -x gnome-shell 2>/dev/null \
             || pgrep -u "$REAL_USER" gnome-session 2>/dev/null \
             || pgrep -u "$REAL_USER" Xorg 2>/dev/null \
             || echo ""); do
  [[ -z "$pid" ]] && continue
  disp=$(cat /proc/$pid/environ 2>/dev/null | tr '\0' '\n' | grep '^DISPLAY=' | cut -d= -f2)
  if [[ -n "$disp" ]]; then
    CURRENT_DISPLAY="$disp"
    info "gnome-shell PID=$pid 에서 DISPLAY=$CURRENT_DISPLAY 감지"
    break
  fi
done

# 폴백: :0 시도
if [[ -z "$CURRENT_DISPLAY" ]]; then
  for disp_try in :0 :1 :2; do
    if [[ -S "/tmp/.X11-unix/X${disp_try#:}" ]]; then
      CURRENT_DISPLAY="$disp_try"
      info "소켓으로 DISPLAY=$CURRENT_DISPLAY 감지"
      break
    fi
  done
fi

[[ -z "$CURRENT_DISPLAY" ]] && CURRENT_DISPLAY=":0"
info "사용할 DISPLAY: $CURRENT_DISPLAY"

# XAUTH 파일 찾기
XAUTH_FILE=$(sudo -u "$REAL_USER" bash -c \
  'ls ~/.Xauthority 2>/dev/null \
   || ls /run/user/'"$REAL_UID"'/gdm/Xauthority 2>/dev/null \
   || find /run/user/'"$REAL_UID"' -name "*authority*" 2>/dev/null | head -1 \
   || echo ""')
[[ -z "$XAUTH_FILE" ]] && XAUTH_FILE="$REAL_HOME/.Xauthority"
info "XAUTH 파일: $XAUTH_FILE"

export DEBIAN_FRONTEND=noninteractive

# ════════════════════════════════════════════════════════════
# ── 방식 A: gnome-remote-desktop ─────────────────────────
# ════════════════════════════════════════════════════════════
if [[ "$USE_GRD" == "true" ]]; then
  section "[A] gnome-remote-desktop 설정"

  # 패키지 설치
  apt-get $APT_PROXY_OPTS install -y gnome-remote-desktop 2>/dev/null || true

  # 비밀번호 설정
  if [[ -n "$VNC_PASSWORD" ]]; then
    PASS="$VNC_PASSWORD"
  else
    echo ""
    read -rsp "VNC 비밀번호 입력 (최소 1자): " PASS
    echo ""
  fi

  # gnome-remote-desktop VNC 활성화 (사용자 dconf/gsettings)
  sudo -u "$REAL_USER" bash << GRDEOF
export DBUS_SESSION_BUS_ADDRESS=\$(cat /proc/\$(pgrep -u $REAL_USER gnome-session | head -1)/environ 2>/dev/null | tr '\0' '\n' | grep DBUS_SESSION_BUS_ADDRESS | cut -d= -f2- || echo "")
if [[ -z "\$DBUS_SESSION_BUS_ADDRESS" ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus"
fi

# VNC 활성화
gsettings set org.gnome.desktop.remote-desktop.vnc auth-method 'password' 2>/dev/null || true
gsettings set org.gnome.desktop.remote-desktop.vnc view-only false 2>/dev/null || true

# 비밀번호 설정
if command -v grdctl &>/dev/null; then
  grdctl vnc set-password '${PASS}' 2>/dev/null || true
  grdctl vnc enable 2>/dev/null || true
  echo "[GRD] grdctl 로 VNC 활성화 완료"
fi
GRDEOF

    # gnome-remote-desktop 서비스 활성화 (사용자 systemd)
    sudo -u "$REAL_USER" systemctl --user enable gnome-remote-desktop 2>/dev/null || true
    sudo -u "$REAL_USER" systemctl --user restart gnome-remote-desktop 2>/dev/null || true
    success "gnome-remote-desktop 활성화 완료"
    VNC_PORT=5900

# ════════════════════════════════════════════════════════════
# ── 방식 B: x11vnc ───────────────────────────────────────
# ════════════════════════════════════════════════════════════
elif [[ "$USE_X11VNC" == "true" ]]; then
  section "[B] x11vnc 설치 및 설정"

  # 패키지 설치
  apt-get $APT_PROXY_OPTS update -y
  apt-get $APT_PROXY_OPTS install -y x11vnc xauth
  success "x11vnc 설치 완료"

  # 비밀번호 설정
  X11VNC_PASSWD_DIR="$REAL_HOME/.vnc"
  sudo -u "$REAL_USER" mkdir -p "$X11VNC_PASSWD_DIR"
  chmod 700 "$X11VNC_PASSWD_DIR"
  chown "$REAL_USER:$REAL_USER" "$X11VNC_PASSWD_DIR"

  if [[ -n "$VNC_PASSWORD" ]]; then
    x11vnc -storepasswd "$VNC_PASSWORD" "$X11VNC_PASSWD_DIR/passwd"
    chown "$REAL_USER:$REAL_USER" "$X11VNC_PASSWD_DIR/passwd"
    chmod 600 "$X11VNC_PASSWD_DIR/passwd"
    success "x11vnc 비밀번호 설정 완료 (비대화형)"
  elif [[ -f "$X11VNC_PASSWD_DIR/passwd" ]]; then
    warn "기존 비밀번호 파일 유지: $X11VNC_PASSWD_DIR/passwd"
  else
    info "x11vnc 비밀번호를 입력하세요:"
    sudo -u "$REAL_USER" x11vnc -storepasswd "$X11VNC_PASSWD_DIR/passwd"
    chmod 600 "$X11VNC_PASSWD_DIR/passwd"
    success "x11vnc 비밀번호 설정 완료"
  fi

  # ── systemd 서비스 생성 ──────────────────────────────────
  SERVICE_NAME="x11vnc-${REAL_USER}"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

  # DISPLAY 감지 스크립트 (서비스 시작 시 동적으로 현재 DISPLAY 찾기)
  DETECT_SCRIPT="/usr/local/bin/x11vnc-detect-display-${REAL_USER}.sh"
  cat > "$DETECT_SCRIPT" << DETEOF
#!/bin/bash
# x11vnc 시작 전 현재 DISPLAY 동적 감지
USER_NAME="${REAL_USER}"
USER_ID="${REAL_UID}"
PASSWD_FILE="${X11VNC_PASSWD_DIR}/passwd"
VNC_PORT="${VNC_PORT}"

# DISPLAY 및 XAUTH 자동 감지
DISPLAY_VAL=""
XAUTH_VAL=""

# gnome-shell PID 에서 DISPLAY 찾기
for pid in \$(pgrep -u "\$USER_NAME" gnome-shell 2>/dev/null || pgrep -u "\$USER_NAME" gnome-session 2>/dev/null || pgrep -u "\$USER_NAME" Xorg 2>/dev/null); do
  d=\$(cat /proc/\$pid/environ 2>/dev/null | tr '\0' '\n' | grep '^DISPLAY=' | cut -d= -f2)
  a=\$(cat /proc/\$pid/environ 2>/dev/null | tr '\0' '\n' | grep '^XAUTHORITY=' | cut -d= -f2)
  if [[ -n "\$d" ]]; then
    DISPLAY_VAL="\$d"
    XAUTH_VAL="\$a"
    break
  fi
done

# 폴백
[[ -z "\$DISPLAY_VAL" ]] && DISPLAY_VAL=":0"
[[ -z "\$XAUTH_VAL" ]] && XAUTH_VAL="/home/\${USER_NAME}/.Xauthority"

echo "감지된 DISPLAY=\$DISPLAY_VAL  XAUTHORITY=\$XAUTH_VAL"

exec /usr/bin/x11vnc \\
  -display "\$DISPLAY_VAL" \\
  -auth "\$XAUTH_VAL" \\
  -rfbauth "\$PASSWD_FILE" \\
  -rfbport "\$VNC_PORT" \\
  -forever \\
  -shared \\
  -noxdamage \\
  -repeat \\
  -loop \\
  -o /var/log/x11vnc-\${USER_NAME}.log
DETEOF
  chmod +x "$DETECT_SCRIPT"

  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=x11vnc VNC Server for ${REAL_USER} (GNOME session mirror)
Documentation=man:x11vnc(1)
After=graphical.target network.target
Wants=graphical.target

[Service]
Type=simple
User=${REAL_USER}
# GNOME 세션이 완전히 뜨기까지 대기
ExecStartPre=/bin/sleep 5
ExecStart=${DETECT_SCRIPT}
Restart=on-failure
RestartSec=10
# GNOME 세션 없으면 재시작 계속 시도 (로그인 후 자동 연결)
StartLimitIntervalSec=0

[Install]
WantedBy=graphical.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"

  # 현재 GNOME 세션이 있으면 즉시 시작
  if pgrep -u "$REAL_USER" gnome-shell &>/dev/null || pgrep -u "$REAL_USER" gnome-session &>/dev/null; then
    systemctl restart "${SERVICE_NAME}" \
      && success "${SERVICE_NAME} 시작 완료" \
      || warn "${SERVICE_NAME} 시작 실패 — 로그: journalctl -u ${SERVICE_NAME}"
  else
    warn "현재 GNOME 세션 없음 — 서비스는 등록됨, GNOME 로그인 후 자동 시작됩니다."
  fi
fi

# ════════════════════════════════════════════════════════════
# UFW 방화벽
# ════════════════════════════════════════════════════════════
section "UFW 방화벽 설정"

if [[ "$SKIP_FIREWALL" == "true" ]]; then
  warn "방화벽 설정 건너뜀"
elif command -v ufw &>/dev/null; then
  ufw allow "${VNC_PORT}/tcp" comment "VNC" 2>/dev/null \
    && success "UFW: 포트 ${VNC_PORT}/tcp 오픈" || true
  if ! ufw status 2>/dev/null | grep -qE "22/tcp|OpenSSH"; then
    ufw allow 22/tcp comment "SSH" 2>/dev/null && success "UFW: SSH(22/tcp) 오픈" || true
  fi
  ufw --force enable 2>/dev/null && success "UFW 활성화" || true
else
  apt-get $APT_PROXY_OPTS install -y ufw 2>/dev/null || true
  ufw allow "${VNC_PORT}/tcp" 2>/dev/null || true
  ufw allow 22/tcp 2>/dev/null || true
  ufw --force enable 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════
# 동작 확인
# ════════════════════════════════════════════════════════════
section "동작 확인"

sleep 3
if ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT}"; then
  success "포트 ${VNC_PORT} LISTEN 확인 ✓"
else
  warn "포트 ${VNC_PORT} 아직 LISTEN 안 됨"
  info "확인: ss -tlnp | grep ${VNC_PORT}"
fi

SERVER_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -Ev '^$|^127\.' | head -5 || echo "")

# ════════════════════════════════════════════════════════════
# 완료 안내
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  VNC 원격 접속 설정 완료!                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}  방식: $([ "$USE_GRD" == "true" ] && echo "gnome-remote-desktop (GNOME 내장)" || echo "x11vnc (GNOME 세션 미러링)")${NC}"
echo "  포트: ${VNC_PORT}"
echo ""
if [[ -n "$SERVER_IPS" ]]; then
  echo -e "${BOLD}  VNC 클라이언트 접속 주소:${NC}"
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    echo "    ${ip}:${VNC_PORT}"
  done <<< "$SERVER_IPS"
  echo ""
fi
echo -e "${BOLD}  TigerVNC Viewer 접속 방법:${NC}"
echo "    주소창에 입력:  서버IP:${VNC_PORT}  또는  서버IP::$(( VNC_PORT - 5900 ))"
echo ""
if [[ "$USE_X11VNC" == "true" ]]; then
  echo -e "${BOLD}  서비스 관리:${NC}"
  echo "    상태:   sudo systemctl status ${SERVICE_NAME:-x11vnc}"
  echo "    재시작: sudo systemctl restart ${SERVICE_NAME:-x11vnc}"
  echo "    로그:   sudo tail -f /var/log/x11vnc-${REAL_USER}.log"
fi
echo ""
echo -e "${BOLD}  SSH 터널 (보안 접속):${NC}"
echo "    ssh -L 5901:localhost:${VNC_PORT} ${REAL_USER}@<서버IP>"
echo "    → VNC 클라이언트: localhost:5901"
echo ""
