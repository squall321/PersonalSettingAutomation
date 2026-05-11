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

# 이미 설치된 경우 확인
if command -v code &>/dev/null; then
  echo "[OK]  VS Code 이미 설치됨: $(code --version | head -1)"
  echo "      재설치하려면 'sudo apt-get reinstall code' 를 실행하세요."
  exit 0
fi

# 필수 패키지 설치
echo "[1/4] 필수 패키지 설치 중..."
apt-get update -y
apt-get install -y wget gpg apt-transport-https ca-certificates

# Microsoft GPG 키 등록
echo "[2/4] Microsoft GPG 키 등록 중..."
mkdir -p /etc/apt/keyrings

# 키를 파일로 먼저 내려받은 뒤 변환 (파이프 전달 시 손상 방지)
wget -q https://packages.microsoft.com/keys/microsoft.asc -O /tmp/microsoft.asc
# ASCII armor(.asc) → binary(.gpg) 변환
gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft.gpg /tmp/microsoft.asc
chmod 644 /etc/apt/keyrings/microsoft.gpg
rm /tmp/microsoft.asc

# 키 정상 여부 확인
if ! gpg --no-default-keyring --keyring /etc/apt/keyrings/microsoft.gpg \
        --list-keys &>/dev/null; then
  echo "[ERROR] GPG 키 변환 실패 — 네트워크 또는 gpg 버전을 확인하세요."
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
