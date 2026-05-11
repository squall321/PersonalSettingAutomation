#!/bin/bash

set -e

echo "=============================="
echo " VS Code 설치 자동화 스크립트"
echo "=============================="

# 필수 패키지 설치
echo "[1/4] 필수 패키지 설치 중..."
sudo apt-get update -y
sudo apt-get install -y wget gpg apt-transport-https

# Microsoft GPG 키 등록
echo "[2/4] Microsoft GPG 키 등록 중..."
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg
sudo install -o root -g root -m 644 /tmp/microsoft.gpg /etc/apt/keyrings/microsoft.gpg
rm /tmp/microsoft.gpg

# Microsoft 레포지토리 등록
echo "[3/4] Microsoft APT 레포지토리 등록 중..."
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

# VS Code 설치
echo "[4/4] VS Code 설치 중..."
sudo apt-get update -y
sudo apt-get install -y code

echo ""
echo "=============================="
echo " VS Code 설치 완료!"
echo " 실행: code"
echo "=============================="
