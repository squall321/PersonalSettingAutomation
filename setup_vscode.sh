#!/bin/bash

set -e

# ── 권한 확인 ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] sudo 로 실행하세요:  sudo bash $0"
  exit 1
fi

echo "=============================="
echo " VS Code 설치 자동화 스크립트"
echo "=============================="

# ── 프록시 설정 로드 (proxy_config.yaml 우선, /etc/environment 폴백) ──
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
  echo "[INFO] proxy_config.yaml 에서 프록시 읽는 중: $YAML_CONFIG"
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    export "$key"="$val"
    export "${key,,}"="$val"
    echo "[INFO]   $key=$val"
  done < <(load_proxy_from_yaml "$YAML_CONFIG")
elif [[ -f /etc/environment ]]; then
  echo "[INFO] /etc/environment 에서 프록시 읽는 중"
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d ' "'); val=$(echo "$val" | tr -d '"')
    case "$key" in
      http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|no_proxy|NO_PROXY)
        export "$key"="$val" ;;
    esac
  done < /etc/environment
  [[ -n "${HTTP_PROXY:-}" ]] && echo "[INFO] 프록시 감지: $HTTP_PROXY"
else
  echo "[INFO] 프록시 설정 없음"
fi

# wget / curl / apt 프록시 옵션 구성
WGET_PROXY_OPTS=""
CURL_PROXY_OPTS=""
APT_PROXY_OPTS=""
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  WGET_PROXY_OPTS="-e use_proxy=yes -e https_proxy=${HTTPS_PROXY} -e http_proxy=${HTTP_PROXY:-$HTTPS_PROXY}"
  CURL_PROXY_OPTS="--proxy ${HTTPS_PROXY}"
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY:-$HTTPS_PROXY} -o Acquire::https::Proxy=${HTTPS_PROXY}"
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  WGET_PROXY_OPTS="-e use_proxy=yes -e http_proxy=${HTTP_PROXY}"
  CURL_PROXY_OPTS="--proxy ${HTTP_PROXY}"
  APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY}"
fi

# 시스템 아키텍처 자동 감지
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
echo "[INFO] 아키텍처: $ARCH"

# 이미 설치된 경우 확인
if command -v code &>/dev/null; then
  echo "[OK]  VS Code 이미 설치됨: $(code --version | head -1)"
  echo "      재설치하려면 'sudo apt-get reinstall code' 를 실행하세요."
  exit 0
fi

# 필수 패키지 설치
echo "[1/4] 필수 패키지 설치 중..."
apt-get $APT_PROXY_OPTS update -y
apt-get $APT_PROXY_OPTS install -y wget gpg apt-transport-https ca-certificates curl

# Microsoft GPG 키 등록
echo "[2/4] Microsoft GPG 키 등록 중..."
mkdir -p /etc/apt/keyrings

KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
echo "      키 다운로드 중: $KEY_URL"

if wget -q --timeout=30 $WGET_PROXY_OPTS "$KEY_URL" -O /tmp/microsoft.asc 2>/dev/null; then
  echo "      wget 성공"
elif curl -fsSL --connect-timeout 30 --max-time 60 $CURL_PROXY_OPTS \
       "$KEY_URL" -o /tmp/microsoft.asc 2>/dev/null; then
  echo "      curl 성공"
else
  echo "[ERROR] GPG 키 다운로드 실패 — 네트워크/프록시 설정을 확인하세요."
  echo "        수동 다운로드: wget $KEY_URL -O /tmp/microsoft.asc"
  exit 1
fi

# ASCII armor(.asc) → binary(.gpg) 변환
gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft.gpg /tmp/microsoft.asc
chmod 644 /etc/apt/keyrings/microsoft.gpg
rm /tmp/microsoft.asc
echo "      GPG 키 등록 완료"

# 키 정상 여부 확인
if ! gpg --no-default-keyring --keyring /etc/apt/keyrings/microsoft.gpg \
        --list-keys &>/dev/null; then
  echo "[ERROR] GPG 키 변환 실패 — 다운로드된 파일이 손상됐을 수 있습니다."
  exit 1
fi

# Microsoft 레포지토리 등록
echo "[3/4] Microsoft APT 레포지토리 등록 중..."
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | tee /etc/apt/sources.list.d/vscode.list > /dev/null

# VS Code 설치
echo "[4/4] VS Code 설치 중..."
apt-get $APT_PROXY_OPTS update -y
apt-get $APT_PROXY_OPTS install -y code

echo ""
echo "=============================="
echo " VS Code 설치 완료!"
echo " 실행: code"
echo "=============================="
