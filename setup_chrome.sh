#!/bin/bash
# ============================================================
#  setup_chrome.sh  v1
#  Google Chrome 자동 설치 스크립트
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS (x86_64 / arm64)
#
#  사용법:
#    sudo bash setup_chrome.sh [옵션]
#
#  옵션:
#    --stable     Stable 채널 설치 (기본값)
#    --beta       Beta 채널 설치
#    --unstable   Dev 채널 설치
#    --no-default 기본 브라우저로 설정하지 않음
# ============================================================

set -euo pipefail

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

# ── 인수 파싱 ─────────────────────────────────────────────────
CHROME_CHANNEL="stable"
SET_DEFAULT=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stable)     CHROME_CHANNEL="stable";   shift ;;
    --beta)       CHROME_CHANNEL="beta";     shift ;;
    --unstable)   CHROME_CHANNEL="unstable"; shift ;;
    --no-default) SET_DEFAULT=false;         shift ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

# 채널별 패키지명
case "$CHROME_CHANNEL" in
  stable)   PKG="google-chrome-stable"   ;;
  beta)     PKG="google-chrome-beta"     ;;
  unstable) PKG="google-chrome-unstable" ;;
esac

info "설치 채널  : ${CHROME_CHANNEL} (${PKG})"
info "대상 사용자: ${REAL_USER}"

# ── 아키텍처 확인 (x86_64 전용, arm64 경고) ──────────────────
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
info "아키텍처   : ${ARCH}"
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  warn "Google Chrome 공식 빌드는 arm64 를 지원하지 않습니다."
  warn "Chromium 을 대신 설치합니다."
  INSTALL_CHROMIUM=true
else
  INSTALL_CHROMIUM=false
fi

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
crt   = yaml_get(path, 'certificate.crt_path')
if http or https:
    print(f"HTTP_PROXY={http}")
    print(f"HTTPS_PROXY={https}")
    print(f"NO_PROXY={nop}")
if crt:
    print(f"CRT_PATH={crt}")
PYEOF
}

CRT_PATH=""
if [[ -f "$YAML_CONFIG" ]] && command -v python3 &>/dev/null; then
  info "proxy_config.yaml 에서 프록시 로드 중"
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    export "$key"="$val"
    export "${key,,}"="$val"
    info "  $key=$val"
  done < <(load_proxy_from_yaml "$YAML_CONFIG")
  # CRT_PATH 상대경로 → 절대경로 변환
  if [[ -n "${CRT_PATH:-}" && "$CRT_PATH" != /* ]]; then
    CRT_PATH="${SCRIPT_DIR}/${CRT_PATH#./}"
  fi
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

CURL_PROXY_OPTS=""
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  CURL_PROXY_OPTS="--proxy ${HTTPS_PROXY}"
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  CURL_PROXY_OPTS="--proxy ${HTTP_PROXY}"
fi

WGET_PROXY_OPTS=""
if [[ -n "${HTTP_PROXY:-}" ]]; then
  WGET_PROXY_OPTS="-e use_proxy=yes -e http_proxy=${HTTP_PROXY} -e https_proxy=${HTTPS_PROXY:-$HTTP_PROXY}"
fi

# ════════════════════════════════════════════════════════════
# [1] arm64: Chromium 설치
# ════════════════════════════════════════════════════════════
if [[ "$INSTALL_CHROMIUM" == "true" ]]; then
  section "[1] Chromium 설치 (arm64 대체)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get $APT_PROXY_OPTS update -y
  apt-get $APT_PROXY_OPTS install -y chromium-browser 2>/dev/null \
    || apt-get $APT_PROXY_OPTS install -y chromium 2>/dev/null \
    || error "Chromium 설치 실패"
  success "Chromium 설치 완료"
  INSTALLED_BIN=$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || echo "")
  info "설치 경로: ${INSTALLED_BIN}"
  echo ""
  echo -e "${GREEN}✅ Chromium 설치 완료!${NC}"
  echo "   실행: chromium-browser  또는  chromium"
  exit 0
fi

# ════════════════════════════════════════════════════════════
# [1] 사전 패키지 설치
# ════════════════════════════════════════════════════════════
section "[1] 사전 패키지 설치"

export DEBIAN_FRONTEND=noninteractive
apt-get $APT_PROXY_OPTS update -y
apt-get $APT_PROXY_OPTS install -y \
  curl \
  wget \
  gnupg \
  ca-certificates \
  apt-transport-https
success "사전 패키지 설치 완료"

# ── 사내 인증서 등록 (프록시 HTTPS 인증서) ─────────────────
if [[ -n "${CRT_PATH:-}" && -f "$CRT_PATH" ]]; then
  section "사내 인증서 등록"
  CERT_DEST="/usr/local/share/ca-certificates/$(basename "$CRT_PATH" .crt).crt"
  cp "$CRT_PATH" "$CERT_DEST"
  update-ca-certificates --fresh 2>/dev/null || true
  success "인증서 등록 완료: $CERT_DEST"
fi

# ════════════════════════════════════════════════════════════
# [2] 이미 설치됐는지 확인
# ════════════════════════════════════════════════════════════
section "[2] 설치 여부 확인"

if dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
  INSTALLED_VER=$(dpkg -l "$PKG" | awk '/^ii/{print $3}')
  warn "${PKG} 이미 설치됨: ${INSTALLED_VER}"
  warn "재설치/업그레이드를 진행합니다."
fi

# ════════════════════════════════════════════════════════════
# [3] Google GPG 키 등록
# ════════════════════════════════════════════════════════════
section "[3] Google GPG 키 등록"

GPG_KEY_URL="https://dl.google.com/linux/linux_signing_key.pub"
GPG_KEY_FILE="/usr/share/keyrings/google-chrome.gpg"
GPG_TMP="/tmp/google-chrome-key.pub"

# GPG 키 다운로드 (curl → wget 순서로 시도, 타임아웃 30초)
info "GPG 키 다운로드 중: $GPG_KEY_URL"
DOWNLOAD_OK=false

if command -v curl &>/dev/null; then
  if curl -fsSL $CURL_PROXY_OPTS \
      --max-time 30 \
      --retry 3 \
      --retry-delay 2 \
      ${CRT_PATH:+--cacert "$CRT_PATH"} \
      -o "$GPG_TMP" \
      "$GPG_KEY_URL" 2>/dev/null; then
    DOWNLOAD_OK=true
    info "curl 다운로드 성공"
  fi
fi

if [[ "$DOWNLOAD_OK" != "true" ]] && command -v wget &>/dev/null; then
  if wget -q $WGET_PROXY_OPTS \
      --timeout=30 \
      --tries=3 \
      ${CRT_PATH:+--ca-certificate="$CRT_PATH"} \
      -O "$GPG_TMP" \
      "$GPG_KEY_URL" 2>/dev/null; then
    DOWNLOAD_OK=true
    info "wget 다운로드 성공"
  fi
fi

[[ "$DOWNLOAD_OK" != "true" ]] && error "GPG 키 다운로드 실패 (curl/wget 모두 실패). 네트워크/프록시 설정을 확인하세요."

# GPG 키 유효성 확인 후 dearmor
if file "$GPG_TMP" | grep -q "PGP\|GPG\|public key"; then
  # ASCII-armor 형식
  gpg --dearmor < "$GPG_TMP" > "$GPG_KEY_FILE" 2>/dev/null \
    || { cat "$GPG_TMP" > "$GPG_KEY_FILE"; }
elif file "$GPG_TMP" | grep -q "data\|binary"; then
  # 이미 바이너리
  cp "$GPG_TMP" "$GPG_KEY_FILE"
else
  gpg --dearmor < "$GPG_TMP" > "$GPG_KEY_FILE" 2>/dev/null \
    || cp "$GPG_TMP" "$GPG_KEY_FILE"
fi

chmod 644 "$GPG_KEY_FILE"
rm -f "$GPG_TMP"

# GPG 키 검증
if gpg --no-default-keyring --keyring "$GPG_KEY_FILE" --list-keys 2>/dev/null | grep -qi "google"; then
  success "GPG 키 등록 완료 (Google 키 확인됨)"
else
  warn "GPG 키 내용을 검증하지 못했지만 계속 진행합니다."
fi

# ════════════════════════════════════════════════════════════
# [4] APT 저장소 등록
# ════════════════════════════════════════════════════════════
section "[4] Google Chrome APT 저장소 등록"

REPO_FILE="/etc/apt/sources.list.d/google-chrome.list"

cat > "$REPO_FILE" << REPOEOF
deb [arch=amd64 signed-by=${GPG_KEY_FILE}] https://dl.google.com/linux/chrome/deb/ stable main
REPOEOF

success "저장소 등록 완료: $REPO_FILE"
cat "$REPO_FILE"

# ── APT 프록시로 저장소 업데이트 ─────────────────────────────
info "APT 업데이트 중..."
apt-get $APT_PROXY_OPTS update -y \
  || {
    warn "APT 업데이트 실패 — Google 저장소 접근 불가. 프록시 설정을 확인하세요."
    warn "APT 프록시 opts: ${APT_PROXY_OPTS:-없음}"
    # Google 저장소만 제외하고 계속 시도
    apt-get $APT_PROXY_OPTS update -y --ignore-missing 2>/dev/null || true
  }

# ════════════════════════════════════════════════════════════
# [5] Chrome 설치
# ════════════════════════════════════════════════════════════
section "[5] ${PKG} 설치"

if apt-get $APT_PROXY_OPTS install -y "$PKG"; then
  success "${PKG} 설치 완료"
else
  warn "APT 설치 실패 — .deb 직접 다운로드로 전환합니다."

  # .deb 직접 다운로드 방식 (APT 저장소 접근 불가 환경)
  section "[5-fallback] .deb 직접 다운로드"
  DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  DEB_FILE="/tmp/google-chrome.deb"

  info ".deb 다운로드 중: $DEB_URL"
  if command -v curl &>/dev/null; then
    curl -fsSL $CURL_PROXY_OPTS \
      --max-time 120 \
      --retry 3 \
      ${CRT_PATH:+--cacert "$CRT_PATH"} \
      -o "$DEB_FILE" \
      "$DEB_URL" \
      || error ".deb 다운로드 실패"
  else
    wget -q $WGET_PROXY_OPTS \
      --timeout=120 \
      --tries=3 \
      ${CRT_PATH:+--ca-certificate="$CRT_PATH"} \
      -O "$DEB_FILE" \
      "$DEB_URL" \
      || error ".deb 다운로드 실패"
  fi

  info ".deb 설치 중..."
  apt-get $APT_PROXY_OPTS install -y "$DEB_FILE" \
    || dpkg -i "$DEB_FILE" && apt-get $APT_PROXY_OPTS install -f -y \
    || error "Chrome .deb 설치 실패"

  rm -f "$DEB_FILE"
  success "Chrome .deb 직접 설치 완료"
fi

# ════════════════════════════════════════════════════════════
# [6] 설치 확인
# ════════════════════════════════════════════════════════════
section "[6] 설치 확인"

CHROME_BIN=$(command -v google-chrome-stable 2>/dev/null \
  || command -v google-chrome 2>/dev/null \
  || echo "")

if [[ -n "$CHROME_BIN" ]]; then
  CHROME_VER=$("$CHROME_BIN" --version 2>/dev/null || echo "버전 확인 불가")
  success "Chrome 설치 확인: $CHROME_VER"
  success "실행 경로: $CHROME_BIN"
else
  error "Chrome 바이너리를 찾을 수 없습니다."
fi

# ════════════════════════════════════════════════════════════
# [7] 기본 브라우저 설정
# ════════════════════════════════════════════════════════════
if [[ "$SET_DEFAULT" == "true" ]]; then
  section "[7] 기본 브라우저 설정"
  sudo -u "$REAL_USER" xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null \
    && success "기본 브라우저: Google Chrome" \
    || warn "기본 브라우저 설정 실패 (GUI 세션 없음 — VNC 접속 후 수동 설정 가능)"
fi

# ════════════════════════════════════════════════════════════
# [8] 프록시 환경에서 Chrome 실행 래퍼 생성
# ════════════════════════════════════════════════════════════
if [[ -n "${HTTP_PROXY:-}" ]]; then
  section "[8] Chrome 프록시 래퍼 스크립트"

  WRAPPER="/usr/local/bin/chrome-proxy"
  cat > "$WRAPPER" << WEOF
#!/bin/bash
# Google Chrome 프록시 래퍼 (자동 생성: setup_chrome.sh)
exec /usr/bin/google-chrome-stable \
  --proxy-server="${HTTP_PROXY:-}" \
  --no-sandbox \
  "\$@"
WEOF
  chmod +x "$WRAPPER"
  success "프록시 래퍼 생성 완료: $WRAPPER"
  info "프록시 환경에서 실행: chrome-proxy"
fi

# ════════════════════════════════════════════════════════════
# 완료 안내
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  Google Chrome 설치 완료!                       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}  설치 정보:${NC}"
echo "    패키지  : ${PKG}"
echo "    버전    : ${CHROME_VER:-확인 불가}"
echo "    경로    : ${CHROME_BIN:-확인 불가}"
echo ""
echo -e "${BOLD}  실행 방법:${NC}"
echo "    일반 실행  : google-chrome"
if [[ -n "${HTTP_PROXY:-}" ]]; then
echo "    프록시 실행: chrome-proxy"
fi
echo "    VNC 내에서 : 바탕화면 또는 앱 메뉴에서 Chrome 아이콘 클릭"
echo ""
echo -e "${BOLD}  자동 업데이트:${NC}"
echo "    Google APT 저장소가 등록되어 apt upgrade 시 자동 업데이트됩니다."
echo "    저장소: /etc/apt/sources.list.d/google-chrome.list"
echo ""
if [[ -n "${HTTP_PROXY:-}" ]]; then
  echo -e "${YELLOW}  ⚠  프록시 환경:${NC}"
  echo "     Chrome 내부 설정에서 프록시 설정이 필요할 수 있습니다."
  echo "     설정 > 시스템 > 컴퓨터의 프록시 설정 열기"
  echo ""
fi
