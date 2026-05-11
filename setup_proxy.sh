#!/bin/bash
# ============================================================
#  setup_proxy.sh
#  YAML 기반 시스템 전체 프록시 자동 설정 스크립트
#  Target: Ubuntu 24.04 LTS (20.04 / 22.04 호환)
#
#  사용법:
#    sudo bash setup_proxy.sh [config.yaml]
#    (기본값: 스크립트와 같은 디렉토리의 proxy_config.yaml)
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/proxy_config.yaml}"

[[ -f "$CONFIG_FILE" ]] || error "설정 파일을 찾을 수 없습니다: $CONFIG_FILE"
CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

info "설정 파일  : $CONFIG_FILE"
info "대상 사용자: $REAL_USER  ($REAL_HOME)"

# ── python3 가용 확인 (YAML 파싱용) ──────────────────────────
command -v python3 &>/dev/null || error "python3 가 필요합니다: sudo apt install python3"

# ════════════════════════════════════════════════════════════
#  YAML 파싱 함수 (python3 내장 모듈만 사용)
# ════════════════════════════════════════════════════════════
yaml_get() {
  # yaml_get <yaml_file> <dot.notation.key>
  local file="$1" key="$2"
  python3 - "$file" "$key" << 'PYEOF'
import sys, re

def parse_yaml_simple(path):
    """간단한 2-depth YAML 파서 (PyYAML 없이)"""
    data = {}
    current_section = None
    with open(path) as f:
        for raw in f:
            line = raw.rstrip()
            if not line or line.lstrip().startswith('#'):
                continue
            # 최상위 키
            m = re.match(r'^(\w[\w-]*):\s*(.*)', line)
            if m:
                current_section = m.group(1)
                val = m.group(2).strip()
                if val and not val.startswith('#'):
                    data[current_section] = val.strip('"\'')
                else:
                    data[current_section] = {}
                continue
            # 하위 키
            m = re.match(r'^\s{2,}([\w-]+):\s*(.*)', line)
            if m and isinstance(data.get(current_section), dict):
                k = m.group(1)
                v = m.group(2).strip().strip('"\'')
                if v.startswith('#'):
                    v = ''
                data[current_section][k] = v
    return data

file_path, key_path = sys.argv[1], sys.argv[2]
d = parse_yaml_simple(file_path)
keys = key_path.split('.')
val = d
for k in keys:
    if isinstance(val, dict):
        val = val.get(k, '')
    else:
        val = ''
        break
print(val if val is not None else '')
PYEOF
}

# ── 설정값 읽기 ───────────────────────────────────────────────
HTTP_PROXY=$(yaml_get "$CONFIG_FILE" "proxy.http")
HTTPS_PROXY=$(yaml_get "$CONFIG_FILE" "proxy.https")
NO_PROXY=$(yaml_get "$CONFIG_FILE" "proxy.no_proxy")
CRT_REL=$(yaml_get "$CONFIG_FILE" "certificate.crt_path")

[[ -n "$HTTP_PROXY"  ]] || error "proxy.http 가 비어 있습니다."
[[ -n "$HTTPS_PROXY" ]] || error "proxy.https 가 비어 있습니다."

# crt 절대경로 계산
CRT_ABS=""
if [[ -n "$CRT_REL" ]]; then
  CRT_ABS="$(cd "$CONFIG_DIR" && realpath -m "$CRT_REL")"
fi

# targets 읽기 함수
target_enabled() {
  local val
  val=$(yaml_get "$CONFIG_FILE" "targets.$1")
  [[ "$val" == "true" ]]
}

info "HTTP  프록시: $HTTP_PROXY"
info "HTTPS 프록시: $HTTPS_PROXY"
info "NO_PROXY    : $NO_PROXY"
info "인증서 경로 : ${CRT_ABS:-없음}"

# ════════════════════════════════════════════════════════════
#  인증서 설치 (CA 스토어)
# ════════════════════════════════════════════════════════════
section "인증서 설치"

INSTALLED_CERT_PATH=""
if [[ -n "$CRT_ABS" && -f "$CRT_ABS" ]]; then
  CERT_NAME="$(basename "$CRT_ABS")"
  # .crt 확장자 강제 (update-ca-certificates 요구사항)
  DEST_CERT="/usr/local/share/ca-certificates/${CERT_NAME%.crt}.crt"
  cp "$CRT_ABS" "$DEST_CERT"
  update-ca-certificates --fresh 2>&1 | grep -E 'added|removed|WARNING' || true
  INSTALLED_CERT_PATH="$DEST_CERT"
  success "CA 인증서 설치 완료: $DEST_CERT"
elif [[ -n "$CRT_REL" ]]; then
  warn "인증서 파일을 찾을 수 없습니다: $CRT_ABS (건너뜀)"
else
  info "인증서 없음 — 건너뜁니다."
fi

# ════════════════════════════════════════════════════════════
# 헬퍼: 사용자 파일에 블록 추가 (중복 방지)
# ════════════════════════════════════════════════════════════
MARKER_BEGIN="# >>> proxy-setup-begin <<<"
MARKER_END="# >>> proxy-setup-end <<<"

write_user_block() {
  # write_user_block <file> <content> [tag]
  local file="$1" content="$2" tag="${3:-default}"
  local mb="# >>> proxy-setup-${tag}-begin <<<"
  local me="# >>> proxy-setup-${tag}-end <<<"
  local dir
  dir="$(dirname "$file")"
  [[ -d "$dir" ]] || sudo -u "$REAL_USER" mkdir -p "$dir"
  [[ -f "$file" ]] || sudo -u "$REAL_USER" touch "$file"

  # 기존 블록 제거
  python3 - "$file" "$mb" "$me" << 'PYEOF'
import sys
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
out, inside = [], False
for l in lines:
    if begin in l:
        inside = True
    if not inside:
        out.append(l)
    if end in l:
        inside = False
with open(path, 'w') as f:
    f.writelines(out)
PYEOF

  # 새 블록 추가
  {
    echo ""
    echo "$mb"
    echo "$content"
    echo "$me"
  } >> "$file"
  chown "$REAL_USER:$REAL_USER" "$file"
}

write_root_block() {
  local file="$1" content="$2" tag="${3:-default}"
  local mb="# >>> proxy-setup-${tag}-begin <<<"
  local me="# >>> proxy-setup-${tag}-end <<<"
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || touch "$file"
  python3 - "$file" "$mb" "$me" << 'PYEOF'
import sys
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
out, inside = [], False
for l in lines:
    if begin in l:
        inside = True
    if not inside:
        out.append(l)
    if end in l:
        inside = False
with open(path, 'w') as f:
    f.writelines(out)
PYEOF
  {
    echo ""
    echo "$mb"
    echo "$content"
    echo "$me"
  } >> "$file"
}

# CA 인증서 경로 (설정용)
SYS_CERT_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

# ════════════════════════════════════════════════════════════
# [1] /etc/environment  — 시스템 전역
# ════════════════════════════════════════════════════════════
section "[1] 시스템 환경변수 (/etc/environment)"
if target_enabled "system"; then
  write_root_block "/etc/environment" \
"http_proxy=\"$HTTP_PROXY\"
https_proxy=\"$HTTPS_PROXY\"
HTTP_PROXY=\"$HTTP_PROXY\"
HTTPS_PROXY=\"$HTTPS_PROXY\"
no_proxy=\"$NO_PROXY\"
NO_PROXY=\"$NO_PROXY\"" "system"
  success "/etc/environment 적용"
else skip "system"; fi

# ════════════════════════════════════════════════════════════
# [2] APT
# ════════════════════════════════════════════════════════════
section "[2] APT"
if target_enabled "apt"; then
  CERT_LINE=""
  [[ -n "$INSTALLED_CERT_PATH" ]] && \
    CERT_LINE="Acquire::https::CaInfo \"$SYS_CERT_BUNDLE\";"
  write_root_block "/etc/apt/apt.conf.d/99-proxy" \
"Acquire::http::Proxy  \"$HTTP_PROXY\";
Acquire::https::Proxy \"$HTTPS_PROXY\";
${CERT_LINE}"
  success "/etc/apt/apt.conf.d/99-proxy 적용"
else skip "apt"; fi

# ════════════════════════════════════════════════════════════
# [3] Git (전역)
# ════════════════════════════════════════════════════════════
section "[3] Git"
if target_enabled "git"; then
  sudo -u "$REAL_USER" git config --global http.proxy  "$HTTP_PROXY"
  sudo -u "$REAL_USER" git config --global https.proxy "$HTTPS_PROXY"
  if [[ -n "$INSTALLED_CERT_PATH" ]]; then
    sudo -u "$REAL_USER" git config --global http.sslCAInfo "$SYS_CERT_BUNDLE"
  fi
  success "~/.gitconfig 적용"
else skip "git"; fi

# ════════════════════════════════════════════════════════════
# [4] npm
# ════════════════════════════════════════════════════════════
section "[4] npm"
if target_enabled "npm"; then
  # ~/.npmrc 는 단순 설정 파일 — npm CLI 가 root PATH 에 없어도(NVM 설치 등)
  # 미리 써두면 npm 설치/실행 시 자동으로 읽힘. command -v 게이트 제거.
  CERT_LINE=""
  [[ -n "$INSTALLED_CERT_PATH" ]] && \
    CERT_LINE="cafile=$SYS_CERT_BUNDLE"
  write_user_block "$REAL_HOME/.npmrc" \
"proxy=$HTTP_PROXY
https-proxy=$HTTPS_PROXY
noproxy=$NO_PROXY
${CERT_LINE}
strict-ssl=true"
  success "~/.npmrc 적용"
  if ! command -v npm &>/dev/null && ! sudo -u "$REAL_USER" bash -lc 'command -v npm' &>/dev/null; then
    info "  (참고) npm 미설치 상태 — 설치 후 즉시 적용됨"
  fi
else skip "npm"; fi

# ════════════════════════════════════════════════════════════
# [5] pip
# ════════════════════════════════════════════════════════════
section "[5] pip"
if target_enabled "pip"; then
  if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
    CERT_LINE=""
    [[ -n "$INSTALLED_CERT_PATH" ]] && \
      CERT_LINE="cert = $SYS_CERT_BUNDLE"
    write_user_block "$REAL_HOME/.config/pip/pip.conf" \
"[global]
proxy = $HTTP_PROXY
${CERT_LINE}"
    success "~/.config/pip/pip.conf 적용"
  else
    warn "pip 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "pip"; fi

# ════════════════════════════════════════════════════════════
# [6] Docker (systemd override)
# ════════════════════════════════════════════════════════════
section "[6] Docker"
if target_enabled "docker"; then
  if command -v docker &>/dev/null || systemctl list-units --all docker.service &>/dev/null 2>&1; then
    DOCKER_DROP="/etc/systemd/system/docker.service.d"
    mkdir -p "$DOCKER_DROP"
    cat > "$DOCKER_DROP/99-proxy.conf" << DOCKEREOF
[Service]
Environment="HTTP_PROXY=$HTTP_PROXY"
Environment="HTTPS_PROXY=$HTTPS_PROXY"
Environment="NO_PROXY=$NO_PROXY"
DOCKEREOF

    # Docker daemon 인증서
    if [[ -n "$INSTALLED_CERT_PATH" ]]; then
      PROXY_HOST=$(echo "$HTTPS_PROXY" | sed -E 's|https?://||;s|/.*||')
      DOCKER_CERT_DIR="/etc/docker/certs.d/$PROXY_HOST"
      mkdir -p "$DOCKER_CERT_DIR"
      cp "$INSTALLED_CERT_PATH" "$DOCKER_CERT_DIR/ca.crt"
      success "Docker 인증서 설치: $DOCKER_CERT_DIR/ca.crt"
    fi

    systemctl daemon-reload
    systemctl is-active docker &>/dev/null && systemctl restart docker || true
    success "/etc/systemd/system/docker.service.d/99-proxy.conf 적용"
  else
    warn "Docker 가 설치되어 있지 않습니다 — 건너뜁니다"
  fi
else skip "docker"; fi

# ════════════════════════════════════════════════════════════
# [7] snap
# ════════════════════════════════════════════════════════════
section "[7] snap"
if target_enabled "snap"; then
  if command -v snap &>/dev/null; then
    snap set system proxy.http="$HTTP_PROXY"   && \
    snap set system proxy.https="$HTTPS_PROXY" && \
    success "snap proxy 적용" || warn "snap 설정 실패"
  else
    warn "snap 이 설치되어 있지 않습니다 — 건너뜁니다"
  fi
else skip "snap"; fi

# ════════════════════════════════════════════════════════════
# [8] GNOME gsettings
# ════════════════════════════════════════════════════════════
section "[8] GNOME gsettings"
if target_enabled "gnome"; then
  if command -v gsettings &>/dev/null; then
    PROXY_HOST=$(echo "$HTTP_PROXY" | sed -E 's|https?://||;s|:.*||')
    PROXY_PORT=$(echo "$HTTP_PROXY" | sed -E 's|.*:([0-9]+).*|\1|')

    pid=$(pgrep -u "$REAL_USER" gnome-session 2>/dev/null | head -1 || true)
    DBUS_ADDR=""
    [[ -n "$pid" ]] && DBUS_ADDR=$(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$pid/environ 2>/dev/null \
      | tr '\0' '\n' | grep DBUS_SESSION_BUS_ADDRESS | cut -d= -f2- || true)

    run_gs() {
      if [[ -n "$DBUS_ADDR" ]]; then
        sudo -u "$REAL_USER" env DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" HOME="$REAL_HOME" gsettings "$@" 2>/dev/null
      else
        sudo -u "$REAL_USER" HOME="$REAL_HOME" gsettings "$@" 2>/dev/null
      fi
    }

    run_gs set org.gnome.system.proxy mode 'manual'
    run_gs set org.gnome.system.proxy.http  host "$PROXY_HOST"
    run_gs set org.gnome.system.proxy.http  port "$PROXY_PORT"
    run_gs set org.gnome.system.proxy.https host "$PROXY_HOST"
    run_gs set org.gnome.system.proxy.https port "$PROXY_PORT"
    # no_proxy 배열 변환: "a,b,c" → "['a','b','c']"
    NO_PROXY_GSETTINGS=$(python3 -c "
import sys
items = '$NO_PROXY'.split(',')
print('[' + ', '.join(repr(i.strip()) for i in items) + ']')
")
    run_gs set org.gnome.system.proxy ignore-hosts "$NO_PROXY_GSETTINGS"
    success "GNOME gsettings 프록시 적용"
  else
    warn "gsettings 없음 — 건너뜁니다"
  fi
else skip "gnome"; fi

# ════════════════════════════════════════════════════════════
# [9] wget
# ════════════════════════════════════════════════════════════
section "[9] wget (~/.wgetrc)"
if target_enabled "wget"; then
  # ~/.wgetrc 는 단순 설정 파일 — wget CLI 유무 무관
  CERT_LINE=""
  [[ -n "$INSTALLED_CERT_PATH" ]] && CERT_LINE="ca_certificate=$SYS_CERT_BUNDLE"
  write_user_block "$REAL_HOME/.wgetrc" \
"use_proxy=on
http_proxy=$HTTP_PROXY
https_proxy=$HTTPS_PROXY
no_proxy=$NO_PROXY
${CERT_LINE}"
  success "~/.wgetrc 적용"
else skip "wget"; fi

# ════════════════════════════════════════════════════════════
# [10] curl
# ════════════════════════════════════════════════════════════
section "[10] curl (~/.curlrc)"
if target_enabled "curl"; then
  # ~/.curlrc 는 단순 설정 파일 — curl CLI 유무 무관
  CERT_LINE=""
  [[ -n "$INSTALLED_CERT_PATH" ]] && CERT_LINE="cacert = $SYS_CERT_BUNDLE"
  write_user_block "$REAL_HOME/.curlrc" \
"proxy = $HTTP_PROXY
noproxy = $NO_PROXY
${CERT_LINE}"
  success "~/.curlrc 적용"
else skip "curl"; fi

# ════════════════════════════════════════════════════════════
# [11] conda
# ════════════════════════════════════════════════════════════
section "[11] conda (~/.condarc)"
if target_enabled "conda"; then
  if command -v conda &>/dev/null; then
    CERT_LINE=""
    [[ -n "$INSTALLED_CERT_PATH" ]] && CERT_LINE="ssl_verify: $SYS_CERT_BUNDLE"
    write_user_block "$REAL_HOME/.condarc" \
"proxy_servers:
  http:  $HTTP_PROXY
  https: $HTTPS_PROXY
${CERT_LINE}"
    success "~/.condarc 적용"
  else
    warn "conda 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "conda"; fi

# ════════════════════════════════════════════════════════════
# [12] Maven (~/.m2/settings.xml)
# ════════════════════════════════════════════════════════════
section "[12] Maven (~/.m2/settings.xml)"
if target_enabled "maven"; then
  if command -v mvn &>/dev/null; then
    MVN_SETTINGS="$REAL_HOME/.m2/settings.xml"
    sudo -u "$REAL_USER" mkdir -p "$(dirname "$MVN_SETTINGS")"

    PROXY_HOST=$(echo "$HTTP_PROXY"  | sed -E 's|https?://||;s|:.*||')
    PROXY_PORT=$(echo "$HTTP_PROXY"  | sed -E 's|.*:([0-9]+).*|\1|')
    SPROXY_HOST=$(echo "$HTTPS_PROXY" | sed -E 's|https?://||;s|:.*||')
    SPROXY_PORT=$(echo "$HTTPS_PROXY" | sed -E 's|.*:([0-9]+).*|\1|')

    if [[ ! -f "$MVN_SETTINGS" ]]; then
      sudo -u "$REAL_USER" cat > "$MVN_SETTINGS" << 'MVNEOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
          https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <proxies/>
</settings>
MVNEOF
    fi

    # Python으로 XML 패치
    python3 - "$MVN_SETTINGS" "$PROXY_HOST" "$PROXY_PORT" \
                              "$SPROXY_HOST" "$SPROXY_PORT" "$NO_PROXY" << 'PYEOF'
import sys, xml.etree.ElementTree as ET

ET.register_namespace('', 'http://maven.apache.org/SETTINGS/1.0.0')
ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
ns = 'http://maven.apache.org/SETTINGS/1.0.0'

path, hhost, hport, shost, sport, noproxy = sys.argv[1:]

tree = ET.parse(path)
root = tree.getroot()

proxies = root.find(f'{{{ns}}}proxies')
if proxies is None:
    proxies = ET.SubElement(root, f'{{{ns}}}proxies')

# 기존 proxy-setup 블록 제거
for p in proxies.findall(f'{{{ns}}}proxy'):
    if p.findtext(f'{{{ns}}}id', '').startswith('proxy-setup-'):
        proxies.remove(p)

for proto, host, port in [('http', hhost, hport), ('https', shost, sport)]:
    proxy = ET.SubElement(proxies, f'{{{ns}}}proxy')
    for tag, val in [('id', f'proxy-setup-{proto}'), ('active', 'true'),
                     ('protocol', proto), ('host', host), ('port', port),
                     ('nonProxyHosts', noproxy.replace(',', '|'))]:
        el = ET.SubElement(proxy, f'{{{ns}}}{tag}')
        el.text = val

ET.indent(tree, space='  ')
tree.write(path, xml_declaration=True, encoding='UTF-8')
print('ok')
PYEOF
    chown "$REAL_USER:$REAL_USER" "$MVN_SETTINGS"
    success "~/.m2/settings.xml 적용"
  else
    warn "Maven 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "maven"; fi

# ════════════════════════════════════════════════════════════
# [13] Gradle
# ════════════════════════════════════════════════════════════
section "[13] Gradle (~/.gradle/gradle.properties)"
if target_enabled "gradle"; then
  if command -v gradle &>/dev/null; then
    PROXY_HOST=$(echo "$HTTP_PROXY"  | sed -E 's|https?://||;s|:.*||')
    PROXY_PORT=$(echo "$HTTP_PROXY"  | sed -E 's|.*:([0-9]+).*|\1|')
    SPROXY_HOST=$(echo "$HTTPS_PROXY" | sed -E 's|https?://||;s|:.*||')
    SPROXY_PORT=$(echo "$HTTPS_PROXY" | sed -E 's|.*:([0-9]+).*|\1|')
    NO_PROXY_GRADLE=$(echo "$NO_PROXY" | tr ',' '|')

    write_user_block "$REAL_HOME/.gradle/gradle.properties" \
"systemProp.http.proxyHost=$PROXY_HOST
systemProp.http.proxyPort=$PROXY_PORT
systemProp.http.nonProxyHosts=$NO_PROXY_GRADLE
systemProp.https.proxyHost=$SPROXY_HOST
systemProp.https.proxyPort=$SPROXY_PORT
systemProp.https.nonProxyHosts=$NO_PROXY_GRADLE"
    success "~/.gradle/gradle.properties 적용"
  else
    warn "Gradle 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "gradle"; fi

# ════════════════════════════════════════════════════════════
# [14] Cargo (Rust)
# ════════════════════════════════════════════════════════════
section "[14] Cargo (~/.cargo/config.toml)"
if target_enabled "cargo"; then
  if command -v cargo &>/dev/null; then
    write_user_block "$REAL_HOME/.cargo/config.toml" \
"[http]
proxy = \"$HTTP_PROXY\"

[https]
proxy = \"$HTTPS_PROXY\""
    success "~/.cargo/config.toml 적용"
  else
    warn "Cargo 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "cargo"; fi

# ════════════════════════════════════════════════════════════
# [15] Go
# ════════════════════════════════════════════════════════════
section "[15] Go (go env -w)"
if target_enabled "go"; then
  if command -v go &>/dev/null; then
    sudo -u "$REAL_USER" HOME="$REAL_HOME" \
      go env -w GOPROXY="direct" \
               GONOSUMDB="*" \
               GOPRIVATE="" \
               HTTP_PROXY="$HTTP_PROXY" \
               HTTPS_PROXY="$HTTPS_PROXY" \
               NO_PROXY="$NO_PROXY" \
      && success "go env 적용" || warn "go env 실패"
  else
    warn "Go 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "go"; fi

# ════════════════════════════════════════════════════════════
# [16] Poetry
# ════════════════════════════════════════════════════════════
section "[16] Poetry"
if target_enabled "poetry"; then
  if command -v poetry &>/dev/null; then
    sudo -u "$REAL_USER" HOME="$REAL_HOME" poetry config installer.no-binary :all: false 2>/dev/null || true
    # Poetry는 환경변수로 프록시를 따름 → /etc/environment 로 충분
    # 단 인증서가 있으면 추가 설정
    if [[ -n "$INSTALLED_CERT_PATH" ]]; then
      sudo -u "$REAL_USER" HOME="$REAL_HOME" \
        poetry config certificates.default.cert "$SYS_CERT_BUNDLE" 2>/dev/null \
        && success "poetry 인증서 설정 완료" || warn "poetry 인증서 설정 실패"
    fi
    success "Poetry: 환경변수(/etc/environment)로 프록시 적용"
  else
    warn "Poetry 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "poetry"; fi

# ════════════════════════════════════════════════════════════
# [17] yarn
# ════════════════════════════════════════════════════════════
section "[17] yarn"
if target_enabled "yarn"; then
  if command -v yarn &>/dev/null; then
    # Yarn Berry (v2+): .yarnrc.yml
    YARN_VER=$(sudo -u "$REAL_USER" HOME="$REAL_HOME" yarn --version 2>/dev/null || echo "0")
    YARN_MAJOR="${YARN_VER%%.*}"
    if [[ "$YARN_MAJOR" -ge 2 ]]; then
      CERT_LINE=""
      [[ -n "$INSTALLED_CERT_PATH" ]] && CERT_LINE="httpsCaFilePath: \"$SYS_CERT_BUNDLE\""
      write_user_block "$REAL_HOME/.yarnrc.yml" \
"httpProxy: \"$HTTP_PROXY\"
httpsProxy: \"$HTTPS_PROXY\"
noProxy: \"$NO_PROXY\"
${CERT_LINE}"
      success "~/.yarnrc.yml (Berry) 적용"
    else
      # Yarn Classic (v1): .yarnrc
      write_user_block "$REAL_HOME/.yarnrc" \
"proxy \"$HTTP_PROXY\"
https-proxy \"$HTTPS_PROXY\""
      success "~/.yarnrc (Classic) 적용"
    fi
  else
    warn "yarn 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "yarn"; fi

# ════════════════════════════════════════════════════════════
# [18] pnpm
# ════════════════════════════════════════════════════════════
section "[18] pnpm"
if target_enabled "pnpm"; then
  # pnpm 은 ~/.npmrc 를 npm 과 공유 → npm 섹션에서 이미 작성됨 (중복 작성 방지)
  info "  ~/.npmrc 는 [4] npm 섹션에서 작성됨 (pnpm 도 공유)"
  # pnpm CLI 가 있으면 자체 config 명령으로도 추가 설정
  if command -v pnpm &>/dev/null || sudo -u "$REAL_USER" bash -lc 'command -v pnpm' &>/dev/null; then
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -lc "pnpm config set proxy '$HTTP_PROXY'" 2>/dev/null || true
    sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -lc "pnpm config set https-proxy '$HTTPS_PROXY'" 2>/dev/null || true
    [[ -n "$INSTALLED_CERT_PATH" ]] && \
      sudo -u "$REAL_USER" HOME="$REAL_HOME" bash -lc "pnpm config set cafile '$SYS_CERT_BUNDLE'" 2>/dev/null || true
    success "pnpm config set 적용"
  else
    info "  pnpm CLI 미설치 — ~/.npmrc 만으로도 동작 (설치 후 즉시 적용)"
  fi
else skip "pnpm"; fi

# ════════════════════════════════════════════════════════════
# [19] podman
# ════════════════════════════════════════════════════════════
section "[19] podman"
if target_enabled "podman"; then
  if command -v podman &>/dev/null; then
    CONTAINERS_CONF="/etc/containers/containers.conf"
    mkdir -p /etc/containers
    [[ -f "$CONTAINERS_CONF" ]] || cat > "$CONTAINERS_CONF" << 'PODEOF'
[engine]
PODEOF
    # [engine] env 항목 패치
    python3 - "$CONTAINERS_CONF" "$HTTP_PROXY" "$HTTPS_PROXY" "$NO_PROXY" << 'PYEOF'
import sys, re
path, http, https, noproxy = sys.argv[1:]
with open(path) as f:
    content = f.read()

env_line = f'env = ["HTTP_PROXY={http}", "HTTPS_PROXY={https}", "NO_PROXY={noproxy}"]'

# [engine] 섹션에 env 추가/교체
if re.search(r'^\s*env\s*=', content, re.M):
    content = re.sub(r'^\s*env\s*=.*$', env_line, content, flags=re.M)
else:
    content = re.sub(r'(\[engine\])', r'\1\n' + env_line, content)

with open(path, 'w') as f:
    f.write(content)
PYEOF
    success "/etc/containers/containers.conf 적용"
  else
    warn "podman 없음 — 건너뜁니다"
  fi
else skip "podman"; fi

# ════════════════════════════════════════════════════════════
# [20] helm
# ════════════════════════════════════════════════════════════
section "[20] helm"
if target_enabled "helm"; then
  if command -v helm &>/dev/null; then
    # Helm은 환경변수(HTTP_PROXY, HTTPS_PROXY, NO_PROXY)를 직접 사용
    # /etc/environment 에 이미 설정됐으므로 추가로 helm env 파일에 명시
    HELM_ENV_DIR="/etc/systemd/system.conf.d"
    mkdir -p "$HELM_ENV_DIR"
    cat > "$HELM_ENV_DIR/99-helm-proxy.conf" << HELMEOF
[Manager]
DefaultEnvironment="HTTP_PROXY=$HTTP_PROXY" "HTTPS_PROXY=$HTTPS_PROXY" "NO_PROXY=$NO_PROXY"
HELMEOF
    # 사용자 레벨 env 파일
    HELM_DATA_HOME="${HELM_DATA_HOME:-$REAL_HOME/.local/share/helm}"
    sudo -u "$REAL_USER" mkdir -p "$HELM_DATA_HOME"
    systemctl daemon-reload 2>/dev/null || true
    success "helm proxy (/etc/environment + systemd DefaultEnvironment) 적용"
  else
    warn "helm 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "helm"; fi

# ════════════════════════════════════════════════════════════
# [21] kubectl
# ════════════════════════════════════════════════════════════
section "[21] kubectl"
if target_enabled "kubectl"; then
  if command -v kubectl &>/dev/null; then
    # kubectl은 환경변수(HTTPS_PROXY)를 따름 — /etc/environment 로 커버
    success "kubectl: 환경변수(/etc/environment)로 프록시 적용"
    info  "  💡 클러스터 API 서버 주소를 no_proxy 에 추가하는 것을 권장합니다"
  else
    warn "kubectl 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "kubectl"; fi

# ════════════════════════════════════════════════════════════
# [22] JVM (JAVA_TOOL_OPTIONS)
# ════════════════════════════════════════════════════════════
section "[22] JVM (JAVA_TOOL_OPTIONS)"
if target_enabled "jvm"; then
  if command -v java &>/dev/null; then
    PROXY_HOST=$(echo "$HTTP_PROXY"  | sed -E 's|https?://||;s|:.*||')
    PROXY_PORT=$(echo "$HTTP_PROXY"  | sed -E 's|.*:([0-9]+).*|\1|')
    SPROXY_HOST=$(echo "$HTTPS_PROXY" | sed -E 's|https?://||;s|:.*||')
    SPROXY_PORT=$(echo "$HTTPS_PROXY" | sed -E 's|.*:([0-9]+).*|\1|')
    # no_proxy → nonProxyHosts (| 구분자, * 와일드카드)
    NO_PROXY_JVM=$(echo "$NO_PROXY" | sed 's/,/|/g' | sed 's/\./\\./g')

    JVM_OPTS="-Dhttp.proxyHost=${PROXY_HOST} -Dhttp.proxyPort=${PROXY_PORT}"
    JVM_OPTS+=" -Dhttps.proxyHost=${SPROXY_HOST} -Dhttps.proxyPort=${SPROXY_PORT}"
    JVM_OPTS+=" -Dhttp.nonProxyHosts='${NO_PROXY_JVM}'"
    [[ -n "$INSTALLED_CERT_PATH" ]] && \
      JVM_OPTS+=" -Djavax.net.ssl.trustStore=$SYS_CERT_BUNDLE"

    # /etc/environment 에 추가
    write_root_block "/etc/environment" \
"JAVA_TOOL_OPTIONS=\"${JVM_OPTS}\"" "jvm"
    success "/etc/environment JAVA_TOOL_OPTIONS 적용"
  else
    warn "java 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "jvm"; fi

# ════════════════════════════════════════════════════════════
# [23] gem (Ruby)
# ════════════════════════════════════════════════════════════
section "[23] gem (Ruby)"
if target_enabled "gem"; then
  if command -v gem &>/dev/null; then
    write_user_block "$REAL_HOME/.gemrc" \
"http_proxy: $HTTP_PROXY
https_proxy: $HTTPS_PROXY"
    success "~/.gemrc 적용"
  else
    warn "gem 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "gem"; fi

# ════════════════════════════════════════════════════════════
# [24] bundler (Ruby)
# ════════════════════════════════════════════════════════════
section "[24] bundler (Ruby)"
if target_enabled "bundler"; then
  if command -v bundle &>/dev/null; then
    sudo -u "$REAL_USER" HOME="$REAL_HOME" \
      bundle config set --global proxy "$HTTP_PROXY" 2>/dev/null \
      && success "bundler config proxy 적용" || warn "bundler 설정 실패"
  else
    warn "bundler 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "bundler"; fi

# ════════════════════════════════════════════════════════════
# [25] terraform
# ════════════════════════════════════════════════════════════
section "[25] terraform"
if target_enabled "terraform"; then
  if command -v terraform &>/dev/null; then
    # Terraform은 환경변수(HTTP_PROXY, HTTPS_PROXY)를 그대로 사용
    # 인증서가 있으면 SSL_CERT_FILE 로 지정
    CERT_LINE=""
    [[ -n "$INSTALLED_CERT_PATH" ]] && \
      CERT_LINE="SSL_CERT_FILE=\"$SYS_CERT_BUNDLE\""
    write_root_block "/etc/environment" \
"# Terraform (환경변수 상속 + 인증서)
${CERT_LINE}" "terraform"
    # provider_installation 캐시 설정
    write_user_block "$REAL_HOME/.terraformrc" \
"# Terraform proxy (환경변수로 적용)
# http_proxy / https_proxy 는 /etc/environment 에서 상속됩니다"
    success "~/.terraformrc + /etc/environment 적용"
  else
    warn "terraform 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "terraform"; fi

# ════════════════════════════════════════════════════════════
# [26] ansible
# ════════════════════════════════════════════════════════════
section "[26] ansible"
if target_enabled "ansible"; then
  if command -v ansible &>/dev/null; then
    ANSIBLE_CFG="$REAL_HOME/.ansible.cfg"
    write_user_block "$ANSIBLE_CFG" \
"[galaxy]
server_timeout = 60

[ssh_connection]
# Ansible은 환경변수(http_proxy)를 사용합니다

[defaults]
# 인증서 경로 (custom CA 가 있을 때)
$([ -n "$INSTALLED_CERT_PATH" ] && echo "ca_path = $SYS_CERT_BUNDLE" || echo "# ca_path =")"
    success "~/.ansible.cfg 적용"
  else
    warn "ansible 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "ansible"; fi

# ════════════════════════════════════════════════════════════
# [27] flatpak
# ════════════════════════════════════════════════════════════
section "[27] flatpak"
if target_enabled "flatpak"; then
  if command -v flatpak &>/dev/null; then
    # Flatpak 1.15.0+ 은 프록시 설정 API 제공
    # 이전 버전은 환경변수 경유
    if flatpak --system config --list &>/dev/null 2>&1; then
      flatpak --system config --set http-proxy "$HTTP_PROXY" 2>/dev/null \
        && success "flatpak --system config http-proxy 적용" \
        || warn "flatpak config 실패 (버전 확인 필요)"
    else
      warn "flatpak config API 미지원 버전 — /etc/environment 로 적용됩니다"
    fi
    if [[ -n "$INSTALLED_CERT_PATH" ]]; then
      cp "$INSTALLED_CERT_PATH" /usr/share/ca-certificates/ 2>/dev/null || true
    fi
  else
    warn "flatpak 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "flatpak"; fi

# ════════════════════════════════════════════════════════════
# [28] pipx
# ════════════════════════════════════════════════════════════
section "[28] pipx"
if target_enabled "pipx"; then
  if command -v pipx &>/dev/null; then
    # pipx 는 pip 설정과 환경변수를 상속하므로 별도 설정 불필요
    # pip.conf + /etc/environment 로 자동 적용됨
    success "pipx: pip.conf + /etc/environment 상속으로 프록시 적용"
  else
    warn "pipx 없음 — 건너뜁니다 (설치 후 재실행하면 적용됩니다)"
  fi
else skip "pipx"; fi

# ════════════════════════════════════════════════════════════
#  완료
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅  프록시 설정 자동화 완료!                     ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "재적용(설정 변경 후):"
echo "  sudo bash $0 $CONFIG_FILE"
echo ""
echo "설정 확인:"
echo "  env | grep -i proxy"
echo "  cat /etc/apt/apt.conf.d/99-proxy"
echo "  git config --global --list | grep proxy"
echo ""
warn "shell 환경변수(/etc/environment)는 재로그인 후 반영됩니다."
echo ""
