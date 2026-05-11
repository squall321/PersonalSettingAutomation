#!/bin/bash
# ============================================================
#  clean_vnc.sh  —  VNC 잔여물 강제 정리 스크립트
#
#  setup_vnc.sh 가 만든 서비스/lock/소켓/PID/포트를 모두 청소합니다.
#  "Cannot establish any listening sockets" 류 잔존 lock 에러를
#  해결할 때 사용. sudo 권한 필수 (lock 파일이 root 소유일 수 있음).
#
#  사용법:
#    sudo bash clean_vnc.sh                  # 기본 :1, :2 모두 청소
#    sudo bash clean_vnc.sh --disp 1         # :1 만
#    sudo bash clean_vnc.sh --disp 1,2,3     # :1, :2, :3
#    sudo bash clean_vnc.sh --port 5900,5901 # 특정 포트 강제 회수
#    sudo bash clean_vnc.sh --restart        # 청소 후 서비스 자동 재시작
#    sudo bash clean_vnc.sh --hard           # ~/.vnc/*.log, *.pid 까지 삭제
# ============================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── 권한 ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "sudo 로 실행하세요:  sudo bash $0 $*"
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
[[ "$REAL_USER" == "root" ]] && { err "SUDO_USER 가 없습니다. 'sudo bash $0' 형태로 실행하세요."; exit 1; }
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ── 인수 파싱 ──────────────────────────────────────────────────
DISPS="1,2"
PORTS=""
RESTART=false
HARD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disp)    DISPS="$2";  shift 2 ;;
    --port)    PORTS="$2";  shift 2 ;;
    --restart) RESTART=true; shift ;;
    --hard)    HARD=true;    shift ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) warn "알 수 없는 옵션 무시: $1"; shift ;;
  esac
done

# 콤마 분리 → 배열
IFS=',' read -ra DISP_ARR <<< "$DISPS"

info "대상 사용자: $REAL_USER"
info "정리 대상 디스플레이: :${DISPS//,/, :}"
[[ -n "$PORTS" ]] && info "추가 회수 포트: $PORTS"
$RESTART && info "옵션: 청소 후 서비스 자동 재시작"
$HARD    && info "옵션: HARD — ~/.vnc/*.log, *.pid 까지 삭제"

# ── [1] systemd 서비스 정지 ────────────────────────────────────
section "[1] systemd 서비스 정지"

X11SVC="x11vnc-mirror"
TIGERSVC="tigervnc-${REAL_USER}"

for svc in "$X11SVC" "$TIGERSVC"; do
  if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
    if systemctl is-active "$svc" &>/dev/null; then
      systemctl stop "$svc" 2>/dev/null && ok "$svc 정지" || warn "$svc 정지 실패"
    else
      info "$svc 이미 비활성"
    fi
  else
    info "$svc 미설치 (skip)"
  fi
done

# ── [2] vncserver -kill (사용자 컨텍스트 정상 종료 시도) ──────
section "[2] vncserver -kill 시도"

if command -v vncserver &>/dev/null; then
  for d in "${DISP_ARR[@]}"; do
    OUT=$(sudo -u "$REAL_USER" vncserver -kill ":$d" 2>&1)
    if echo "$OUT" | grep -qi "killing"; then
      ok ":$d 정상 종료"
    elif echo "$OUT" | grep -qi "No matching"; then
      info ":$d 실행 중 아님"
    else
      warn ":$d kill 결과: $OUT"
    fi
  done
else
  info "vncserver 미설치 (skip)"
fi

# ── [3] 좀비 프로세스 강제 종료 ────────────────────────────────
section "[3] 잔여 Xvnc/x11vnc 프로세스 강제 종료"

for d in "${DISP_ARR[@]}"; do
  # Xvnc :1 형태 + 끝 boundary
  PIDS=$(pgrep -f "Xvnc.*:${d}( |$)" 2>/dev/null || true)
  if [[ -n "$PIDS" ]]; then
    kill -9 $PIDS 2>/dev/null
    ok "Xvnc :$d PID 종료: $PIDS"
  else
    info "Xvnc :$d 좀비 없음"
  fi
done

# x11vnc 는 디스플레이 인자가 다양해서 통째로 정리
X11_PIDS=$(pgrep -x x11vnc 2>/dev/null || true)
if [[ -n "$X11_PIDS" ]]; then
  kill -9 $X11_PIDS 2>/dev/null
  ok "x11vnc PID 종료: $X11_PIDS"
else
  info "x11vnc 좀비 없음"
fi

# ── [4] lock 파일 / X11 소켓 ──────────────────────────────────
section "[4] /tmp/.X*-lock, /tmp/.X11-unix/X* 정리"

for d in "${DISP_ARR[@]}"; do
  for f in "/tmp/.X${d}-lock" "/tmp/.X11-unix/X${d}"; do
    if [[ -e "$f" ]]; then
      OWNER=$(stat -c '%U' "$f" 2>/dev/null || echo "?")
      if rm -f "$f" 2>/dev/null; then
        ok "삭제: $f (소유자: $OWNER)"
      else
        warn "삭제 실패: $f"
      fi
    fi
  done
done

# ── [4-2] /tmp/.X11-unix 디렉토리 권한 보장 (1777) ────────────
# 권한이 잘못되어 있으면 Xvnc 가 자기 소켓을 못 만들어서
# '_XSERVTransSocketUNIXCreateListener ... failed' 에러로 즉사함.
# systemd-tmpfiles 가 부팅 시 만들어주지만 어쩌다 권한이 깨져있을 수 있음.
section "[4-2] /tmp/.X11-unix 디렉토리 권한 확인/복구"

if [[ ! -d /tmp/.X11-unix ]]; then
  mkdir -p /tmp/.X11-unix && ok "/tmp/.X11-unix 생성"
fi
CUR_PERM=$(stat -c '%a' /tmp/.X11-unix 2>/dev/null)
CUR_OWNER=$(stat -c '%U:%G' /tmp/.X11-unix 2>/dev/null)
if [[ "$CUR_PERM" != "1777" ]]; then
  warn "/tmp/.X11-unix 권한이 ${CUR_PERM} (정상: 1777) — 복구 시도"
  chown root:root /tmp/.X11-unix 2>/dev/null
  if chmod 1777 /tmp/.X11-unix 2>/dev/null; then
    ok "/tmp/.X11-unix → 1777 복구"
  else
    err "chmod 실패 — chattr +i 가 걸려있을 수 있음:"
    err "  lsattr -d /tmp/.X11-unix     로 확인 후"
    err "  sudo chattr -i /tmp/.X11-unix"
  fi
  # canonical 한 systemd-tmpfiles 적용 시도
  if command -v systemd-tmpfiles &>/dev/null; then
    systemd-tmpfiles --create /usr/lib/tmpfiles.d/x11.conf 2>/dev/null && \
      info "systemd-tmpfiles 재적용"
  fi
else
  ok "/tmp/.X11-unix 권한 정상 (1777, ${CUR_OWNER})"
fi

# ── [5] ~/.vnc/*.pid (해당 디스플레이만) ──────────────────────
section "[5] ~/.vnc/*.pid 정리"

VNC_DIR="$REAL_HOME/.vnc"
if [[ -d "$VNC_DIR" ]]; then
  for d in "${DISP_ARR[@]}"; do
    # vncserver 가 만드는 PID 파일: hostname:disp.pid
    for f in "$VNC_DIR"/*":${d}.pid"; do
      [[ -e "$f" ]] || continue
      rm -f "$f" && ok "삭제: $f"
    done
  done
  if $HARD; then
    rm -f "$VNC_DIR"/*.log "$VNC_DIR"/*.pid 2>/dev/null && \
      ok "HARD: ~/.vnc/*.log, *.pid 모두 삭제"
  fi
else
  info "~/.vnc 디렉토리 없음 (skip)"
fi

# ── [6] 포트 점유 회수 ────────────────────────────────────────
section "[6] 포트 점유 회수"

# 기본: 디스플레이 기반 포트 (590X) + 사용자 지정
PORT_LIST=()
for d in "${DISP_ARR[@]}"; do
  PORT_LIST+=("590$d")
done
if [[ -n "$PORTS" ]]; then
  IFS=',' read -ra USER_PORTS <<< "$PORTS"
  PORT_LIST+=("${USER_PORTS[@]}")
fi

for p in "${PORT_LIST[@]}"; do
  if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
    PROC=$(ss -tlnp | grep ":${p} " | grep -oP 'users:\(\("\K[^"]+' || echo "?")
    fuser -k "${p}/tcp" 2>/dev/null && \
      ok "포트 $p 회수 (점유: $PROC)" || \
      warn "포트 $p 회수 실패 (점유: $PROC)"
  else
    info "포트 $p 점유 없음"
  fi
done

# ── [7] 결과 확인 ─────────────────────────────────────────────
section "[7] 정리 후 상태"

CLEAN=true
for d in "${DISP_ARR[@]}"; do
  for f in "/tmp/.X${d}-lock" "/tmp/.X11-unix/X${d}"; do
    [[ -e "$f" ]] && { warn "남아있음: $f"; CLEAN=false; }
  done
done
for p in "${PORT_LIST[@]}"; do
  ss -tlnp 2>/dev/null | grep -q ":${p} " && { warn "포트 $p 아직 LISTEN"; CLEAN=false; }
done
PIDS_LEFT=$(pgrep -f 'Xvnc|x11vnc' 2>/dev/null || true)
[[ -n "$PIDS_LEFT" ]] && { warn "잔여 프로세스: $PIDS_LEFT"; CLEAN=false; }

$CLEAN && ok "모두 깨끗합니다 — VNC 재시작 가능 상태"

# ── [8] (선택) 재시작 ─────────────────────────────────────────
if $RESTART; then
  section "[8] 서비스 자동 재시작"
  systemctl daemon-reload
  for svc in "$TIGERSVC" "$X11SVC"; do
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
      if systemctl restart "$svc" 2>/dev/null; then
        ok "$svc 재시작"
        sleep 2
        STATE=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$STATE" == "active" ]]; then
          ok "$svc 상태: active"
        else
          warn "$svc 상태: $STATE → journalctl -u $svc -n 30"
        fi
      else
        err "$svc 재시작 실패 → journalctl -u $svc -n 30"
      fi
    fi
  done
fi

echo ""
ok "완료. 다음 단계:"
$RESTART || echo "  sudo systemctl restart ${TIGERSVC}"
echo "  ss -tlnp | grep -E '5900|5901'"
echo "  bash check_vnc.sh"
