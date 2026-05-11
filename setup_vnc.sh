#!/bin/bash
# ============================================================
#  setup_vnc.sh  v2  —  Ubuntu GNOME VNC 완전 자동화
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS
#
#  핵심 설계 원칙:
#   - GNOME + TigerVNC 에 특화된 신뢰성 있는 설정
#   - Wayland 충돌 완전 차단 (XDG_SESSION_TYPE=x11 강제)
#   - GPU 없는 VNC 환경에서도 gnome-shell 정상 동작 (소프트웨어 렌더링)
#   - stale lock / PID 파일 자동 정리
#   - gnome-initial-setup 차단 (VNC 세션 블로킹 방지)
#   - systemd 서비스: 전용 서비스 (템플릿 User=%i 버그 없음)
#   - 부팅 후 자동 시작
#
#  사용법:
#    sudo bash setup_vnc.sh [옵션]
#
#  옵션:
#    --display N     VNC 디스플레이 번호 (기본: 1 → 포트 5901)
#    --geometry WxH  해상도 (기본: 1920x1080)
#    --depth D       색 깊이 (기본: 24)
#    --password PWD  VNC 비밀번호 비대화형 지정
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
REAL_GROUP=$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")
[[ -z "$REAL_HOME" ]] && error "사용자 '$REAL_USER' 의 홈 디렉토리를 찾을 수 없습니다."

info "대상 사용자 : $REAL_USER"
info "홈 디렉토리 : $REAL_HOME"

# ── 인수 파싱 ─────────────────────────────────────────────────
VNC_DISPLAY=1
VNC_GEOMETRY="1920x1080"
VNC_DEPTH=24
VNC_PASSWORD=""
SKIP_FIREWALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --display)    VNC_DISPLAY="$2";  shift 2 ;;
    --geometry)   VNC_GEOMETRY="$2"; shift 2 ;;
    --depth)      VNC_DEPTH="$2";    shift 2 ;;
    --password)   VNC_PASSWORD="$2"; shift 2 ;;
    --no-firewall) SKIP_FIREWALL=true; shift ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

VNC_PORT=$((5900 + VNC_DISPLAY))
SERVER_HOSTNAME=$(hostname)
VNC_PASSWD_DIR="$REAL_HOME/.vnc"
SERVICE_NAME="vncserver-gnome-${REAL_USER}@${VNC_DISPLAY}"

info "VNC 디스플레이 : :${VNC_DISPLAY}  (포트 ${VNC_PORT})"
info "해상도         : ${VNC_GEOMETRY}"
info "색 깊이        : ${VNC_DEPTH}bit"
info "서비스 이름    : ${SERVICE_NAME}"

# ── Ubuntu 버전 감지 ──────────────────────────────────────────
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "22.04")
UBUNTU_MAJOR=${UBUNTU_VER%%.*}
info "Ubuntu 버전    : ${UBUNTU_VER}"

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
  info "proxy_config.yaml 에서 프록시 로드 중"
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    export "$key"="$val"
    export "${key,,}"="$val"
    info "  $key=$val"
  done < <(load_proxy_from_yaml "$YAML_CONFIG")
elif [[ -f /etc/environment ]]; then
  info "/etc/environment 에서 프록시 로드 중"
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d ' "'); val=$(echo "$val" | tr -d '"')
    case "$key" in
      http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|no_proxy|NO_PROXY)
        export "$key"="$val" ;;
    esac
  done < /etc/environment
  [[ -n "${HTTP_PROXY:-}" ]] && info "프록시 감지: $HTTP_PROXY"
else
  info "프록시 설정 없음"
fi

APT_PROXY_OPTS=""
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY:-$HTTPS_PROXY} -o Acquire::https::Proxy=${HTTPS_PROXY}"
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY}"
fi

# ════════════════════════════════════════════════════════════
# [1] 패키지 설치 — GNOME + TigerVNC
# ════════════════════════════════════════════════════════════
section "[1] 패키지 설치"

export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY_OPTS update -y

# ── TigerVNC ───────────────────────────────────────────────
info "TigerVNC 설치 중..."
apt-get $APT_PROXY_OPTS install -y \
  tigervnc-standalone-server \
  tigervnc-common \
  xauth \
  xfonts-base \
  dbus-x11
success "TigerVNC 설치 완료"

# ── GNOME 필수 패키지 ────────────────────────────────────────
info "GNOME 필수 패키지 설치 중..."
apt-get $APT_PROXY_OPTS install -y \
  gnome-session \
  gnome-shell \
  gnome-shell-extensions \
  gnome-settings-daemon \
  gnome-control-center \
  gnome-terminal \
  gnome-tweaks \
  nautilus \
  adwaita-icon-theme-full \
  fonts-cantarell \
  fonts-noto-core \
  at-spi2-core \
  glib-networking \
  gsettings-desktop-schemas
success "GNOME 필수 패키지 설치 완료"

# ── 소프트웨어 렌더링 (VNC = GPU 없음, gnome-shell 크래시 방지) ──
info "소프트웨어 렌더링 라이브러리 설치 중..."
apt-get $APT_PROXY_OPTS install -y \
  libgl1-mesa-dri \
  libgl1-mesa-glx \
  mesa-utils 2>/dev/null \
  || apt-get $APT_PROXY_OPTS install -y libgl1-mesa-dri mesa-utils || true
success "Mesa 소프트웨어 렌더링 설치 완료"

# ── Ubuntu 테마 (설치 가능한 경우만) ────────────────────────────
if apt-cache show yaru-theme-gnome-shell &>/dev/null 2>&1; then
  apt-get $APT_PROXY_OPTS install -y \
    yaru-theme-gnome-shell \
    yaru-theme-gtk \
    yaru-theme-icon 2>/dev/null || true
  info "Yaru 테마 설치 완료"
fi

# ── 방화벽 ────────────────────────────────────────────────────
apt-get $APT_PROXY_OPTS install -y ufw 2>/dev/null || true

success "모든 패키지 설치 완료"

# ── vncserver 경로 확인 ─────────────────────────────────────────
VNCSERVER_BIN=$(command -v vncserver 2>/dev/null || echo "")
[[ -z "$VNCSERVER_BIN" ]] && error "vncserver 바이너리를 찾을 수 없습니다. TigerVNC 설치를 확인하세요."
info "vncserver 경로: $VNCSERVER_BIN"

# ════════════════════════════════════════════════════════════
# [2] GNOME 초기 설정 차단 (VNC 세션 블로킹 방지)
# ════════════════════════════════════════════════════════════
section "[2] GNOME 초기 설정 차단"

# gnome-initial-setup 이 VNC 세션에서 전체 화면을 잡아 조작 불가 상태 방지
sudo -u "$REAL_USER" bash << GNOMEINIT
mkdir -p "\$HOME/.config"
touch "\$HOME/.config/gnome-initial-setup-done"
# GNOME Tour 팝업 비활성화
if command -v gsettings &>/dev/null; then
  GNOME_VER=\$(gnome-shell --version 2>/dev/null | awk '{print \$3}' || echo "")
  if [[ -n "\$GNOME_VER" ]]; then
    gsettings set org.gnome.shell welcome-dialog-last-shown-version "\$GNOME_VER" 2>/dev/null || true
  fi
fi
# 자동 잠금 / 화면보호기 비활성화 (VNC 세션에서 화면 잠김 방지)
gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
GNOMEINIT

success "GNOME 초기 설정 차단 완료"

# ════════════════════════════════════════════════════════════
# [3] VNC 비밀번호 설정
# ════════════════════════════════════════════════════════════
section "[3] VNC 비밀번호 설정"

sudo -u "$REAL_USER" mkdir -p "$VNC_PASSWD_DIR"
chmod 700 "$VNC_PASSWD_DIR"
chown "$REAL_USER:$REAL_GROUP" "$VNC_PASSWD_DIR"

if [[ -n "$VNC_PASSWORD" ]]; then
  # 비대화형: --password 인수 사용
  if echo "$VNC_PASSWORD" | sudo -u "$REAL_USER" vncpasswd -f > "$VNC_PASSWD_DIR/passwd" 2>/dev/null; then
    chmod 600 "$VNC_PASSWD_DIR/passwd"
    chown "$REAL_USER:$REAL_GROUP" "$VNC_PASSWD_DIR/passwd"
    success "VNC 비밀번호 설정 완료 (인수 사용)"
  else
    error "vncpasswd 실패"
  fi
elif [[ -f "$VNC_PASSWD_DIR/passwd" ]]; then
  warn "기존 VNC 비밀번호 파일 유지: $VNC_PASSWD_DIR/passwd"
  warn "변경하려면: sudo -u $REAL_USER vncpasswd"
else
  info "VNC 비밀번호를 입력하세요 (최소 6자):"
  if sudo -u "$REAL_USER" vncpasswd; then
    # vncpasswd 기본 저장 위치 확인 및 이동
    if [[ -f "$REAL_HOME/.vnc/passwd" ]]; then
      chmod 600 "$REAL_HOME/.vnc/passwd"
      chown "$REAL_USER:$REAL_GROUP" "$REAL_HOME/.vnc/passwd"
      success "VNC 비밀번호 설정 완료"
    fi
  else
    error "VNC 비밀번호 설정 실패"
  fi
fi

[[ -f "$VNC_PASSWD_DIR/passwd" ]] || error "VNC 비밀번호 파일이 없습니다: $VNC_PASSWD_DIR/passwd"

# ════════════════════════════════════════════════════════════
# [4] GNOME 전용 xstartup 작성
# ════════════════════════════════════════════════════════════
section "[4] xstartup 작성 (GNOME 최적화)"

XSTARTUP="$VNC_PASSWD_DIR/xstartup"

# gnome-session 에 사용할 세션 파일 감지
#  Ubuntu: /usr/share/gnome-session/sessions/ubuntu.session (우선)
#  순수 GNOME: gnome.session, gnome-classic.session 등
detect_gnome_session() {
  local session_dir="/usr/share/gnome-session/sessions"
  for sess in ubuntu ubuntu-xorg gnome gnome-flashback-metacity gnome-classic; do
    if [[ -f "${session_dir}/${sess}.session" ]]; then
      echo "$sess"
      return
    fi
  done
  echo ""
}
GNOME_SESSION_NAME=$(detect_gnome_session)
if [[ -n "$GNOME_SESSION_NAME" ]]; then
  GNOME_SESSION_ARG="--session=${GNOME_SESSION_NAME}"
  info "GNOME 세션 파일 감지: ${GNOME_SESSION_NAME}.session"
else
  GNOME_SESSION_ARG=""
  warn "gnome-session 파일 미감지 — 기본값으로 시작"
fi

# Ubuntu 버전별 XDG_DATA_DIRS 설정
if [[ "$UBUNTU_MAJOR" -ge 20 ]]; then
  XDG_DATA_DIRS_VAL="/usr/share/ubuntu:/usr/local/share:/usr/share:/var/lib/snapd/desktop"
else
  XDG_DATA_DIRS_VAL="/usr/local/share:/usr/share"
fi

cat > "$XSTARTUP" << XEOF
#!/bin/bash
# ================================================================
# VNC xstartup — GNOME 전용  (자동 생성: setup_vnc.sh v2)
# ================================================================

# ── 이전 세션 변수 초기화 ─────────────────────────────────────
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# ── 핵심: X11 강제 (Wayland 완전 차단) ──────────────────────────
# Wayland 시도 시 gnome-shell 즉시 크래시 — X11 고정 필수
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
export CLUTTER_BACKEND=x11

# ── GNOME Ubuntu 세션 환경 ────────────────────────────────────
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export DESKTOP_SESSION=ubuntu
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
export XDG_DATA_DIRS=${XDG_DATA_DIRS_VAL}

# ── 소프트웨어 렌더링 (VNC = GPU 없음) ───────────────────────
# GPU 없이 gnome-shell 이 정상 동작하려면 llvmpipe 필수
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export MESA_GL_VERSION_OVERRIDE=4.5COMPAT

# ── gnome-keyring SSH 에이전트 비활성화 (VNC hang 방지) ──────
# VNC 세션에서 gnome-keyring이 패스워드를 요구해 hang 발생 가능
export GNOME_KEYRING_CONTROL=""
export SSH_AUTH_SOCK=""

# ── 언어/로케일 ───────────────────────────────────────────────
export LANG=\${LANG:-ko_KR.UTF-8}
export LANGUAGE=\${LANGUAGE:-ko_KR:ko:en_US:en}
export LC_ALL=\${LC_ALL:-}

# ── X 환경 초기화 ─────────────────────────────────────────────
[ -r "\$HOME/.Xresources" ] && xrdb -merge "\$HOME/.Xresources" 2>/dev/null || true
xsetroot -solid '#2E3440' 2>/dev/null || true

# ── at-spi2 접근성 버스 (gnome-session 의존성) ────────────────
/usr/libexec/at-spi-bus-launcher --launch-immediately 2>/dev/null &
sleep 0.5

# ── GNOME 세션 시작 ───────────────────────────────────────────
# dbus-launch: VNC 세션 전용 D-Bus 데몬 생성
# --exit-with-session: 세션 종료 시 D-Bus 데몬도 자동 종료
exec dbus-launch --exit-with-session \
  /usr/bin/gnome-session ${GNOME_SESSION_ARG}
XEOF

chmod +x "$XSTARTUP"
chown "$REAL_USER:$REAL_GROUP" "$XSTARTUP"
success "xstartup 작성 완료: $XSTARTUP"

# ── 기존 xstartup 백업 메시지 ────────────────────────────────
info "내용 미리보기:"
cat "$XSTARTUP" | sed 's/^/    /'

# ════════════════════════════════════════════════════════════
# [5] systemd 서비스 등록 (전용 서비스 — 템플릿 버그 없음)
# ════════════════════════════════════════════════════════════
section "[5] systemd 서비스 등록"

# 전용 서비스 파일 경로
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PID_FILE="${VNC_PASSWD_DIR}/${SERVER_HOSTNAME}:${VNC_DISPLAY}.pid"
LOG_FILE="${VNC_PASSWD_DIR}/${SERVER_HOSTNAME}:${VNC_DISPLAY}.log"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=TigerVNC GNOME Server for ${REAL_USER} on display :${VNC_DISPLAY}
Documentation=man:vncserver(1)
After=syslog.target network.target

[Service]
Type=forking
User=${REAL_USER}
Group=${REAL_GROUP}
WorkingDirectory=${REAL_HOME}

# PIDFile: vncserver 가 생성하는 실제 경로 (hostname:display.pid)
PIDFile=${PID_FILE}

# ── 시작 전 정리 [1]: root 권한으로 /tmp 잠금 파일 삭제 ────────
# User= 권한(일반유저)으로는 root 소유 /tmp/.X?-lock 삭제 불가
# → PermissionsStartOnly 없이 root로 실행하려면 별도 ExecStartPre 사용
ExecStartPre=/bin/bash -c '\
  rm -f /tmp/.X${VNC_DISPLAY}-lock; \
  rm -f /tmp/.X11-unix/X${VNC_DISPLAY}'

# ── 시작 전 정리 [2]: 사용자 권한으로 기존 vncserver 종료 ──────
ExecStartPre=/bin/su - ${REAL_USER} -c '\
  /usr/bin/vncserver -kill :${VNC_DISPLAY} >/dev/null 2>&1 || true; \
  rm -f ${VNC_PASSWD_DIR}/*:${VNC_DISPLAY}.pid; \
  sleep 1'

ExecStart=/usr/bin/vncserver :${VNC_DISPLAY} \
  -geometry ${VNC_GEOMETRY} \
  -depth ${VNC_DEPTH} \
  -localhost no \
  -SecurityTypes VncAuth \
  -rfbauth ${VNC_PASSWD_DIR}/passwd \
  -log "*:stderr:30"

ExecStop=/bin/bash -c '\
  /usr/bin/vncserver -kill :${VNC_DISPLAY} >/dev/null 2>&1 || true; \
  rm -f /tmp/.X${VNC_DISPLAY}-lock; \
  rm -f /tmp/.X11-unix/X${VNC_DISPLAY}'

# ── 비정상 종료 시 자동 재시작 (10초 후) ──────────────────────
Restart=on-failure
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

success "서비스 파일 작성 완료: $SERVICE_FILE"

systemctl daemon-reload

# ── STEP A: 기존 서비스/프로세스 완전 종료 ───────────────────
info "기존 VNC 프로세스 정리 중..."
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
# 서비스 stop 후 프로세스가 남아있으면 강제 kill
if pgrep -u "$REAL_USER" -f "Xtigervnc.*:${VNC_DISPLAY}" &>/dev/null; then
  pkill -u "$REAL_USER" -f "Xtigervnc.*:${VNC_DISPLAY}" 2>/dev/null || true
  sleep 1
fi
if pgrep -u "$REAL_USER" -f "vncserver.*:${VNC_DISPLAY}" &>/dev/null; then
  pkill -u "$REAL_USER" -f "vncserver.*:${VNC_DISPLAY}" 2>/dev/null || true
  sleep 1
fi

# ── STEP B: root 권한으로 stale lock 파일 완전 삭제 ──────────
# /tmp/.X?-lock 은 root 소유인 경우 있어 반드시 root가 삭제
info "stale X 잠금 파일 정리 중 (root)..."
rm -fv /tmp/.X${VNC_DISPLAY}-lock 2>/dev/null || true
rm -fv /tmp/.X11-unix/X${VNC_DISPLAY} 2>/dev/null || true
rm -fv "${VNC_PASSWD_DIR}"/*:${VNC_DISPLAY}.pid 2>/dev/null || true
success "stale 잠금 파일 정리 완료"

# ── STEP C: 일반 사용자로 직접 vncserver 시작 테스트 ────────
# systemd 서비스 전에 직접 실행해 xstartup/GNOME 오류를 빠르게 감지
info "일반 사용자($REAL_USER)로 vncserver :${VNC_DISPLAY} 시작 중..."
if sudo -u "$REAL_USER" /usr/bin/vncserver :${VNC_DISPLAY} \
    -geometry ${VNC_GEOMETRY} \
    -depth ${VNC_DEPTH} \
    -localhost no \
    -SecurityTypes VncAuth \
    -rfbauth ${VNC_PASSWD_DIR}/passwd \
    -log "*:stderr:30" 2>/tmp/vnc_start_test.log; then
  success "vncserver :${VNC_DISPLAY} 시작 성공"
else
  warn "vncserver 직접 시작 실패 — 로그:"
  cat /tmp/vnc_start_test.log | sed 's/^/    /' || true
  warn "서비스 방식으로 계속 진행합니다."
fi

# ── STEP D: systemd 서비스 등록 및 자동시작 활성화 ──────────
systemctl enable "${SERVICE_NAME}" \
  && success "${SERVICE_NAME} 자동시작 등록 완료" \
  || warn "${SERVICE_NAME} enable 실패"

# 이미 직접 시작했으면 서비스는 상태만 확인 (중복 시작 방지)
SVC_ACTIVE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "inactive")
if [[ "$SVC_ACTIVE" != "active" ]]; then
  systemctl start "${SERVICE_NAME}" 2>/dev/null \
    && success "${SERVICE_NAME} systemd 서비스 시작 완료" \
    || {
      warn "${SERVICE_NAME} systemd 시작 실패 — 로그:"
      journalctl -u "${SERVICE_NAME}" --no-pager -n 20 2>/dev/null || true
    }
else
  success "${SERVICE_NAME} 실행 중 (직접 시작됨 — 재부팅 시 systemd 자동시작)"
fi

# ════════════════════════════════════════════════════════════
# [6] UFW 방화벽 설정
# ════════════════════════════════════════════════════════════
section "[6] UFW 방화벽 설정"

if [[ "$SKIP_FIREWALL" == "true" ]]; then
  warn "방화벽 설정 건너뜀 (--no-firewall)"
elif command -v ufw &>/dev/null; then
  # SSH 포트 (SSH 터널용 — 먼저 확보)
  if ! ufw status 2>/dev/null | grep -qE "22/tcp|OpenSSH"; then
    ufw allow 22/tcp comment "SSH" 2>/dev/null && success "UFW: SSH(22/tcp) 오픈" || true
  else
    info "UFW: SSH(22/tcp) 이미 허용됨"
  fi

  # VNC 포트
  ufw allow "${VNC_PORT}/tcp" comment "VNC-GNOME :${VNC_DISPLAY}" 2>/dev/null \
    && success "UFW: 포트 ${VNC_PORT}/tcp 오픈" \
    || warn "UFW 규칙 추가 실패"

  # UFW 활성화
  ufw --force enable 2>/dev/null && success "UFW 활성화 완료" || true
  ufw status numbered 2>/dev/null | head -20 || true
else
  warn "ufw 미설치 — iptables 수동 설정 필요:"
  warn "  sudo iptables -A INPUT -p tcp --dport ${VNC_PORT} -j ACCEPT"
fi

# ════════════════════════════════════════════════════════════
# [7] 동작 확인 및 진단
# ════════════════════════════════════════════════════════════
section "[7] 동작 확인"

# GNOME 세션은 초기화에 시간이 걸림 — 최대 15초 대기
info "VNC 포트 대기 중 (최대 15초)..."
for i in $(seq 1 15); do
  if ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT}"; then
    success "포트 ${VNC_PORT} LISTEN 확인 ✓ (${i}초 후)"
    break
  fi
  sleep 1
  [[ $i -eq 15 ]] && warn "포트 ${VNC_PORT} 15초 내 LISTEN 안 됨"
done

# 포트 상세 확인
if ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT}"; then
  ss -tlnp | grep ":${VNC_PORT}" | sed 's/^/    /'
fi

# PID 파일 확인
if [[ -f "$PID_FILE" ]]; then
  VNC_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  success "PID 파일 확인: $PID_FILE (PID: $VNC_PID)"
else
  warn "PID 파일 없음: $PID_FILE"
fi

# VNC 로그 파일 확인
if [[ -f "$LOG_FILE" ]]; then
  info "VNC 로그 (마지막 10줄):"
  tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
fi

# 프로세스 확인
info "VNC 프로세스:"
ps aux | grep -E "[Xv]nc|tigervnc" | grep -v grep | sed 's/^/    /' || echo "    (없음)"

# 서버 IP 목록
SERVER_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.' | head -5 || echo "")

# ════════════════════════════════════════════════════════════
# 완료 안내
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  GNOME VNC 설정 완료!                           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}  서버 정보:${NC}"
echo "    사용자    : $REAL_USER"
echo "    DE        : GNOME (세션: ${GNOME_SESSION_NAME:-기본값})"
echo "    해상도    : ${VNC_GEOMETRY} @ ${VNC_DEPTH}bit"
echo "    렌더링    : 소프트웨어 (llvmpipe) — GPU 없이도 동작"
echo "    포트      : ${VNC_PORT}  (디스플레이 :${VNC_DISPLAY})"
echo ""
if [[ -n "$SERVER_IPS" ]]; then
  echo -e "${BOLD}  VNC 클라이언트 접속 주소:${NC}"
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    echo "    ${ip}:${VNC_PORT}"
  done <<< "$SERVER_IPS"
  echo ""
fi
echo -e "${BOLD}  보안 접속 — SSH 터널 (강력 권장):${NC}"
echo "    ① 로컬 PC 터미널에서:"
echo "       ssh -L 5901:localhost:${VNC_PORT} ${REAL_USER}@<서버IP>"
echo "    ② VNC 클라이언트에서: localhost:5901 접속"
echo ""
echo -e "${BOLD}  추천 VNC 클라이언트:${NC}"
echo "    Windows  : RealVNC Viewer (https://www.realvnc.com/download/viewer/)"
echo "    macOS    : RealVNC Viewer / Finder > 이동 > 서버에 연결 > vnc://IP:PORT"
echo "    Linux    : Remmina,  vncviewer <IP>::${VNC_DISPLAY}"
echo ""
echo -e "${BOLD}  서비스 관리:${NC}"
echo "    상태 확인   : sudo systemctl status ${SERVICE_NAME}"
echo "    재시작      : sudo systemctl restart ${SERVICE_NAME}"
echo "    중지        : sudo systemctl stop ${SERVICE_NAME}"
echo "    로그 보기   : sudo journalctl -u ${SERVICE_NAME} -f"
echo "    비밀번호 변경: sudo -u ${REAL_USER} vncpasswd"
echo ""
echo -e "${BOLD}  문제 진단:${NC}"
echo "    VNC 로그    : cat ${LOG_FILE}"
echo "    포트 확인   : ss -tlnp | grep ${VNC_PORT}"
echo "    수동 테스트 : sudo -u ${REAL_USER} vncserver :${VNC_DISPLAY} -geometry ${VNC_GEOMETRY} -localhost no -SecurityTypes VncAuth -rfbauth ${VNC_PASSWD_DIR}/passwd"
echo ""
echo -e "${YELLOW}  ⚠  VNC는 기본적으로 암호화되지 않습니다.${NC}"
echo -e "${YELLOW}     외부망 접속 시 반드시 SSH 터널을 사용하세요.${NC}"
echo ""
