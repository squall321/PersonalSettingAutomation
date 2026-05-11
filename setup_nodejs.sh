#!/bin/bash
# ============================================================
#  setup_nodejs.sh  v1
#  Node.js (NodeSource APT repo) 자동 설치 — 프록시 환경 지원
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS (x86_64 / arm64)
#
#  사용법:
#    sudo bash setup_nodejs.sh [옵션]
#
#  옵션:
#    --version N        Node.js major 버전 (기본: 20)
#    --no-proxy         proxy_config.yaml 무시 (직결)
#    --no-cert          사내 CA 인증서 등록 안 함
#    --check-only       이미 설치돼 있는지 점검만 (설치 안 함)
#
#  예:
#    sudo bash setup_nodejs.sh                # Node 20 (기본)
#    sudo bash setup_nodejs.sh --version 22   # Node 22
#    sudo bash setup_nodejs.sh --no-proxy     # 사외/직결 환경
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

# ── 인수 파싱 ─────────────────────────────────────────────────
NODE_MAJOR=20
USE_PROXY=true
USE_CERT=true
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    NODE_MAJOR="$2";  shift 2 ;;
    --no-proxy)   USE_PROXY=false;  shift ;;
    --no-cert)    USE_CERT=false;   shift ;;
    --check-only) CHECK_ONLY=true;  shift ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || error "--version 은 숫자여야 합니다: $NODE_MAJOR"

info "Node.js major 버전: $NODE_MAJOR"
info "대상 사용자: $REAL_USER"

# ── 기존 설치 점검 ────────────────────────────────────────────
if command -v node &>/dev/null; then
  CUR_VER=$(node -v 2>/dev/null | sed 's/^v//')
  CUR_MAJOR="${CUR_VER%%.*}"
  info "현재 설치된 Node.js: v${CUR_VER}"
  if [[ "$CUR_MAJOR" == "$NODE_MAJOR" ]]; then
    success "이미 Node.js ${NODE_MAJOR}.x 가 설치되어 있습니다"
    $CHECK_ONLY && exit 0
    info "재설치/업데이트 진행"
  fi
elif $CHECK_ONLY; then
  warn "Node.js 미설치"
  exit 1
fi

# ════════════════════════════════════════════════════════════
# 프록시 설정 로드 (proxy_config.yaml)
# ════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_CONFIG="${SCRIPT_DIR}/proxy_config.yaml"
CRT_PATH=""
APT_PROXY_OPTS=""

if $USE_PROXY; then
  section "프록시 설정 로드"

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

  if [[ -f "$YAML_CONFIG" ]] && command -v python3 &>/dev/null; then
    while IFS='=' read -r key val; do
      [[ -z "$key" ]] && continue
      export "$key"="$val"
      export "${key,,}"="$val"
      info "  $key=$val"
    done < <(load_proxy_from_yaml "$YAML_CONFIG")

    # CRT_PATH 상대경로 → 절대경로
    if [[ -n "${CRT_PATH:-}" && "$CRT_PATH" != /* ]]; then
      CRT_PATH="${SCRIPT_DIR}/${CRT_PATH#./}"
    fi
  else
    warn "proxy_config.yaml 없거나 python3 미설치 — 시스템 환경변수 사용"
  fi

  # APT 용 프록시 옵션
  if [[ -n "${HTTPS_PROXY:-}" ]]; then
    APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY:-$HTTPS_PROXY} -o Acquire::https::Proxy=${HTTPS_PROXY}"
  elif [[ -n "${HTTP_PROXY:-}" ]]; then
    APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY}"
  fi
else
  warn "--no-proxy 옵션 — 프록시 사용 안 함"
fi

export DEBIAN_FRONTEND=noninteractive

# ════════════════════════════════════════════════════════════
# [1] 사내 CA 인증서 등록 (SSL 인터셉트 프록시 대응)
# ════════════════════════════════════════════════════════════
if $USE_CERT && [[ -n "$CRT_PATH" ]]; then
  section "[1] 사내 CA 인증서 등록"

  if [[ -f "$CRT_PATH" ]]; then
    CERT_NAME="$(basename "$CRT_PATH" .crt).crt"
    DEST="/usr/local/share/ca-certificates/${CERT_NAME}"
    if [[ ! -f "$DEST" ]] || ! cmp -s "$CRT_PATH" "$DEST"; then
      cp "$CRT_PATH" "$DEST" && \
        update-ca-certificates >/dev/null 2>&1 && \
        success "CA 인증서 등록: $DEST"
    else
      info "CA 인증서 이미 등록됨: $DEST"
    fi
  else
    warn "인증서 파일 없음: $CRT_PATH — 건너뜀"
  fi
fi

# ════════════════════════════════════════════════════════════
# [2] 사전 패키지 설치 (curl, gnupg, ca-certificates)
# ════════════════════════════════════════════════════════════
section "[2] 사전 패키지 설치"

apt-get $APT_PROXY_OPTS update -y >/dev/null 2>&1 || warn "apt-get update 일부 실패"
apt-get $APT_PROXY_OPTS install -y \
  ca-certificates \
  curl \
  gnupg \
  apt-transport-https \
  && success "사전 패키지 설치 완료" \
  || error "사전 패키지 설치 실패 (네트워크/프록시 확인 필요)"

# ════════════════════════════════════════════════════════════
# [3] NodeSource GPG 키 등록
#     공식 가이드: https://github.com/nodesource/distributions
# ════════════════════════════════════════════════════════════
section "[3] NodeSource GPG 키 등록"

KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/nodesource.gpg"
mkdir -p "$KEYRING_DIR"
chmod 755 "$KEYRING_DIR"

# curl 옵션: 프록시 인증서 검증 위해 필요시 --cacert
CURL_OPTS=(-fsSL --retry 3 --connect-timeout 30)
if $USE_CERT && [[ -n "$CRT_PATH" && -f "$CRT_PATH" ]]; then
  CURL_OPTS+=(--cacert "$CRT_PATH")
fi
if $USE_PROXY && [[ -n "${HTTPS_PROXY:-}" ]]; then
  CURL_OPTS+=(--proxy "$HTTPS_PROXY")
fi

GPG_URL="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
info "GPG 키 다운로드: $GPG_URL"
if curl "${CURL_OPTS[@]}" "$GPG_URL" | gpg --dearmor -o "$KEYRING_FILE" 2>/dev/null; then
  chmod 644 "$KEYRING_FILE"
  success "NodeSource GPG 키 저장: $KEYRING_FILE"
else
  error "GPG 키 다운로드 실패 — 프록시/인증서/네트워크 점검 필요"
fi

# ════════════════════════════════════════════════════════════
# [4] APT 저장소 등록
# ════════════════════════════════════════════════════════════
section "[4] APT 저장소 등록"

SOURCES_FILE="/etc/apt/sources.list.d/nodesource.list"
cat > "$SOURCES_FILE" << EOF
deb [signed-by=${KEYRING_FILE}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
deb-src [signed-by=${KEYRING_FILE}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF
success "저장소 등록: $SOURCES_FILE"

# pinning — NodeSource 의 nodejs 가 ubuntu 기본보다 우선되도록
cat > /etc/apt/preferences.d/nodesource << 'PINEOF'
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 1000
PINEOF

# ════════════════════════════════════════════════════════════
# [5] Node.js 설치
# ════════════════════════════════════════════════════════════
section "[5] Node.js ${NODE_MAJOR}.x 설치"

apt-get $APT_PROXY_OPTS update -y >/dev/null 2>&1 || warn "apt-get update 일부 실패"

# 충돌 가능성 있는 이전 패키지 제거 (Ubuntu 기본 nodejs/libnode 등)
if dpkg -l 2>/dev/null | grep -qE '^ii\s+(libnode|nodejs-doc)\s'; then
  apt-get $APT_PROXY_OPTS remove -y libnode-dev libnode72 nodejs-doc 2>/dev/null || true
fi

apt-get $APT_PROXY_OPTS install -y nodejs \
  && success "Node.js 설치 완료" \
  || error "Node.js 설치 실패 — apt-get install nodejs 로그 확인"

# ════════════════════════════════════════════════════════════
# [6] 검증 + npm 설정
# ════════════════════════════════════════════════════════════
section "[6] 검증"

if command -v node &>/dev/null; then
  NODE_V=$(node -v 2>&1)
  success "node : $NODE_V"
else
  error "node 실행 불가"
fi

if command -v npm &>/dev/null; then
  NPM_V=$(npm -v 2>&1)
  success "npm  : v$NPM_V"
else
  warn "npm 실행 불가"
fi

# npm 캐시 위치(있으면 그냥 안내)
NPM_PREFIX=$(npm config get prefix 2>/dev/null || echo "")
[[ -n "$NPM_PREFIX" ]] && info "npm prefix : $NPM_PREFIX"

# ════════════════════════════════════════════════════════════
# 완료 안내
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  Node.js ${NODE_MAJOR}.x 설치 완료                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}▶ 설치 확인:${NC}"
echo "  node -v"
echo "  npm -v"
echo "  npx -v"
echo ""
echo -e "${BOLD}▶ npm 프록시 설정 (이미 setup_proxy.sh 로 했다면 생략):${NC}"
if $USE_PROXY && [[ -n "${HTTPS_PROXY:-}" ]]; then
  echo "  npm config set proxy ${HTTP_PROXY:-$HTTPS_PROXY}"
  echo "  npm config set https-proxy ${HTTPS_PROXY}"
  [[ -n "${NO_PROXY:-}" ]] && echo "  npm config set noproxy ${NO_PROXY}"
  if [[ -n "$CRT_PATH" && -f "$CRT_PATH" ]]; then
    echo "  npm config set cafile ${CRT_PATH}"
  fi
fi
echo ""
echo -e "${BOLD}▶ 글로벌 패키지 설치 예:${NC}"
echo "  sudo npm install -g pnpm yarn typescript"
echo ""
