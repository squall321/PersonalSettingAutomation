#!/bin/bash
# ============================================================
#  check_vnc.sh  —  VNC 서비스 상태 진단 스크립트
#  사용법: bash check_vnc.sh
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
sep()  { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

REAL_USER="${SUDO_USER:-$USER}"

# ── [1] 포트 리스닝 ──────────────────────────────────────────
sep "포트 리스닝 상태"
for port in 5900 5905; do
  if ss -tlnp 2>/dev/null | grep -q ":${port}"; then
    PROC=$(ss -tlnp | grep ":${port}" | grep -oP 'users:\(\("\K[^"]+' || echo "?")
    ok "포트 ${port} LISTEN  ← ${PROC}"
  else
    fail "포트 ${port} LISTEN 안됨"
  fi
done

# ── [2] 서비스 상태 ──────────────────────────────────────────
sep "systemd 서비스 상태"

X11SVC="x11vnc-mirror"
TIGERSVC="tigervnc-${REAL_USER}"

for svc in "$X11SVC" "$TIGERSVC"; do
  if ! systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
    warn "${svc}: 서비스 파일 없음 (setup_vnc.sh 미실행)"
    continue
  fi
  STATE=$(systemctl is-active "$svc" 2>/dev/null)
  ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null)
  if [[ "$STATE" == "active" ]]; then
    ok "${svc}: active (enabled=${ENABLED})"
  else
    fail "${svc}: ${STATE} (enabled=${ENABLED})"
    info "  → 재시작: sudo systemctl restart ${svc}"
  fi
done

# ── [3] 세션 타입 (Wayland vs X11) ───────────────────────────
sep "현재 세션 타입"
SESSION_ID=$(loginctl list-sessions 2>/dev/null | awk -v u="$REAL_USER" '$0~u{print $1; exit}')
if [[ -n "$SESSION_ID" ]]; then
  SESSION_TYPE=$(loginctl show-session "$SESSION_ID" -p Type --value 2>/dev/null || echo "unknown")
  if [[ "$SESSION_TYPE" == "wayland" ]]; then
    fail "현재 세션: Wayland → x11vnc(5900) 연결 불가"
    warn "  로그아웃 후 재로그인 → 로그인 화면 ⚙️ → 'Ubuntu on Xorg' 선택"
  elif [[ "$SESSION_TYPE" == "x11" ]]; then
    ok "현재 세션: X11 → x11vnc 정상 동작 가능"
  else
    warn "현재 세션 타입: ${SESSION_TYPE}"
  fi
else
  warn "현재 로그인된 GUI 세션 없음 (x11vnc는 동작 안 함, TigerVNC는 무관)"
fi

# ── [4] GDM Wayland 설정 ─────────────────────────────────────
sep "GDM Wayland 비활성화 설정"
GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "$GDM_CONF" ]]; then
  if grep -q "^WaylandEnable=false" "$GDM_CONF"; then
    ok "WaylandEnable=false 설정됨 (다음 로그인부터 X11)"
  else
    fail "WaylandEnable=false 미설정 → setup_vnc.sh 재실행 필요"
  fi
else
  warn "GDM 설정 파일 없음 ($GDM_CONF)"
fi

# ── [5] UFW 방화벽 ───────────────────────────────────────────
sep "UFW 방화벽"
if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null)
  if echo "$UFW_STATUS" | grep -q "Status: active"; then
    for port in 5900 5905; do
      if echo "$UFW_STATUS" | grep -q "${port}"; then
        ok "UFW 포트 ${port} 허용됨"
      else
        fail "UFW 포트 ${port} 차단 → sudo ufw allow ${port}/tcp"
      fi
    done
  else
    warn "UFW 비활성화 상태 (방화벽 없음 — 포트 차단 없음)"
  fi
else
  warn "UFW 미설치"
fi

# ── [6] VNC 로그 ─────────────────────────────────────────────
sep "TigerVNC 서비스 최근 로그"
journalctl -u "${TIGERSVC}" -n 20 --no-pager 2>/dev/null \
  || warn "로그 없음 (서비스 미등록)"

sep "TigerVNC 래퍼 로그"
TIGER_LOG="/var/log/tigervnc-${REAL_USER}.log"
if [[ -f "$TIGER_LOG" ]]; then
  tail -20 "$TIGER_LOG"
else
  warn "로그 파일 없음: ${TIGER_LOG}"
fi

sep "x11vnc 최근 로그"
LOG_FILE="/var/log/x11vnc-${REAL_USER}.log"
if [[ -f "$LOG_FILE" ]]; then
  tail -20 "$LOG_FILE"
else
  warn "로그 파일 없음: ${LOG_FILE}"
fi

# ── [7] ~/.vnc 로그 ──────────────────────────────────────────
sep "~/.vnc xstartup 로그"
VNC_LOGS=$(ls "$HOME/.vnc/"*.log 2>/dev/null)
if [[ -n "$VNC_LOGS" ]]; then
  tail -20 $(ls -t "$HOME/.vnc/"*.log 2>/dev/null | head -1)
else
  warn "~/.vnc/*.log 없음"
fi

# ── 요약 ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━  접속 가능 여부 요약  ━━━${NC}"
for port in 5900 5905; do
  if ss -tlnp 2>/dev/null | grep -q ":${port}"; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
    ok "접속 가능: ${SERVER_IP}:${port}"
  else
    fail "접속 불가: 포트 ${port} LISTEN 안됨"
  fi
done
echo ""
