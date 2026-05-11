#!/bin/bash
# ============================================================
#  prevent_sleep.sh  v2
#  Ubuntu 시스템 잠금 / 슬립 / 절전 완전 비활성화 스크립트
#  Target: Ubuntu 24.04 LTS (20.04 / 22.04 / X11 & Wayland)
#
#  커버 범위:
#   1. systemd-logind      (lid switch / power key / idle)
#   2. systemd sleep targets 마스킹
#   3. systemd sleep.conf  (AllowSuspend=no 등)
#   4. UPower              (배터리 임계 동작 차단)
#   5. acpid               (하드웨어 이벤트 핸들러 오버라이드)
#   6. X11 DPMS / xset     (.xprofile 영구 적용)
#   7. Xorg.conf           (DPMS 하드웨어 비활성화)
#   8. GNOME gsettings     (screensaver / power / lock / lid)
#   9. KDE Plasma          (kscreenlocker / powerdevil)
#  10. XFCE               (xfce4-power-manager)
#  11. MATE               (mate-screensaver / mate-power-manager)
#  12. Cinnamon           (cinnamon-screensaver)
#  13. xscreensaver       (데몬 비활성화)
#  14. light-locker       (데몬 비활성화)
#  15. xautolock          (데몬 비활성화)
#  16. GDM / LightDM      (lock-on-suspend 차단)
#  17. systemd-inhibit    (always-on guard 서비스)
# ============================================================

set -euo pipefail

# ── 색상 헬퍼 ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
skip()    { echo -e "        ${YELLOW}↷ skip${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── 권한 확인 ─────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "sudo 로 실행하세요:  sudo bash $0"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

info "대상 사용자 : $REAL_USER  ($REAL_HOME)"

# ── 현재 세션 환경 탐지 ───────────────────────────────────────
detect_session() {
  DESKTOP=""
  for proc in gnome-session plasmashell xfce4-session mate-session cinnamon-session; do
    if pgrep -u "$REAL_USER" "$proc" &>/dev/null; then
      case "$proc" in
        gnome-session)    DESKTOP="gnome"    ;;
        plasmashell)      DESKTOP="kde"      ;;
        xfce4-session)    DESKTOP="xfce"     ;;
        mate-session)     DESKTOP="mate"     ;;
        cinnamon-session) DESKTOP="cinnamon" ;;
      esac
      break
    fi
  done
  # XDG_CURRENT_DESKTOP 폴백
  if [[ -z "$DESKTOP" ]]; then
    local xdg
    xdg=$(sudo -u "$REAL_USER" printenv XDG_CURRENT_DESKTOP 2>/dev/null || echo "")
    case "${xdg,,}" in
      *gnome*)        DESKTOP="gnome"    ;;
      *kde*|*plasma*) DESKTOP="kde"      ;;
      *xfce*)         DESKTOP="xfce"     ;;
      *mate*)         DESKTOP="mate"     ;;
      *cinnamon*)     DESKTOP="cinnamon" ;;
    esac
  fi
  info "감지된 데스크탑 환경: ${DESKTOP:-알 수 없음 (비 DE / tty)}"
}
detect_session

# ── DBus 세션 주소 탐색 ───────────────────────────────────────
get_dbus_addr() {
  local pid=""
  for proc in gnome-session plasmashell xfce4-session mate-session dbus-daemon; do
    pid=$(pgrep -u "$REAL_USER" "$proc" 2>/dev/null | head -1 || true)
    [[ -n "$pid" ]] && break
  done
  [[ -z "$pid" ]] && { echo ""; return; }
  grep -z DBUS_SESSION_BUS_ADDRESS /proc/$pid/environ 2>/dev/null \
    | tr '\0' '\n' | grep DBUS_SESSION_BUS_ADDRESS | cut -d= -f2- || echo ""
}
DBUS_ADDR=$(get_dbus_addr)

run_as_user() {
  if [[ -n "$DBUS_ADDR" ]]; then
    sudo -u "$REAL_USER" env DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" HOME="$REAL_HOME" "$@" 2>/dev/null
  else
    sudo -u "$REAL_USER" HOME="$REAL_HOME" "$@" 2>/dev/null
  fi
}

# ════════════════════════════════════════════════════════════
# [1] systemd-logind
# ════════════════════════════════════════════════════════════
section "[1] systemd-logind (lid / power key / idle)"

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-no-sleep.conf << 'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
IdleActionSec=0
EOF
systemctl restart systemd-logind \
  && success "systemd-logind 재시작 완료" \
  || warn "재시작 실패 (재부팅 후 적용)"

# ════════════════════════════════════════════════════════════
# [2] systemd sleep targets 마스킹
# ════════════════════════════════════════════════════════════
section "[2] systemd sleep targets 마스킹"

for t in sleep.target suspend.target hibernate.target \
          hybrid-sleep.target suspend-then-hibernate.target; do
  systemctl mask "$t" && success "masked: $t" || warn "mask 실패: $t"
done

# ════════════════════════════════════════════════════════════
# [3] /etc/systemd/sleep.conf
# ════════════════════════════════════════════════════════════
section "[3] /etc/systemd/sleep.conf"

mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/99-no-sleep.conf << 'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF
success "sleep.conf.d/99-no-sleep.conf 작성 완료"

# ════════════════════════════════════════════════════════════
# [4] UPower — 배터리 임계·덮개 동작 차단
# ════════════════════════════════════════════════════════════
section "[4] UPower (/etc/UPower/UPower.conf)"

UPOWER_CONF="/etc/UPower/UPower.conf"
if [[ -f "$UPOWER_CONF" ]]; then
  patch_upower() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$UPOWER_CONF"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$UPOWER_CONF"
    elif grep -q "^#.*${key}=" "$UPOWER_CONF"; then
      sed -i "s|^#.*${key}=.*|${key}=${val}|" "$UPOWER_CONF"
    else
      echo "${key}=${val}" >> "$UPOWER_CONF"
    fi
  }
  patch_upower "IgnoreLid"              "true"
  patch_upower "PercentageCritical"     "2"
  patch_upower "PercentageAction"       "1"
  # CriticalPowerAction → HybridSleep(마스킹됨) 으로 우회 차단
  patch_upower "CriticalPowerAction"    "HybridSleep"
  systemctl restart upower 2>/dev/null \
    && success "UPower 재시작 완료" || warn "UPower 재시작 실패"
else
  warn "$UPOWER_CONF 없음 — UPower 미설치 (건너뜁니다)"
fi

# ════════════════════════════════════════════════════════════
# [5] acpid — 하드웨어 이벤트(덮개 닫기) 오버라이드
# ════════════════════════════════════════════════════════════
section "[5] acpid 덮개 이벤트 오버라이드"

if command -v acpid &>/dev/null; then
  LID_EVENT_DIR="/etc/acpi/events"
  if [[ -d "$LID_EVENT_DIR" ]]; then
    for f in "$LID_EVENT_DIR"/*; do
      [[ -f "$f" ]] || continue
      if grep -qiE "lid|button/lid" "$f"; then
        cp -f "$f" "${f}.bak-nosleep"
        sed -i 's|^action=.*|action=/bin/true|i' "$f"
        success "acpid 이벤트 무력화: $(basename "$f")"
      fi
    done
  fi
  mkdir -p /etc/acpi/events
  cat > /etc/acpi/events/99-nosleep-lid << 'EOF'
event=button/lid.*
action=/bin/true
EOF
  cat > /etc/acpi/events/99-nosleep-sleep << 'EOF'
event=button/sleep.*
action=/bin/true
EOF
  systemctl restart acpid 2>/dev/null \
    && success "acpid 재시작 완료" || warn "acpid 재시작 실패"
else
  skip "acpid (미설치)"
fi

# ════════════════════════════════════════════════════════════
# [6] X11 DPMS & xset — .xprofile 영구 적용 + xorg.conf.d
# ════════════════════════════════════════════════════════════
section "[6] X11 DPMS / xset"

XPROFILE="$REAL_HOME/.xprofile"
MARKER_B="# >>> prevent-sleep-xset-begin <<<"
MARKER_E="# >>> prevent-sleep-xset-end <<<"

# 기존 블록 제거
if [[ -f "$XPROFILE" ]]; then
  python3 - "$XPROFILE" "$MARKER_B" "$MARKER_E" << 'PYEOF'
import sys
path, begin, end = sys.argv[1:]
with open(path) as f:
    lines = f.readlines()
out, inside = [], False
for l in lines:
    if begin in l: inside = True
    if not inside: out.append(l)
    if end in l: inside = False
with open(path, 'w') as f:
    f.writelines(out)
PYEOF
fi

sudo -u "$REAL_USER" touch "$XPROFILE"
cat >> "$XPROFILE" << 'XEOF'

# >>> prevent-sleep-xset-begin <<<
# X11 화면 보호기 / DPMS 비활성화 (재로그인마다 자동 적용)
if command -v xset &>/dev/null && [ -n "${DISPLAY:-}" ]; then
  xset s off          # 스크린세이버 끄기
  xset s noblank      # 화면 블랙아웃 방지
  xset -dpms          # DPMS 에너지 절약 모드 끄기
  xset dpms 0 0 0     # DPMS 타이머 전부 0 (무한)
fi
# >>> prevent-sleep-xset-end <<<
XEOF
chown "$REAL_USER:$REAL_USER" "$XPROFILE"
success "~/.xprofile xset 설정 완료"

# Xorg 전역 설정 (하드웨어 레벨 DPMS)
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-no-dpms.conf << 'EOF'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Monitor"
    Identifier "all-monitors"
    Option "DPMS" "false"
EndSection
EOF
success "/etc/X11/xorg.conf.d/99-no-dpms.conf 작성 완료"

# 현재 세션에 즉시 적용 (X 세션이 살아있으면)
DISP=$(sudo -u "$REAL_USER" printenv DISPLAY 2>/dev/null || echo "")
if [[ -n "$DISP" ]] && command -v xset &>/dev/null; then
  run_as_user xset -display "$DISP" s off     && \
  run_as_user xset -display "$DISP" s noblank && \
  run_as_user xset -display "$DISP" -dpms     && \
  run_as_user xset -display "$DISP" dpms 0 0 0 && \
  success "현재 X 세션에 xset 즉시 적용" \
  || warn "xset 즉시 적용 실패 (재로그인 후 .xprofile에서 적용)"
fi

# ════════════════════════════════════════════════════════════
# [7] GNOME gsettings
# ════════════════════════════════════════════════════════════
section "[7] GNOME gsettings"

if [[ "$DESKTOP" == "gnome" ]] || command -v gsettings &>/dev/null; then
  gs() { run_as_user gsettings set "$@" || true; }

  gs org.gnome.desktop.screensaver              lock-enabled                            false
  gs org.gnome.desktop.screensaver              idle-activation-enabled                 false
  gs org.gnome.desktop.screensaver              lock-delay                              0
  gs org.gnome.desktop.session                  idle-delay                              0
  gs org.gnome.settings-daemon.plugins.power    sleep-inactive-ac-type                  nothing
  gs org.gnome.settings-daemon.plugins.power    sleep-inactive-battery-type             nothing
  gs org.gnome.settings-daemon.plugins.power    sleep-inactive-ac-timeout               0
  gs org.gnome.settings-daemon.plugins.power    sleep-inactive-battery-timeout          0
  gs org.gnome.settings-daemon.plugins.power    idle-dim                                false
  gs org.gnome.settings-daemon.plugins.power    power-button-action                     nothing
  gs org.gnome.settings-daemon.plugins.power    lid-close-ac-action                     nothing
  gs org.gnome.settings-daemon.plugins.power    lid-close-battery-action                nothing
  gs org.gnome.settings-daemon.plugins.power    lid-close-suspend-with-external-monitor false

  # GDM dconf (잠금 화면 비활성화)
  if [[ -d /etc/gdm3 ]]; then
    mkdir -p /etc/dconf/db/gdm.d
    cat > /etc/dconf/db/gdm.d/99-no-sleep << 'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
lid-close-ac-action='nothing'
lid-close-battery-action='nothing'
EOF
    dconf update 2>/dev/null && success "GDM dconf 업데이트 완료" || true
  fi

  success "GNOME gsettings 적용 완료"
else
  skip "GNOME gsettings (GNOME 환경 아님)"
fi

# ════════════════════════════════════════════════════════════
# [8] KDE Plasma — kscreenlocker / powerdevil
# ════════════════════════════════════════════════════════════
section "[8] KDE Plasma (kscreenlocker / powerdevil)"

if [[ "$DESKTOP" == "kde" ]] || command -v kscreenlocker_greet &>/dev/null 2>&1; then
  # kscreenlocker
  KDE_LOCKER_CFG="$REAL_HOME/.config/kscreenlockerrc"
  sudo -u "$REAL_USER" mkdir -p "$(dirname "$KDE_LOCKER_CFG")"
  python3 - "$KDE_LOCKER_CFG" << 'PYEOF'
import sys, configparser, os
path = sys.argv[1]
cfg = configparser.RawConfigParser()
cfg.optionxform = str
if os.path.exists(path):
    cfg.read(path)
if not cfg.has_section('Daemon'):
    cfg.add_section('Daemon')
cfg.set('Daemon', 'Autolock',    'false')
cfg.set('Daemon', 'LockOnResume','false')
cfg.set('Daemon', 'Timeout',     '0')
with open(path, 'w') as f:
    cfg.write(f)
PYEOF
  chown "$REAL_USER:$REAL_USER" "$KDE_LOCKER_CFG"
  success "kscreenlockerrc 적용"

  # powerdevil
  KDE_POWER_CFG="$REAL_HOME/.config/powermanagementprofilesrc"
  sudo -u "$REAL_USER" mkdir -p "$(dirname "$KDE_POWER_CFG")"
  python3 - "$KDE_POWER_CFG" << 'PYEOF'
import sys, configparser, os
path = sys.argv[1]
cfg = configparser.RawConfigParser()
cfg.optionxform = str
if os.path.exists(path):
    cfg.read(path)
for profile in ['AC', 'Battery', 'LowBattery']:
    for section in [f'{profile}/DPMSControl', f'{profile}/SuspendSession',
                    f'{profile}/HandleButtonEvents']:
        if not cfg.has_section(section):
            cfg.add_section(section)
    cfg.set(f'{profile}/DPMSControl',       'idleTime',          '0')
    cfg.set(f'{profile}/DPMSControl',       'lockBeforeTurnOff', '0')
    cfg.set(f'{profile}/SuspendSession',    'idleTime',          '0')
    cfg.set(f'{profile}/SuspendSession',    'suspendType',       '0')
    cfg.set(f'{profile}/HandleButtonEvents','lidAction',         '0')
    cfg.set(f'{profile}/HandleButtonEvents','powerButtonAction', '0')
with open(path, 'w') as f:
    cfg.write(f)
PYEOF
  chown "$REAL_USER:$REAL_USER" "$KDE_POWER_CFG"
  success "KDE powerdevil 프로필 적용"
  run_as_user qdbus org.kde.screensaver /ScreenSaver configure 2>/dev/null || true
else
  skip "KDE Plasma (KDE 환경 아님)"
fi

# ════════════════════════════════════════════════════════════
# [9] XFCE — xfce4-power-manager
# ════════════════════════════════════════════════════════════
section "[9] XFCE (xfce4-power-manager)"

if [[ "$DESKTOP" == "xfce" ]] || command -v xfce4-power-manager &>/dev/null; then
  XFCE_POWER_CFG="$REAL_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"
  sudo -u "$REAL_USER" mkdir -p "$(dirname "$XFCE_POWER_CFG")"
  cat > "$XFCE_POWER_CFG" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="power-button-action"          type="uint"   value="0"/>
    <property name="sleep-button-action"          type="uint"   value="0"/>
    <property name="hibernate-button-action"      type="uint"   value="0"/>
    <property name="lid-action-on-ac"             type="uint"   value="0"/>
    <property name="lid-action-on-battery"        type="uint"   value="0"/>
    <property name="blank-on-ac"                  type="int"    value="0"/>
    <property name="blank-on-battery"             type="int"    value="0"/>
    <property name="dpms-on-ac-sleep"             type="uint"   value="0"/>
    <property name="dpms-on-ac-off"               type="uint"   value="0"/>
    <property name="dpms-on-battery-sleep"        type="uint"   value="0"/>
    <property name="dpms-on-battery-off"          type="uint"   value="0"/>
    <property name="dpms-enabled"                 type="bool"   value="false"/>
    <property name="inactivity-on-ac"             type="uint"   value="0"/>
    <property name="inactivity-on-battery"        type="uint"   value="0"/>
    <property name="inactivity-sleep-mode-on-ac"  type="uint"   value="0"/>
  </property>
</channel>
EOF
  chown "$REAL_USER:$REAL_USER" "$XFCE_POWER_CFG"
  if command -v xfconf-query &>/dev/null; then
    for prop in lid-action-on-ac lid-action-on-battery blank-on-ac blank-on-battery \
                dpms-on-ac-sleep dpms-on-ac-off dpms-on-battery-sleep dpms-on-battery-off \
                inactivity-on-ac inactivity-on-battery; do
      run_as_user xfconf-query -c xfce4-power-manager \
        -p "/xfce4-power-manager/$prop" -s 0 2>/dev/null || true
    done
    run_as_user xfconf-query -c xfce4-power-manager \
      -p "/xfce4-power-manager/dpms-enabled" -s false 2>/dev/null || true
  fi
  success "xfce4-power-manager 설정 완료"
else
  skip "XFCE (XFCE 환경 아님)"
fi

# ════════════════════════════════════════════════════════════
# [10] MATE — mate-screensaver / mate-power-manager
# ════════════════════════════════════════════════════════════
section "[10] MATE (mate-screensaver / mate-power-manager)"

if [[ "$DESKTOP" == "mate" ]] || command -v mate-screensaver &>/dev/null; then
  gm() { run_as_user gsettings set "$@" || true; }
  gm org.mate.screensaver     idle-activation-enabled  false
  gm org.mate.screensaver     lock-enabled             false
  gm org.mate.session         idle-delay               0
  gm org.mate.power-manager   sleep-computer-ac        0
  gm org.mate.power-manager   sleep-computer-battery   0
  gm org.mate.power-manager   sleep-display-ac         0
  gm org.mate.power-manager   sleep-display-battery    0
  gm org.mate.power-manager   lid-close-ac-action      nothing
  gm org.mate.power-manager   lid-close-battery-action nothing
  success "MATE gsettings 적용 완료"
else
  skip "MATE (MATE 환경 아님)"
fi

# ════════════════════════════════════════════════════════════
# [11] Cinnamon — cinnamon-screensaver
# ════════════════════════════════════════════════════════════
section "[11] Cinnamon (cinnamon-screensaver)"

if [[ "$DESKTOP" == "cinnamon" ]] || command -v cinnamon-screensaver &>/dev/null; then
  gc() { run_as_user gsettings set "$@" || true; }
  gc org.cinnamon.desktop.screensaver              idle-activation-enabled  false
  gc org.cinnamon.desktop.screensaver              lock-enabled             false
  gc org.cinnamon.desktop.session                  idle-delay               0
  gc org.cinnamon.settings-daemon.plugins.power    sleep-inactive-ac-type      nothing
  gc org.cinnamon.settings-daemon.plugins.power    sleep-inactive-battery-type nothing
  gc org.cinnamon.settings-daemon.plugins.power    lid-close-ac-action         nothing
  gc org.cinnamon.settings-daemon.plugins.power    lid-close-battery-action    nothing
  success "Cinnamon gsettings 적용 완료"
else
  skip "Cinnamon (Cinnamon 환경 아님)"
fi

# ════════════════════════════════════════════════════════════
# [12] xscreensaver — 데몬 비활성화
# ════════════════════════════════════════════════════════════
section "[12] xscreensaver"

if command -v xscreensaver &>/dev/null; then
  for f in "$REAL_HOME/.config/autostart/xscreensaver.desktop" \
            /etc/xdg/autostart/xscreensaver.desktop; do
    if [[ -f "$f" ]]; then
      sed -i '/^Hidden=/d' "$f"
      sed -i '/^\[Desktop Entry\]/a Hidden=true' "$f"
      success "xscreensaver autostart 비활성화: $(basename "$f")"
    fi
  done
  XSCR_CFG="$REAL_HOME/.xscreensaver"
  sudo -u "$REAL_USER" touch "$XSCR_CFG"
  if grep -q "^timeout:" "$XSCR_CFG"; then
    sed -i 's|^timeout:.*|timeout: 0:00:00|' "$XSCR_CFG"
  else
    echo "timeout: 0:00:00" >> "$XSCR_CFG"
  fi
  if grep -q "^lock:" "$XSCR_CFG"; then
    sed -i 's|^lock:.*|lock: False|' "$XSCR_CFG"
  else
    echo "lock: False" >> "$XSCR_CFG"
  fi
  chown "$REAL_USER:$REAL_USER" "$XSCR_CFG"
  run_as_user xscreensaver-command -exit 2>/dev/null || true
  success "xscreensaver 비활성화 완료"
else
  skip "xscreensaver (미설치)"
fi

# ════════════════════════════════════════════════════════════
# [13] light-locker — 데몬 비활성화
# ════════════════════════════════════════════════════════════
section "[13] light-locker"

if command -v light-locker &>/dev/null; then
  for f in "$REAL_HOME/.config/autostart/light-locker.desktop" \
            /etc/xdg/autostart/light-locker.desktop; do
    if [[ -f "$f" ]]; then
      sed -i '/^Hidden=/d' "$f"
      sed -i '/^\[Desktop Entry\]/a Hidden=true' "$f"
      success "light-locker autostart 비활성화: $(basename "$f")"
    fi
  done
  pkill -u "$REAL_USER" light-locker 2>/dev/null || true
  success "light-locker 프로세스 종료"
else
  skip "light-locker (미설치)"
fi

# ════════════════════════════════════════════════════════════
# [14] xautolock — 데몬 비활성화
# ════════════════════════════════════════════════════════════
section "[14] xautolock"

if command -v xautolock &>/dev/null; then
  for f in "$REAL_HOME/.config/autostart/xautolock.desktop" \
            /etc/xdg/autostart/xautolock.desktop; do
    if [[ -f "$f" ]]; then
      sed -i '/^Hidden=/d' "$f"
      sed -i '/^\[Desktop Entry\]/a Hidden=true' "$f"
      success "xautolock autostart 비활성화: $(basename "$f")"
    fi
  done
  pkill -u "$REAL_USER" xautolock 2>/dev/null || true
  success "xautolock 프로세스 종료"
else
  skip "xautolock (미설치)"
fi

# ════════════════════════════════════════════════════════════
# [15] GDM / LightDM — lock-on-suspend 차단
# ════════════════════════════════════════════════════════════
section "[15] 디스플레이 매니저 (GDM / LightDM)"

if [[ -d /etc/gdm3 ]]; then
  mkdir -p /etc/dconf/db/gdm.d
  # [7]에서 이미 작성됨 — dconf update 재실행
  dconf update 2>/dev/null && success "GDM dconf 재적용 완료" || true
fi

if [[ -f /etc/lightdm/lightdm.conf ]]; then
  LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
  if grep -q "^lock-on-suspend" "$LIGHTDM_CONF"; then
    sed -i 's|^lock-on-suspend.*|lock-on-suspend=false|' "$LIGHTDM_CONF"
  else
    echo "lock-on-suspend=false" >> "$LIGHTDM_CONF"
  fi
  success "LightDM lock-on-suspend=false 적용"
fi

if [[ ! -d /etc/gdm3 ]] && [[ ! -f /etc/lightdm/lightdm.conf ]]; then
  skip "GDM/LightDM 설정 파일 없음"
fi

# ════════════════════════════════════════════════════════════
# [16] systemd-inhibit always-on guard 서비스
# ════════════════════════════════════════════════════════════
section "[16] systemd-inhibit always-on guard 서비스"

cat > /etc/systemd/system/prevent-sleep.service << 'EOF'
[Unit]
Description=Prevent system sleep/suspend/hibernate (always-on guard)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-inhibit \
  --what=sleep:idle:handle-lid-switch:handle-power-key:handle-suspend-key:handle-hibernate-key \
  --who="prevent-sleep" \
  --why="Always-on mode enabled" \
  --mode=block \
  /bin/sleep infinity
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prevent-sleep.service \
  && success "prevent-sleep.service 활성화 및 시작 완료" \
  || warn "prevent-sleep.service 시작 실패"

# ════════════════════════════════════════════════════════════
# 완료
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  모든 절전/잠금 설정 비활성화 완료!  v2          ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
printf "  %-5s %-22s %s\n" "[1]"  "systemd-logind"       "lid/power key/idle → ignore"
printf "  %-5s %-22s %s\n" "[2]"  "sleep targets"        "suspend/hibernate 마스킹"
printf "  %-5s %-22s %s\n" "[3]"  "sleep.conf"           "AllowSuspend=no 외 3종"
printf "  %-5s %-22s %s\n" "[4]"  "UPower"               "배터리 임계·IgnoreLid"
printf "  %-5s %-22s %s\n" "[5]"  "acpid"                "덮개·슬립 이벤트 noop"
printf "  %-5s %-22s %s\n" "[6]"  "X11 DPMS/xset"        ".xprofile + xorg.conf.d"
printf "  %-5s %-22s %s\n" "[7]"  "GNOME gsettings"      "screensaver/power/lock/lid"
printf "  %-5s %-22s %s\n" "[8]"  "KDE Plasma"           "kscreenlocker/powerdevil"
printf "  %-5s %-22s %s\n" "[9]"  "XFCE"                 "xfce4-power-manager"
printf "  %-5s %-22s %s\n" "[10]" "MATE"                 "mate-screensaver/power"
printf "  %-5s %-22s %s\n" "[11]" "Cinnamon"             "cinnamon-screensaver"
printf "  %-5s %-22s %s\n" "[12]" "xscreensaver"         "데몬 비활성화"
printf "  %-5s %-22s %s\n" "[13]" "light-locker"         "데몬 비활성화"
printf "  %-5s %-22s %s\n" "[14]" "xautolock"            "데몬 비활성화"
printf "  %-5s %-22s %s\n" "[15]" "GDM/LightDM"          "lock-on-suspend=false"
printf "  %-5s %-22s %s\n" "[16]" "prevent-sleep.service" "systemd-inhibit 데몬"
echo ""
warn "X11 DPMS(.xprofile) / KDE / XFCE 일부 설정은 재로그인 후 완전히 적용됩니다."
echo ""
