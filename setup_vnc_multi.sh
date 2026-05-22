#!/bin/bash
# ============================================================
#  setup_vnc_multi.sh  v1
#  여러 계정에 대해 TigerVNC 헤드리스 서비스를 일괄 셋업
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS
#
#  특징:
#    - 사용자별로 tigervnc-USERNAME.service 등록
#    - 사용자별 ~/.vnc/{passwd, xstartup, config} 작성
#    - 디스플레이 자동 충돌 회피 (점유된 :N 은 다음 번호로)
#    - x11vnc(미러링)는 다루지 않음 — 그건 setup_vnc.sh 사용
#
#  사용:
#    # 1) 입력 파일 (가장 간단 — 권장)
#    sudo bash setup_vnc_multi.sh --config vnc_users.yaml
#
#    # 2) CLI 직접 지정
#    sudo bash setup_vnc_multi.sh --users 'alice:5905,bob:5906' [옵션]
#    sudo bash setup_vnc_multi.sh --users 'alice,bob,carol'         # 포트 자동
#
#  옵션:
#    --config FILE      vnc_users.yaml 같은 입력 파일에서 읽음
#                       (users, desktop, password 필드 모두 지원)
#    --users LIST       사용자 목록 (--config 안 쓸 때)
#                       형식 1: 'alice:5905,bob:5906'   (포트 명시)
#                       형식 2: 'alice,bob,carol'        (5905부터 자동)
#    --password PWD     모든 사용자 공통 비밀번호
#                       미지정 시 사용자별 대화형 입력
#    --desktop D        gnome|xfce (기본: gnome)
#    --start-port P     자동 할당 시작 포트 (기본: 5905)
#    --no-firewall      UFW 열기 건너뜀
#    --remove           지정한 사용자들의 VNC 서비스 모두 제거
#
#  ※ CLI 옵션이 --config 의 값을 덮어씁니다 (CLI 우선)
# ============================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── 권한 확인 ─────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "sudo 로 실행하세요:  sudo bash $0 $*"

# ── 인수 파싱 ─────────────────────────────────────────────────
USERS_ARG=""
COMMON_PASS=""
DESKTOP=""        # 빈값 → 나중에 config 값 또는 'gnome' 기본
START_PORT=5905
SKIP_FIREWALL=false
DO_REMOVE=false
CONFIG_FILE=""
# CLI 로 명시됐는지 추적 (config 값 덮어쓸지 판단용)
CLI_USERS=false; CLI_PASS=false; CLI_DESKTOP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --users)       USERS_ARG="$2";   CLI_USERS=true;   shift 2 ;;
    --password)    COMMON_PASS="$2"; CLI_PASS=true;    shift 2 ;;
    --desktop)     DESKTOP="$2";     CLI_DESKTOP=true; shift 2 ;;
    --start-port)  START_PORT="$2";  shift 2 ;;
    --no-firewall) SKIP_FIREWALL=true; shift ;;
    --remove)      DO_REMOVE=true;   shift ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

# ── --config 파일 파싱 ───────────────────────────────────────
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || error "config 파일 없음: $CONFIG_FILE"
  command -v python3 &>/dev/null || error "config 파싱에 python3 필요"

  CFG_OUT=$(python3 - "$CONFIG_FILE" << 'PYEOF'
import re, sys
path = sys.argv[1]
data = {}
section = None
with open(path) as f:
    for raw in f:
        line = raw.rstrip()
        if not line or line.lstrip().startswith('#'): continue
        m = re.match(r'^(\w[\w-]*):\s*(.*)', line)
        if m:
            section = m.group(1)
            # 1) 인라인 주석 제거  2) 좌우 공백 제거  3) raw 가 비었으면 섹션, 아니면 값
            raw_val = re.sub(r'\s+#.*$', '', m.group(2)).strip()
            if raw_val == '':
                data[section] = {}
            else:
                data[section] = raw_val.strip('"\'')   # password: "" 가 빈 문자열로 보존됨
            continue
        m = re.match(r'^\s{2,}([\w-]+):\s*(.*)', line)
        if m and isinstance(data.get(section), dict):
            v = re.sub(r'\s+#.*$', '', m.group(2)).strip().strip('"\'')
            data[section][m.group(1)] = v
desktop = data.get('desktop','') or ''
password = data.get('password','') if not isinstance(data.get('password'), dict) else ''
users = data.get('users', {})
if isinstance(users, dict):
    pairs = ','.join(f"{u}:{p}" for u,p in users.items() if p)
else:
    pairs = ''
print(f"DESKTOP={desktop}")
print(f"PASSWORD={password}")
print(f"USERS={pairs}")
PYEOF
)
  while IFS='=' read -r k v; do
    case "$k" in
      DESKTOP)  $CLI_DESKTOP || [[ -z "$v" ]] || DESKTOP="$v" ;;
      PASSWORD) $CLI_PASS    || [[ -z "$v" ]] || COMMON_PASS="$v" ;;
      USERS)    $CLI_USERS   || [[ -z "$v" ]] || USERS_ARG="$v" ;;
    esac
  done <<< "$CFG_OUT"
  info "config 로드: $CONFIG_FILE"
fi

[[ -z "$DESKTOP" ]] && DESKTOP="gnome"
[[ -z "$USERS_ARG" ]] && error "사용자 목록이 비어있습니다. --users 또는 --config 의 users 필드를 설정하세요"
case "$DESKTOP" in gnome|xfce) ;; *) error "desktop 은 gnome|xfce 만 가능: $DESKTOP" ;; esac
[[ "$START_PORT" =~ ^[0-9]+$ ]] || error "--start-port 는 숫자여야 합니다: $START_PORT"

# ── 사용자 목록 파싱 ──────────────────────────────────────────
# user:port,user:port  또는  user,user  혼합 가능
declare -A USER_PORT
declare -a USER_ORDER
IFS=',' read -ra ENTRIES <<< "$USERS_ARG"
NEXT_PORT="$START_PORT"
for entry in "${ENTRIES[@]}"; do
  entry="${entry// /}"   # 공백 제거
  [[ -z "$entry" ]] && continue
  if [[ "$entry" == *":"* ]]; then
    u="${entry%%:*}"
    p="${entry##*:}"
    [[ "$p" =~ ^[0-9]+$ ]] || error "포트가 숫자가 아님: $entry"
  else
    u="$entry"
    # 사용 안 한 다음 빈 포트 자동 할당
    while [[ -n "${USER_PORT[*]:-}" ]] && \
          (for v in "${USER_PORT[@]}"; do [[ "$v" == "$NEXT_PORT" ]] && exit 0; done; exit 1); do
      NEXT_PORT=$((NEXT_PORT + 1))
    done
    p="$NEXT_PORT"
    NEXT_PORT=$((NEXT_PORT + 1))
  fi
  USER_PORT["$u"]="$p"
  USER_ORDER+=("$u")
done

[[ ${#USER_ORDER[@]} -eq 0 ]] && error "유효한 사용자가 없습니다"

# ── 사용자 존재 확인 ──────────────────────────────────────────
section "사용자 검증"
for u in "${USER_ORDER[@]}"; do
  if ! getent passwd "$u" &>/dev/null; then
    error "사용자 '$u' 존재하지 않음 (먼저 useradd 로 계정 생성 필요)"
  fi
  uid=$(id -u "$u")
  home=$(getent passwd "$u" | cut -d: -f6)
  info "  $u  (UID=$uid, HOME=$home, port=${USER_PORT[$u]}, disp=:${USER_PORT[$u]##590})"
done

# ════════════════════════════════════════════════════════════
# --remove: 지정 사용자들 서비스 삭제
# ════════════════════════════════════════════════════════════
if $DO_REMOVE; then
  section "서비스 제거 모드"
  for u in "${USER_ORDER[@]}"; do
    svc="tigervnc-${u}"
    p="${USER_PORT[$u]}"
    d="${p##590}"
    info "[$u] 서비스/잔여물 정리"
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
    sudo -u "$u" vncserver -kill ":$d" </dev/null >/dev/null 2>&1 || true
    pkill -9 -u "$u" -f "Xvnc.*:${d}( |$)" 2>/dev/null || true
    rm -f "/tmp/.X${d}-lock" "/tmp/.X11-unix/X${d}" 2>/dev/null || true
    success "[$u] 제거 완료"
  done
  systemctl daemon-reload
  echo ""
  success "총 ${#USER_ORDER[@]} 명의 VNC 서비스 제거 완료"
  exit 0
fi

# ════════════════════════════════════════════════════════════
# [1] 공통 패키지 설치 (한 번만)
# ════════════════════════════════════════════════════════════
section "[1] 필수 패키지 설치"

# 프록시 로드 (proxy_config.yaml 가 있으면)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_CONFIG="${SCRIPT_DIR}/proxy_config.yaml"
APT_PROXY_OPTS=""
if [[ -f "$YAML_CONFIG" ]] && command -v python3 &>/dev/null; then
  HP=$(python3 -c "
import re
with open('$YAML_CONFIG') as f:
    for line in f:
        m = re.match(r'^\s+http:\s*(.+)', line)
        if m:
            v = re.sub(r'\s+#.*$','',m.group(1)).strip().strip('\"\\'')
            print(v); break
") || HP=""
  if [[ -n "$HP" ]]; then
    APT_PROXY_OPTS="-o Acquire::http::Proxy=${HP} -o Acquire::https::Proxy=${HP}"
    info "  프록시: $HP"
  fi
fi

export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY_OPTS update -y >/dev/null 2>&1 || warn "apt update 일부 실패"

apt-get $APT_PROXY_OPTS install -y \
  tigervnc-standalone-server tigervnc-common \
  xauth dbus-x11 x11-xserver-utils xserver-common xfonts-base xterm \
  && success "TigerVNC 기본 패키지 OK" || error "TigerVNC 설치 실패"

if [[ "$DESKTOP" == "gnome" ]]; then
  apt-get $APT_PROXY_OPTS install -y gnome-session gnome-shell gnome-terminal \
    && success "GNOME OK" || warn "GNOME 일부 설치 실패 (이미 설치돼 있을 수 있음)"
else
  apt-get $APT_PROXY_OPTS install -y xfce4 xfce4-goodies xfce4-terminal \
    && success "XFCE OK" || warn "XFCE 일부 설치 실패"
fi

# ════════════════════════════════════════════════════════════
# 사용자별 셋업 함수
# ════════════════════════════════════════════════════════════
setup_one_user() {
  local U="$1"
  local PORT="$2"
  local DISP="${PORT##590}"
  [[ -z "$DISP" || "$DISP" -le 0 ]] && DISP=1
  local UID_U; UID_U=$(id -u "$U")
  local HOME_U; HOME_U=$(getent passwd "$U" | cut -d: -f6)
  local VNC_DIR="${HOME_U}/.vnc"
  local SVC="tigervnc-${U}"

  section "[$U] TigerVNC :${DISP} (포트 ${PORT}) 셋업"

  # 0) 잔여물 정리
  systemctl stop "$SVC" 2>/dev/null || true
  sudo -u "$U" vncserver -kill ":$DISP" </dev/null >/dev/null 2>&1 || true
  pkill -9 -u "$U" -f "Xvnc.*:${DISP}( |$)" 2>/dev/null || true
  rm -f "/tmp/.X${DISP}-lock" "/tmp/.X11-unix/X${DISP}" 2>/dev/null || true

  # 디스플레이 자동 충돌 회피
  local attempts=0
  while (( attempts < 10 )); do
    rm -f "/tmp/.X${DISP}-lock" "/tmp/.X11-unix/X${DISP}" 2>/dev/null
    sleep 0.2
    if [[ ! -e "/tmp/.X${DISP}-lock" && ! -e "/tmp/.X11-unix/X${DISP}" ]]; then
      break
    fi
    local holder
    holder=$(lsof "/tmp/.X11-unix/X${DISP}" 2>/dev/null | awk 'NR==2{print $1"(PID "$2")"}')
    warn "  :${DISP} 점유 중 (${holder:-unknown}) — 다음 번호 시도"
    DISP=$((DISP + 1))
    PORT=$((5900 + DISP))
    attempts=$((attempts + 1))
  done
  info "  최종 디스플레이: :${DISP} (포트 ${PORT})"

  # 1) ~/.vnc 디렉토리
  sudo -u "$U" mkdir -p "$VNC_DIR"
  chmod 700 "$VNC_DIR"
  chown "$U:$U" "$VNC_DIR"

  # 2) 비밀번호 파일
  local THIS_PASS="$COMMON_PASS"
  if [[ -z "$THIS_PASS" ]]; then
    echo ""
    read -rsp "  [$U] VNC 비밀번호 (최소 6자): " THIS_PASS
    echo ""
    [[ ${#THIS_PASS} -lt 6 ]] && { warn "비밀번호 너무 짧음 — [$U] 건너뜀"; return 1; }
  fi
  if command -v vncpasswd &>/dev/null; then
    printf '%s\n%s\n\n' "$THIS_PASS" "$THIS_PASS" | \
      sudo -u "$U" HOME="$HOME_U" vncpasswd "$VNC_DIR/passwd" >/dev/null 2>&1
  fi
  chown "$U:$U" "$VNC_DIR/passwd"
  chmod 600 "$VNC_DIR/passwd"

  # 3) xstartup
  if [[ "$DESKTOP" == "gnome" ]]; then
    cat > "$VNC_DIR/xstartup" << 'XSEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME
export XDG_SESSION_DESKTOP=gnome
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
export MUTTER_DEBUG_DISABLE_HW_CURSOR=1
for s in ubuntu-xorg ubuntu gnome-xorg gnome; do
  [ -f "/usr/share/gnome-session/sessions/${s}.session" ] || continue
  if command -v dbus-launch >/dev/null 2>&1; then
    exec dbus-launch --exit-with-session gnome-session --session="$s"
  else
    exec gnome-session --session="$s"
  fi
done
if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session gnome-session
else
  exec gnome-session
fi
XSEOF
  else
    cat > "$VNC_DIR/xstartup" << 'XSEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session startxfce4
else
  exec startxfce4
fi
XSEOF
  fi
  chmod 755 "$VNC_DIR/xstartup"
  chown "$U:$U" "$VNC_DIR/xstartup"

  # 4) config
  cat > "$VNC_DIR/config" << CFGEOF
geometry=1920x1080
depth=24
localhost=no
rfbport=${PORT}
SecurityTypes=VncAuth
CFGEOF
  chown "$U:$U" "$VNC_DIR/config"

  # 5) XDG_RUNTIME_DIR 사전 생성
  mkdir -p "/run/user/${UID_U}"
  chown "${U}:${U}" "/run/user/${UID_U}"
  chmod 700 "/run/user/${UID_U}"

  # 6) systemd 유닛
  cat > "/etc/systemd/system/${SVC}.service" << TSVC
[Unit]
Description=TigerVNC Server for ${U} (:${DISP}, port ${PORT})
After=network.target syslog.target

[Service]
Type=simple
User=${U}
Group=${U}
WorkingDirectory=${HOME_U}
Environment=HOME=${HOME_U}
Environment=USER=${U}
Environment=SHELL=/bin/bash
Environment=XDG_RUNTIME_DIR=/run/user/${UID_U}
ExecStartPre=-/usr/bin/vncserver -kill :${DISP}
ExecStartPre=+/bin/bash -c 'pkill -9 -u ${U} -f "Xvnc.*:${DISP}( |\$)" 2>/dev/null; rm -f /tmp/.X${DISP}-lock /tmp/.X11-unix/X${DISP} 2>/dev/null; true'
ExecStart=/usr/bin/vncserver -fg :${DISP} -geometry 1920x1080 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :${DISP}
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
TSVC

  systemctl daemon-reload
  systemctl enable "$SVC" 2>/dev/null
  if systemctl restart "$SVC"; then
    sleep 3
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      success "[$U] 서비스 active, 포트 ${PORT} LISTEN ✓"
    else
      warn "[$U] 서비스 시작은 됐으나 포트 ${PORT} LISTEN 안됨 — journalctl 확인"
    fi
  else
    warn "[$U] 서비스 시작 실패 — journalctl -u ${SVC} -n 30"
  fi

  # 7) UFW
  if ! $SKIP_FIREWALL && command -v ufw &>/dev/null; then
    ufw allow "${PORT}/tcp" comment "VNC-${U}" 2>/dev/null || true
  fi
}

# ════════════════════════════════════════════════════════════
# 사용자별 반복
# ════════════════════════════════════════════════════════════
for u in "${USER_ORDER[@]}"; do
  setup_one_user "$u" "${USER_PORT[$u]}" || warn "[$u] 셋업 일부 실패"
done

# UFW enable
if ! $SKIP_FIREWALL; then
  ufw allow 22/tcp comment "SSH" 2>/dev/null || true
  ufw --force enable 2>/dev/null && success "UFW 활성화" || true
fi

# ════════════════════════════════════════════════════════════
# 요약
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  다계정 VNC 셋업 완료                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "${BOLD}▶ 접속 정보:${NC}"
for u in "${USER_ORDER[@]}"; do
  p="${USER_PORT[$u]}"
  state=$(systemctl is-active "tigervnc-${u}" 2>/dev/null)
  listen=$(ss -tlnp 2>/dev/null | grep -q ":${p} " && echo "LISTEN" || echo "no-listen")
  echo -e "  ${CYAN}${u}${NC}\t→ ${SERVER_IP:-?}:${p}   [service: ${state}, port: ${listen}]"
done
echo ""

echo -e "${BOLD}▶ 서비스 관리:${NC}"
echo "  상태: systemctl status tigervnc-<user>"
echo "  로그: journalctl -u tigervnc-<user> -f"
echo "  제거: sudo bash $0 --users '<user1>,<user2>' --remove"
echo ""

echo -e "${BOLD}▶ SSH 터널 (보안 접속 권장):${NC}"
for u in "${USER_ORDER[@]}"; do
  p="${USER_PORT[$u]}"
  echo "  ssh -L ${p}:localhost:${p} ${u}@${SERVER_IP:-<서버IP>}   → VNC: localhost:${p}"
done
echo ""
