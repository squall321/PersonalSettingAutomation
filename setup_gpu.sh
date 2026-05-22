#!/bin/bash
# ============================================================
#  setup_gpu.sh  v1
#  NVIDIA GPU(A4000 기준) 자동 셋업 — 드라이버 설치 + (선택) CUDA torch
#  Target: Ubuntu 20.04 / 22.04 / 24.04 LTS, x86_64
#
#  기본 가정: NVIDIA RTX A4000 (Ampere, sm_86, 16GB VRAM, TDP 140W)
#            동일한 Ampere/Ada/Hopper 계열은 모두 동일 절차로 동작
#            (RTX 3090, A6000, RTX 4090, H100 등)
#
#  2-phase 구조 (재부팅 경계):
#    [pre]  드라이버 설치 → 재부팅 필요
#    [post] nvidia-smi 검증 → venv CUDA torch 설치 → torch.cuda 검증
#
#  사용 시나리오:
#    A) 완전 자동 (권장):
#       sudo bash setup_gpu.sh --venv /path/.venv --auto-resume
#       → pre 실행 → systemd 일회성 서비스 등록 → 자동 재부팅
#       → 부팅 후 post 가 자동 실행 → 서비스 자동 정리
#
#    B) 수동 분리:
#       sudo bash setup_gpu.sh --phase pre              # 드라이버만
#       sudo reboot
#       sudo bash setup_gpu.sh --phase post --venv /path/.venv
#
#    C) 한 번에 (재부팅 안 함):
#       sudo bash setup_gpu.sh --venv /path/.venv --no-reboot
#       sudo reboot   # 수동
#       sudo bash setup_gpu.sh --phase post --venv /path/.venv
#
#  옵션:
#    --phase P        pre | post | all  (기본: all)
#    --auto-resume    pre 끝나면 systemd 일회성 서비스 등록 + 자동 재부팅
#                     (부팅 후 post 가 자동 실행됨)
#    --driver V       드라이버 메이저 버전 (예: 535, 545, 550)
#                     미지정 시 'ubuntu-drivers autoinstall' (권장)
#    --venv PATH      venv 경로 — pip 으로 CUDA torch 자동 설치
#    --cuda-channel C cu118 | cu121 | cu124 | cu126  (기본: cu121)
#    --no-proxy       proxy_config.yaml 무시
#    --no-cert        사내 CA 인증서 등록 안 함
#    --no-reboot      자동 재부팅 안 함 (안내만)
#    --check          현재 상태 진단만, 설치 변경 없음
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
REAL_USER="${SUDO_USER:-$USER}"
[[ "$REAL_USER" == "root" ]] && error "SUDO_USER 가 없습니다. 'sudo bash $0' 형태로 실행하세요."
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ── 인수 파싱 ─────────────────────────────────────────────────
DRIVER_VER=""
VENV_PATH=""
CUDA_CHANNEL="cu121"
USE_PROXY=true
USE_CERT=true
NO_REBOOT=false
CHECK_ONLY=false
PHASE="all"
AUTO_RESUME=false
# 원래 호출 인자 (post 단계 재호출용)
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)         PHASE="$2";        shift 2 ;;
    --auto-resume)   AUTO_RESUME=true;  shift ;;
    --driver)        DRIVER_VER="$2";   shift 2 ;;
    --venv)          VENV_PATH="$2";    shift 2 ;;
    --cuda-channel)  CUDA_CHANNEL="$2"; shift 2 ;;
    --no-proxy)      USE_PROXY=false;   shift ;;
    --no-cert)       USE_CERT=false;    shift ;;
    --no-reboot)     NO_REBOOT=true;    shift ;;
    --check)         CHECK_ONLY=true;   shift ;;
    -h|--help)       sed -n '2,42p' "$0"; exit 0 ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

case "$PHASE" in pre|post|all) ;; *) error "--phase 는 pre|post|all 중 하나: $PHASE" ;; esac

case "$CUDA_CHANNEL" in
  cu118|cu121|cu124|cu126) ;;
  *) error "--cuda-channel 은 cu118|cu121|cu124|cu126 중 하나: $CUDA_CHANNEL" ;;
esac

info "대상 사용자: $REAL_USER"
info "CUDA 채널 : $CUDA_CHANNEL"
$CHECK_ONLY && info "모드: 진단만 (변경 없음)"

# ════════════════════════════════════════════════════════════
# 프록시 설정 로드 (setup_chrome.sh/setup_nodejs.sh 와 동일 패턴)
# ════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_CONFIG="${SCRIPT_DIR}/proxy_config.yaml"
CRT_PATH=""
APT_PROXY_OPTS=""

if $USE_PROXY; then
  section "[1] 프록시 설정 로드"

  load_proxy() {
    python3 - "$1" << 'PYEOF'
import sys, re
def strip_cmt(s): return re.sub(r'\s+#.*$','', s).strip().strip('"\'')
def parse(path):
    data = {}; section = None
    with open(path) as f:
        for raw in f:
            line = raw.rstrip()
            if not line or line.lstrip().startswith('#'): continue
            m = re.match(r'^(\w[\w-]*):\s*(.*)', line)
            if m:
                section = m.group(1)
                v = re.sub(r'\s+#.*$','', m.group(2)).strip()
                data[section] = v.strip('"\'') if v else {}
                continue
            m = re.match(r'^\s{2,}([\w-]+):\s*(.*)', line)
            if m and isinstance(data.get(section), dict):
                data[section][m.group(1)] = strip_cmt(m.group(2))
    return data
d = parse(sys.argv[1])
proxy = d.get('proxy', {}) if isinstance(d.get('proxy'), dict) else {}
cert  = d.get('certificate', {}) if isinstance(d.get('certificate'), dict) else {}
print(f"HTTP_PROXY={proxy.get('http','')}")
print(f"HTTPS_PROXY={proxy.get('https','')}")
print(f"NO_PROXY={proxy.get('no_proxy','')}")
print(f"CRT_PATH={cert.get('crt_path','')}")
PYEOF
  }

  if [[ -f "$YAML_CONFIG" ]] && command -v python3 &>/dev/null; then
    while IFS='=' read -r key val; do
      [[ -z "$key" ]] && continue
      export "$key"="$val"
      export "${key,,}"="$val"
      [[ -n "$val" ]] && info "  $key=$val"
    done < <(load_proxy "$YAML_CONFIG")
    if [[ -n "${CRT_PATH:-}" && "$CRT_PATH" != /* ]]; then
      CRT_PATH="${SCRIPT_DIR}/${CRT_PATH#./}"
    fi
  else
    warn "proxy_config.yaml 없거나 python3 미설치 — 시스템 환경변수 사용"
  fi

  if [[ -n "${HTTPS_PROXY:-}" ]]; then
    APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY:-$HTTPS_PROXY} -o Acquire::https::Proxy=${HTTPS_PROXY}"
  elif [[ -n "${HTTP_PROXY:-}" ]]; then
    APT_PROXY_OPTS="-o Acquire::http::Proxy=${HTTP_PROXY}"
  fi
fi

export DEBIAN_FRONTEND=noninteractive

# ── 사내 CA 인증서 등록 (SSL 인터셉트 대응) ──────────────────
if $USE_CERT && [[ -n "$CRT_PATH" && -f "$CRT_PATH" ]]; then
  CERT_NAME="$(basename "$CRT_PATH" .crt).crt"
  DEST="/usr/local/share/ca-certificates/${CERT_NAME}"
  if [[ ! -f "$DEST" ]] || ! cmp -s "$CRT_PATH" "$DEST"; then
    cp "$CRT_PATH" "$DEST" 2>/dev/null && \
      update-ca-certificates >/dev/null 2>&1 && \
      info "  CA 인증서 등록: $DEST"
  fi
fi

# ════════════════════════════════════════════════════════════
# [2] GPU 존재 확인
# ════════════════════════════════════════════════════════════
section "[2] NVIDIA GPU 감지"

if ! command -v lspci &>/dev/null; then
  apt-get $APT_PROXY_OPTS install -y pciutils >/dev/null 2>&1 || true
fi

GPU_INFO=$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' | grep -i nvidia || true)
if [[ -z "$GPU_INFO" ]]; then
  warn "NVIDIA GPU 감지 안 됨 (lspci 결과 비어있음)"
  $CHECK_ONLY || error "NVIDIA GPU 가 없는 호스트입니다 — 스크립트 종료"
else
  echo "$GPU_INFO" | while read -r line; do success "  GPU: $line"; done
fi

# ════════════════════════════════════════════════════════════
# [3] Secure Boot 상태 점검
# ════════════════════════════════════════════════════════════
section "[3] Secure Boot 상태"

SB_STATE="unknown"
if command -v mokutil &>/dev/null; then
  SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
fi
case "$SB_STATE" in
  *"enabled"*)
    warn "Secure Boot ENABLED — 드라이버 설치 후 MOK 등록 프롬프트가 뜹니다"
    warn "  설치 중 임의 비밀번호 입력 → 재부팅 후 파란 화면에서 'Enroll MOK' 선택"
    warn "  → 동일 비밀번호 재입력 → 'Reboot'"
    ;;
  *"disabled"*)
    success "Secure Boot DISABLED — MOK 등록 절차 불필요"
    ;;
  *)
    info "Secure Boot 상태 확인 불가 (mokutil 미설치 또는 BIOS UEFI 아님)"
    ;;
esac

# ════════════════════════════════════════════════════════════
# [4] 현재 드라이버 점검
# ════════════════════════════════════════════════════════════
section "[4] 현재 NVIDIA 드라이버 상태"

CURRENT_DRIVER=""
if command -v nvidia-smi &>/dev/null; then
  CURRENT_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
fi

if [[ -n "$CURRENT_DRIVER" ]]; then
  success "현재 드라이버: $CURRENT_DRIVER"
  echo "--- nvidia-smi 헤더 ---"
  nvidia-smi 2>&1 | head -12 || true
  if $CHECK_ONLY; then
    exit 0
  fi
  # phase=post 또는 비대화형 환경(systemd 일회성 서비스) → read 가 hang 됨
  # 자동으로 'N'(재설치 안 함) 처리하고 venv 단계로 진행
  if [[ "$PHASE" == "post" ]] || [[ ! -t 0 ]]; then
    info "드라이버 이미 설치됨 + 비대화형 — 재설치 건너뜀, venv 단계 진행"
    SKIP_DRIVER_INSTALL=true
  else
    read -rp "  ▶ 이미 드라이버가 설치돼 있습니다. 재설치/업그레이드? (y/N) " ANS
    if [[ ! "$ANS" =~ ^[yY]$ ]]; then
      info "드라이버 단계 건너뜀 — venv 단계로 진행"
      SKIP_DRIVER_INSTALL=true
    fi
  fi
else
  info "NVIDIA 드라이버 미설치"
  if $CHECK_ONLY; then
    warn "드라이버 미설치 상태 — 설치하려면 --check 없이 다시 실행"
    exit 1
  fi
  # phase=post 인데 드라이버가 안 보임 → 재부팅이 안 됐거나 MOK 미등록
  if [[ "$PHASE" == "post" ]]; then
    error "phase=post 인데 nvidia-smi/드라이버를 찾을 수 없습니다.
       가능한 원인:
         1) 재부팅 안 됨 → sudo reboot 후 다시 'sudo bash $0 --phase post ...'
         2) Secure Boot + MOK 미등록 → 재부팅 시 파란 화면에서 'Enroll MOK' 처리 필요
         3) 커널 헤더 누락 → sudo apt install linux-headers-\$(uname -r) && sudo dkms autoinstall
       진단: sudo dmesg | grep -i nvidia | tail -20"
  fi
fi

# ════════════════════════════════════════════════════════════
# [5] 드라이버 설치 — pre / all phase 일 때만
# ════════════════════════════════════════════════════════════
if [[ "$PHASE" == "post" ]]; then
  info "phase=post — 드라이버 설치 건너뜀"
  SKIP_DRIVER_INSTALL=true
  NEEDS_REBOOT=false
fi

if [[ "${SKIP_DRIVER_INSTALL:-false}" != "true" ]]; then
  section "[5] NVIDIA 드라이버 설치"

  apt-get $APT_PROXY_OPTS update -y >/dev/null 2>&1 || warn "apt-get update 일부 실패"

  # 필요 도구
  apt-get $APT_PROXY_OPTS install -y \
    ubuntu-drivers-common build-essential dkms linux-headers-$(uname -r) \
    >/dev/null 2>&1 || warn "사전 패키지 일부 실패"

  if [[ -n "$DRIVER_VER" ]]; then
    info "  명시 드라이버: nvidia-driver-${DRIVER_VER}"
    apt-get $APT_PROXY_OPTS install -y \
      "nvidia-driver-${DRIVER_VER}" "nvidia-utils-${DRIVER_VER}" \
      && success "드라이버 설치 완료" \
      || error "드라이버 설치 실패 — 'apt-cache search nvidia-driver-' 로 가용 버전 확인"
  else
    info "  ubuntu-drivers autoinstall (권장 드라이버 자동 선택)"
    if command -v ubuntu-drivers &>/dev/null; then
      ubuntu-drivers devices 2>/dev/null | grep -E 'recommended|nvidia-driver' || true
      ubuntu-drivers autoinstall \
        && success "드라이버 자동 설치 완료" \
        || error "ubuntu-drivers autoinstall 실패 — --driver <버전> 옵션으로 명시 시도"
    else
      error "ubuntu-drivers 미설치 — --driver <버전> 옵션 사용"
    fi
  fi

  NEEDS_REBOOT=true
else
  NEEDS_REBOOT=false
fi

# ════════════════════════════════════════════════════════════
# [6] venv 에 CUDA PyTorch 설치 — post / all phase 일 때만
#     pre 단계에서 재부팅 필요하면 여기로 안 옴 (아래 [7] 에서 처리)
# ════════════════════════════════════════════════════════════
RUN_POST=true
if [[ "$PHASE" == "pre" ]]; then
  RUN_POST=false
fi
if [[ "$PHASE" == "all" && "${NEEDS_REBOOT:-false}" == "true" ]]; then
  RUN_POST=false   # 재부팅 후에야 의미 있음
fi

if $RUN_POST && [[ -n "$VENV_PATH" ]]; then
  section "[6] CUDA PyTorch 를 venv 에 설치"

  PIP_BIN="${VENV_PATH}/bin/pip"
  PY_BIN="${VENV_PATH}/bin/python"
  if [[ ! -x "$PIP_BIN" ]]; then
    warn "venv 가 없거나 pip 미설치: $VENV_PATH — 건너뜀"
  else
    # pip 도 프록시 + 인증서 따라가야 함
    PIP_ENV=(env)
    $USE_PROXY && [[ -n "${HTTPS_PROXY:-}" ]] && \
      PIP_ENV+=("HTTPS_PROXY=$HTTPS_PROXY" "HTTP_PROXY=${HTTP_PROXY:-$HTTPS_PROXY}")
    if $USE_CERT && [[ -n "$CRT_PATH" && -f "$CRT_PATH" ]]; then
      PIP_ENV+=("REQUESTS_CA_BUNDLE=$CRT_PATH" "CURL_CA_BUNDLE=$CRT_PATH" "SSL_CERT_FILE=$CRT_PATH")
    fi

    info "  설치 채널: https://download.pytorch.org/whl/${CUDA_CHANNEL}"
    sudo -u "$REAL_USER" "${PIP_ENV[@]}" "$PIP_BIN" install \
      --upgrade --force-reinstall \
      torch --index-url "https://download.pytorch.org/whl/${CUDA_CHANNEL}" \
      && success "CUDA torch 설치 완료" \
      || warn "CUDA torch 설치 실패 — 프록시/네트워크 확인"

    # 검증 (드라이버 활성 상태일 때만 의미 있음)
    if [[ -z "${NEEDS_REBOOT:-}" || "$NEEDS_REBOOT" == "false" ]] && \
       command -v nvidia-smi &>/dev/null; then
      info "  torch CUDA 가용성 검증:"
      sudo -u "$REAL_USER" "$PY_BIN" -c \
        "import torch; print('  cuda:', torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else '(no device)')" \
        2>&1 || warn "torch import 실패"
    else
      info "  검증은 재부팅 후 가능: ${PY_BIN} -c 'import torch; print(torch.cuda.is_available())'"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════
# [7] 마무리 / 재부팅 / auto-resume 처리
# ════════════════════════════════════════════════════════════
section "[7] 마무리"

# post phase 가 systemd 일회성 서비스로 실행됐다면 자기 자신 정리
# 로그 파일은 보존 — 사용자가 부팅 후 결과 확인용으로 필요
SVC_NAME="setup-gpu-post.service"
SVC_PATH="/etc/systemd/system/${SVC_NAME}"
if [[ "$PHASE" == "post" && -f "$SVC_PATH" ]]; then
  info "auto-resume 일회성 서비스 정리 중"
  systemctl disable "$SVC_NAME" 2>/dev/null || true
  rm -f "$SVC_PATH"
  systemctl daemon-reload 2>/dev/null || true
  success "$SVC_NAME 자동 정리 완료 (로그는 /var/log/setup_gpu_resume.log 에 보존)"
fi

if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
  warn "드라이버 신규 설치 — 재부팅 1회 필수"
  echo ""

  if $AUTO_RESUME; then
    # Secure Boot + auto-resume 조합은 위험: MOK 등록 파란 화면에서 사용자 개입 필요
    case "$SB_STATE" in
      *"enabled"*)
        warn "━━━ 중요 ━━━"
        warn "Secure Boot 가 ENABLED 입니다. --auto-resume 와 함께 쓰면 자동화가 실패할 수 있어요."
        warn "재부팅 시 'Enroll MOK' 파란 화면이 뜨는데, 자동화는 그 화면을 처리하지 못합니다."
        warn "권장: --auto-resume 대신 수동 모드로 진행 — 'sudo bash $0 --phase pre'"
        warn "       그 후 재부팅하며 직접 MOK 등록 → 'sudo bash $0 --phase post --venv ${VENV_PATH:-<venv>}'"
        warn ""
        if [[ -t 0 ]]; then
          read -rp "  ▶ 그래도 auto-resume 로 진행하시겠습니까? (y/N) " AR_GO
          [[ ! "$AR_GO" =~ ^[yY]$ ]] && { info "취소 — 수동 절차로 진행하세요"; exit 0; }
        else
          error "Secure Boot+auto-resume 위험 — 명시적으로 비대화형에서 진행 거부"
        fi
        ;;
    esac

    # post phase 자동 실행을 위한 systemd 일회성 서비스 등록
    SCRIPT_PATH="$(readlink -f "$0")"
    # post phase 호출에 venv/cuda-channel/proxy/cert 옵션 승계
    POST_ARGS=(--phase post --no-reboot)
    [[ -n "$VENV_PATH" ]]      && POST_ARGS+=(--venv "$VENV_PATH")
    [[ -n "$CUDA_CHANNEL" ]]   && POST_ARGS+=(--cuda-channel "$CUDA_CHANNEL")
    $USE_PROXY || POST_ARGS+=(--no-proxy)
    $USE_CERT  || POST_ARGS+=(--no-cert)
    # systemd 의 ExecStart 는 whitespace-split 으로 인자 파싱하므로 단순 join 으로 충분
    # (venv 등 경로에 공백 없다는 일반 가정 — 있으면 systemd 'double-quoted' 문법 필요)
    POST_ARGS_STR=""
    for a in "${POST_ARGS[@]}"; do POST_ARGS_STR+=" $a"; done

    cat > "$SVC_PATH" << SVCEOF
[Unit]
Description=setup_gpu.sh post-reboot phase (one-shot, self-cleaning)
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=no
# SUDO_USER 를 명시 — 스크립트가 venv pip install 시 sudo -u 로 활용
Environment=SUDO_USER=${REAL_USER}
# 직접 인자 전달 (bash -c 의 single-quote 이스케이프 함정 회피)
ExecStart=/bin/bash ${SCRIPT_PATH}${POST_ARGS_STR}
StandardOutput=append:/var/log/setup_gpu_resume.log
StandardError=append:/var/log/setup_gpu_resume.log

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    success "post phase 자동 실행 서비스 등록: $SVC_NAME"
    info "  로그: /var/log/setup_gpu_resume.log (재부팅 후 추가됨)"
    info "  10초 후 자동 재부팅 — Ctrl+C 로 취소 가능"
    sleep 10
    reboot

  elif ! $NO_REBOOT; then
    echo -e "${BOLD}▶ 재부팅 후 확인:${NC}"
    echo "  nvidia-smi"
    [[ -n "$VENV_PATH" ]] && \
      echo "  sudo bash $0 --phase post --venv ${VENV_PATH}"
    echo ""
    # 비대화형(예: 다른 스크립트에서 호출) 환경에선 자동 재부팅 안 함 — 안내만
    if [[ ! -t 0 ]]; then
      info "비대화형 환경 감지 — 자동 재부팅 안 함. 수동 'sudo reboot' 후 '--phase post' 실행"
    else
      read -rp "  ▶ 지금 재부팅하시겠습니까? (y/N) " RB
      if [[ "$RB" =~ ^[yY]$ ]]; then
        info "10초 후 재부팅..."; sleep 10
        reboot
      else
        info "수동 재부팅 후 'sudo bash $0 --phase post --venv ${VENV_PATH:-<venv>}' 실행"
      fi
    fi
  else
    info "(--no-reboot) 수동 재부팅 필요: sudo reboot"
    info "  재부팅 후: sudo bash $0 --phase post --venv ${VENV_PATH:-<venv>}"
  fi
else
  echo ""
  if command -v nvidia-smi &>/dev/null; then
    nvidia-smi 2>&1 | head -12 || true
  fi
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅  NVIDIA GPU 셋업 완료                                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}▶ 진단:${NC}     sudo bash $0 --check"
echo -e "${BOLD}▶ 가용:${NC}     nvidia-smi"
echo -e "${BOLD}▶ Apptainer GPU:${NC}  apptainer instance start --nv ..."
echo ""
