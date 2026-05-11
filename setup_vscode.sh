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

# ── 프록시 환경변수 로드 (/etc/environment) ──────────────────
if [[ -f /etc/environment ]]; then
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d ' "')
    val=$(echo "$val" | tr -d '"')
    case "$key" in
      http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|no_proxy|NO_PROXY)
        export "$key"="$val" ;;
    esac
  done < /etc/environment
  [[ -n "${HTTP_PROXY:-}" ]] && echo "[INFO] 프록시 감지: $HTTP_PROXY"
fi

# wget / curl 프록시 옵션 구성
WGET_PROXY_OPTS=""
CURL_PROXY_OPTS=""
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  WGET_PROXY_OPTS="-e use_proxy=yes -e https_proxy=${HTTPS_PROXY} -e http_proxy=${HTTP_PROXY:-$HTTPS_PROXY}"
  CURL_PROXY_OPTS="--proxy ${HTTPS_PROXY}"
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  WGET_PROXY_OPTS="-e use_proxy=yes -e http_proxy=${HTTP_PROXY}"
  CURL_PROXY_OPTS="--proxy ${HTTP_PROXY}"
fi

# 이미 설치된 경우 확인
if command -v code &>/dev/null; then
  echo "[OK]  VS Code 이미 설치됨: $(code --version | head -1)"
  echo "      재설치하려면 'sudo apt-get reinstall code' 를 실행하세요."
  exit 0
fi

# 필수 패키지 설치
echo "[1/4] 필수 패키지 설치 중..."
apt-get update -y
apt-get install -y wget gpg apt-transport-https ca-certificates curl

# Microsoft GPG 키 등록
echo "[2/4] Microsoft GPG 키 등록 중..."
mkdir -p /etc/apt/keyrings

# 키 다운로드 (wget → curl 순서로 시도, 각각 프록시 및 타임아웃 적용)
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
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | tee /etc/apt/sources.list.d/vscode.list > /dev/null

# VS Code 설치
echo "[4/4] VS Code 설치 중..."
apt-get update -y
apt-get install -y code

echo ""
echo "=============================="
echo " VS Code 설치 완료!"
echo " 실행: code"
echo "=============================="
