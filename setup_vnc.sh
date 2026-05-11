#!/bin/bash
# ============================================================
#  setup_vnc.sh  v1
#  Ubuntu VNC 원격 접속 자동화 스크립트
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS
#
#  구성:
#   1. 프록시 설정 로드 (proxy_config.yaml)
#   2. 필수 패키지 설치 (TigerVNC + 데스크탑 환경)
#   3. VNC 비밀번호 설정
#   4. xstartup 구성 (DE 자동 감지: GNOME/KDE/XFCE/MATE)
#   5. systemd 서비스 등록 (부팅 시 자동 시작)
#   6. x11vnc (현재 세션 미러링 모드) 선택 지원
#   7. UFW 방화벽 포트 오픈 (5900+display)
#   8. SSH 터널링 안내
#
#  사용법:
#    sudo bash setup_vnc.sh [옵션]
#    옵션:
#      --display N     VNC 디스플레이 번호 (기본: 1, 포트 5901)
#      --port P        VNC 포트 직접 지정 (기본: 5900+display)
#      --geometry WxH  해상도 (기본: 1920x1080)
#      --depth D       색 깊이 (기본: 24)
#      --password PWD  VNC 비밀번호 (미지정 시 대화형 입력)
#      --x11vnc        TigerVNC 대신 x11vnc (현재 세션 미러링) 사용
#      --no-firewall   UFW 방화벽 설정 건너뜀
# ============================================================

set -uo pipefail

# ── 색상 헬퍼 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── 권한 확인 ─────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "sudo 로 실행하세요:  sudo bash $0 $*"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
info "대상 사용자: $REAL_USER ($REAL_HOME)"

# ── 인수 파싱 ─────────────────────────────────────────────────
VNC_DISPLAY=1
VNC_PORT=""
VNC_GEOMETRY="1920x1080"
VNC_DEPTH=24
VNC_PASSWORD=""
USE_X11VNC=false
SKIP_FIREWALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --display)   VNC_DISPLAY="$2";  shift 2 ;;
    --port)      VNC_PORT="$2";     shift 2 ;;
    --geometry)  VNC_GEOMETRY="$2"; shift 2 ;;
    --depth)     VNC_DEPTH="$2";    shift 2 ;;
    --password)  VNC_PASSWORD="$2"; shift 2 ;;
    --x11vnc)    USE_X11VNC=true;   shift ;;
    --no-firewall) SKIP_FIREWALL=true; shift ;;
    *) warn "알 수 없는 옵션: $1"; shift ;;
  esac
done

[[ -z "$VNC_PORT" ]] && VNC_PORT=$((5900 + VNC_DISPLAY))
info "VNC 디스플레이 : :${VNC_DISPLAY}  (포트 ${VNC_PORT})"
info "해상도         : ${VNC_GEOMETRY}"
info "색 깊이        : ${VNC_DEPTH}bit"

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
http = yaml_get(path, 'proxy.http'); https = yaml_get(path, 'proxy.https'); nop = yaml_get(path, 'proxy.no_proxy')
if http or https:
    print(f"HTTP_PROXY={http}"); print(f"HTTPS_PROXY={https}"); print(f"NO_PROXY={nop}")
PYEOF
}

if [[ -f "$YAML_CONFIG" ]] && command -v python3 &>/dev/null; then
  info "proxy_config.yaml 에서 프록시 읽는 중"
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    export "$key"="$val"
    export "${key,,}"="$val"
    info "  $key=$val"
  done < <(load_proxy_from_yaml "$YAML_CONFIG")
elif [[ -f /etc/environment ]]; then
  info "/etc/environment 에서 프록시 읽는 중"
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
# [1] 현재 데스크탑 환경 감지
# ════════════════════════════════════════════════════════════
section "[1] 데스크탑 환경 감지"

detect_de() {
  # 실행 중인 프로세스로 판별
  for proc in gnome-session plasmashell xfce4-session mate-session cinnamon-session lxsession; do
    if pgrep -u "$REAL_USER" "$proc" &>/dev/null; then
      case "$proc" in
        gnome-session)    echo "gnome"    ; return ;;
        plasmashell)      echo "kde"      ; return ;;
        xfce4-session)    echo "xfce"     ; return ;;
        mate-session)     echo "mate"     ; return ;;
        cinnamon-session) echo "cinnamon" ; return ;;
        lxsession)        echo "lxde"     ; return ;;
      esac
    fi
  done
  # XDG 환경변수로 폴백
  local xdg
  xdg=$(sudo -u "$REAL_USER" printenv XDG_CURRENT_DESKTOP 2>/dev/null || echo "")
  case "${xdg,,}" in
    *gnome*)        echo "gnome"    ;;
    *kde*|*plasma*) echo "kde"      ;;
    *xfce*)         echo "xfce"     ;;
    *mate*)         echo "mate"     ;;
    *cinnamon*)     echo "cinnamon" ;;
    *lxde*)         echo "lxde"     ;;
    *)              echo "unknown"  ;;
  esac
}

DETECTED_DE=$(detect_de)
info "감지된 DE: ${DETECTED_DE:-알 수 없음}"

# 설치된 DE 중 VNC에 가장 적합한 것 선택
choose_de_for_vnc() {
  # 경량 순서로 우선순위
  for de_check in xfce mate lxde cinnamon gnome kde; do
    case "$de_check" in
      xfce)     command -v startxfce4    &>/dev/null && { echo "xfce";     return; } ;;
      mate)     command -v mate-session  &>/dev/null && { echo "mate";     return; } ;;
      lxde)     command -v startlxde     &>/dev/null && { echo "lxde";     return; } ;;
      cinnamon) command -v cinnamon-session &>/dev/null && { echo "cinnamon"; return; } ;;
      gnome)    command -v gnome-session &>/dev/null && { echo "gnome";    return; } ;;
      kde)      command -v plasmashell   &>/dev/null && { echo "kde";      return; } ;;
    esac
  done
  echo "none"
}

VNC_DE=$(choose_de_for_vnc)
info "VNC용 DE: ${VNC_DE}"

# ════════════════════════════════════════════════════════════
# [2] 패키지 설치
# ════════════════════════════════════════════════════════════
section "[2] 패키지 설치"

apt-get $APT_PROXY_OPTS update -y

if [[ "$USE_X11VNC" == "true" ]]; then
  # x11vnc 모드: 현재 X 세션 미러링
  apt-get $APT_PROXY_OPTS install -y x11vnc xauth
  success "x11vnc 설치 완료"
else
  # TigerVNC 모드: 독립 가상 데스크탑
  apt-get $APT_PROXY_OPTS install -y \
    tigervnc-standalone-server \
    tigervnc-common \
    dbus-x11 \
    xauth \
    xfonts-base

  # DE가 없으면 XFCE 설치 (경량)
  if [[ "$VNC_DE" == "none" ]]; then
    info "데스크탑 환경 없음 — XFCE4 설치 중..."
    apt-get $APT_PROXY_OPTS install -y \
      xfce4 xfce4-goodies xterm
    VNC_DE="xfce"
    success "XFCE4 설치 완료"
  fi
  success "TigerVNC 설치 완료"
fi

# 공통 유틸
apt-get $APT_PROXY_OPTS install -y ufw 2>/dev/null || true

# ════════════════════════════════════════════════════════════
# [3] VNC 비밀번호 설정
# ════════════════════════════════════════════════════════════
section "[3] VNC 비밀번호 설정"

VNC_PASSWD_DIR="$REAL_HOME/.vnc"
sudo -u "$REAL_USER" mkdir -p "$VNC_PASSWD_DIR"
chmod 700 "$VNC_PASSWD_DIR"

if [[ -n "$VNC_PASSWORD" ]]; then
  # 비대화형: 인수로 받은 비밀번호 사용
  echo "$VNC_PASSWORD" | sudo -u "$REAL_USER" vncpasswd -f > "$VNC_PASSWD_DIR/passwd"
  chmod 600 "$VNC_PASSWD_DIR/passwd"
  chown "$REAL_USER:$REAL_USER" "$VNC_PASSWD_DIR/passwd"
  success "VNC 비밀번호 설정 완료 (인수 사용)"
elif [[ -f "$VNC_PASSWD_DIR/passwd" ]]; then
  warn "기존 VNC 비밀번호 파일 유지: $VNC_PASSWD_DIR/passwd"
  warn "변경하려면: sudo -u $REAL_USER vncpasswd"
else
  info "VNC 비밀번호를 입력하세요 (최소 6자):"
  sudo -u "$REAL_USER" vncpasswd "$VNC_PASSWD_DIR/passwd" \
    || error "VNC 비밀번호 설정 실패"
  chmod 600 "$VNC_PASSWD_DIR/passwd"
  success "VNC 비밀번호 설정 완료"
fi

# ════════════════════════════════════════════════════════════
# [4] xstartup 스크립트 작성 (TigerVNC 전용)
# ════════════════════════════════════════════════════════════
if [[ "$USE_X11VNC" != "true" ]]; then
  section "[4] xstartup 구성 (DE: $VNC_DE)"

  XSTARTUP="$VNC_PASSWD_DIR/xstartup"

  # DE별 시작 명령 결정
  case "$VNC_DE" in
    gnome)
      DE_CMD='exec dbus-launch --exit-with-session gnome-session'
      DE_ENV='export GNOME_SHELL_SESSION_MODE=ubuntu\nexport XDG_CURRENT_DESKTOP=ubuntu:GNOME'
      ;;
    kde)
      DE_CMD='exec dbus-launch --exit-with-session startplasma-x11'
      DE_ENV='export XDG_CURRENT_DESKTOP=KDE\nexport KDE_FULL_SESSION=true'
      ;;
    xfce)
      DE_CMD='exec dbus-launch --exit-with-session startxfce4'
      DE_ENV='export XDG_CURRENT_DESKTOP=XFCE'
      ;;
    mate)
      DE_CMD='exec dbus-launch --exit-with-session mate-session'
      DE_ENV='export XDG_CURRENT_DESKTOP=MATE'
      ;;
    cinnamon)
      DE_CMD='exec dbus-launch --exit-with-session cinnamon-session'
      DE_ENV='export XDG_CURRENT_DESKTOP=X-Cinnamon'
      ;;
    lxde)
      DE_CMD='exec dbus-launch --exit-with-session startlxde'
      DE_ENV='export XDG_CURRENT_DESKTOP=LXDE'
      ;;
    *)
      DE_CMD='exec xterm'
      DE_ENV=''
      warn "알 수 없는 DE — xterm 으로 폴백"
      ;;
  esac

  cat > "$XSTARTUP" << XEOF
#!/bin/bash
# VNC xstartup — 자동 생성 (setup_vnc.sh)

# 환경 초기화
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# X 리소스 / 키맵
[ -r "\$HOME/.Xresources" ] && xrdb "\$HOME/.Xresources"
xsetroot -solid grey

# 한글 입력기 (fcitx/ibus 설치 시 자동 활성화)
if command -v fcitx5 &>/dev/null; then
  export GTK_IM_MODULE=fcitx
  export QT_IM_MODULE=fcitx
  export XMODIFIERS=@im=fcitx
  fcitx5 -d 2>/dev/null &
elif command -v ibus-daemon &>/dev/null; then
  export GTK_IM_MODULE=ibus
  export QT_IM_MODULE=ibus
  export XMODIFIERS=@im=ibus
  ibus-daemon -drx 2>/dev/null &
fi

# 데스크탑 환경 시작 (${VNC_DE})
$(echo -e "$DE_ENV")
${DE_CMD}
XEOF

  chmod +x "$XSTARTUP"
  chown "$REAL_USER:$REAL_USER" "$XSTARTUP"
  success "xstartup 작성 완료: $XSTARTUP"
fi

# ════════════════════════════════════════════════════════════
# [5] systemd 서비스 등록
# ════════════════════════════════════════════════════════════
section "[5] systemd 서비스 등록"

if [[ "$USE_X11VNC" == "true" ]]; then
  # ── x11vnc 서비스 ──────────────────────────────────────────
  SERVICE_NAME="x11vnc"
  cat > /etc/systemd/system/x11vnc.service << EOF
[Unit]
Description=x11vnc VNC Server (current session mirror)
After=multi-user.target graphical.target
Wants=graphical.target

[Service]
Type=simple
User=${REAL_USER}
Environment=DISPLAY=:0
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/x11vnc \\
  -display :0 \\
  -auth guess \\
  -forever \\
  -loop \\
  -noxdamage \\
  -repeat \\
  -rfbauth ${VNC_PASSWD_DIR}/passwd \\
  -rfbport ${VNC_PORT} \\
  -shared \\
  -bg
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF
  success "x11vnc.service 작성 완료 (포트 ${VNC_PORT})"

else
  # ── TigerVNC 서비스 (@템플릿 방식) ────────────────────────
  SERVICE_NAME="vncserver@${VNC_DISPLAY}"

  # tigervnc systemd 템플릿 서비스 작성
  cat > /etc/systemd/system/vncserver@.service << 'EOF'
[Unit]
Description=TigerVNC Server (display :%i)
After=syslog.target network.target

[Service]
Type=forking
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H:%i.pid

ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver :%i \
  -geometry GEOMETRY_PLACEHOLDER \
  -depth DEPTH_PLACEHOLDER \
  -localhost no \
  -SecurityTypes VncAuth \
  -rfbauth /home/%i/.vnc/passwd
ExecStop=/usr/bin/vncserver -kill :%i

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # geometry/depth 치환
  sed -i \
    -e "s/GEOMETRY_PLACEHOLDER/${VNC_GEOMETRY}/" \
    -e "s/DEPTH_PLACEHOLDER/${VNC_DEPTH}/" \
    /etc/systemd/system/vncserver@.service

  # 사용자 전용 서비스 (User= 가 %i 템플릿이라 실제 사용자로 override)
  OVERRIDE_DIR="/etc/systemd/system/vncserver@${VNC_DISPLAY}.service.d"
  mkdir -p "$OVERRIDE_DIR"
  cat > "$OVERRIDE_DIR/override.conf" << EOF
[Service]
User=${REAL_USER}
PIDFile=${REAL_HOME}/.vnc/%H:${VNC_DISPLAY}.pid
ExecStartPre=-/usr/bin/vncserver -kill :${VNC_DISPLAY} > /dev/null 2>&1
ExecStart=
ExecStart=/usr/bin/vncserver :${VNC_DISPLAY} \\
  -geometry ${VNC_GEOMETRY} \\
  -depth ${VNC_DEPTH} \\
  -localhost no \\
  -SecurityTypes VncAuth \\
  -rfbauth ${VNC_PASSWD_DIR}/passwd
ExecStop=
ExecStop=/usr/bin/vncserver -kill :${VNC_DISPLAY}
EOF
  success "vncserver@.service + override 작성 완료"
fi

# 서비스 활성화 및 시작
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" 2>/dev/null \
  && success "${SERVICE_NAME} 자동시작 등록 완료" \
  || warn "${SERVICE_NAME} enable 실패"

# 기존 VNC 프로세스 정리 후 시작
if [[ "$USE_X11VNC" != "true" ]]; then
  sudo -u "$REAL_USER" vncserver -kill ":${VNC_DISPLAY}" &>/dev/null || true
  sleep 1
fi

systemctl restart "${SERVICE_NAME}" 2>/dev/null \
  && success "${SERVICE_NAME} 시작 완료" \
  || warn "${SERVICE_NAME} 시작 실패 (재부팅 후 자동 시작됩니다)"

# ════════════════════════════════════════════════════════════
# [6] UFW 방화벽 설정
# ════════════════════════════════════════════════════════════
section "[6] UFW 방화벽 설정"

if [[ "$SKIP_FIREWALL" == "true" ]]; then
  warn "방화벽 설정 건너뜀 (--no-firewall)"
elif command -v ufw &>/dev/null; then
  ufw allow "${VNC_PORT}/tcp" comment "VNC :${VNC_DISPLAY}" 2>/dev/null \
    && success "UFW: 포트 ${VNC_PORT}/tcp 오픈" \
    || warn "UFW 규칙 추가 실패 (ufw 비활성 상태일 수 있음)"

  # SSH도 열려있는지 확인 (SSH 터널용)
  if ! ufw status | grep -q "22/tcp\|OpenSSH"; then
    ufw allow 22/tcp comment "SSH" 2>/dev/null && success "UFW: SSH(22/tcp) 오픈" || true
  fi

  # UFW 활성화 (이미 활성이면 무시)
  ufw --force enable 2>/dev/null && success "UFW 활성화 완료" || true
else
  warn "ufw 미설치 — 방화벽 설정 건너뜀"
  warn "수동: sudo iptables -A INPUT -p tcp --dport ${VNC_PORT} -j ACCEPT"
fi

# ════════════════════════════════════════════════════════════
# [7] VNC 동작 확인
# ════════════════════════════════════════════════════════════
section "[7] VNC 동작 확인"

sleep 2
if ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT}"; then
  success "포트 ${VNC_PORT} LISTEN 확인 ✓"
elif netstat -tlnp 2>/dev/null | grep -q ":${VNC_PORT}"; then
  success "포트 ${VNC_PORT} LISTEN 확인 ✓"
else
  warn "포트 ${VNC_PORT} 아직 LISTEN 안 됨 (서비스 시작 시간 필요 또는 재부팅)"
  info "확인: sudo ss -tlnp | grep ${VNC_PORT}"
fi

# 서버 IP 수집
SERVER_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -5 || echo "IP 확인 불가")

# ════════════════════════════════════════════════════════════
# 완료 안내
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  VNC 설정 완료!                                  ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}  서버 정보:${NC}"
echo "    사용자  : $REAL_USER"
echo "    DE      : ${VNC_DE}"
echo "    해상도  : ${VNC_GEOMETRY} @ ${VNC_DEPTH}bit"
echo "    포트    : ${VNC_PORT}  (디스플레이 :${VNC_DISPLAY})"
echo ""
echo -e "${BOLD}  접속 주소 (VNC 클라이언트):${NC}"
while read -r ip; do
  [[ -z "$ip" ]] && continue
  echo "    ${ip}:${VNC_PORT}   또는   ${ip}::${VNC_DISPLAY}"
done <<< "$SERVER_IPS"
echo ""
echo -e "${BOLD}  추천 VNC 클라이언트:${NC}"
echo "    Windows : RealVNC Viewer, TightVNC Viewer, TigerVNC Viewer"
echo "    macOS   : RealVNC Viewer, 화면 공유 (내장)"
echo "    Linux   : Remmina, TigerVNC Viewer"
echo ""
echo -e "${BOLD}  보안 접속 (SSH 터널 — 권장):${NC}"
echo "    1. SSH 터널 설정 (로컬 PC에서 실행):"
echo "       ssh -L 5901:localhost:${VNC_PORT} ${REAL_USER}@<서버IP>"
echo "    2. VNC 클라이언트에서 localhost:5901 으로 접속"
echo ""
echo -e "${BOLD}  서비스 관리:${NC}"
echo "    상태 확인 : sudo systemctl status ${SERVICE_NAME}"
echo "    재시작    : sudo systemctl restart ${SERVICE_NAME}"
echo "    중지      : sudo systemctl stop ${SERVICE_NAME}"
echo "    비밀번호 변경: sudo -u ${REAL_USER} vncpasswd ${VNC_PASSWD_DIR}/passwd"
echo ""
warn "VNC는 기본적으로 암호화되지 않습니다. 외부 접속 시 SSH 터널 사용을 강력 권장합니다."
echo ""
