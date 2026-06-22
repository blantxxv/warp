#!/usr/bin/env bash
set -Eeuo pipefail

# Eclipse WARP Manager
# Safe Cloudflare WARP WireGuard installer for Remnawave/Xray nodes.
#
# Design goals:
#   - pretty interactive menu
#   - safe wgcf + wg-quick installation
#   - no default-route hijack: Table=off
#   - no system DNS rewrite: DNS line removed
#   - automatic endpoint scan until WARP loc is acceptable
#   - watchdog timer to re-scan if WARP becomes RU or goes offline
#
# Quick usage:
#   bash warp-auto-install.sh
#   bash warp-auto-install.sh --auto
#   bash warp-auto-install.sh --rescan-only
#   bash warp-auto-install.sh --status
#
# Options:
#   --deny=RU,CN          Denied WARP loc values. Default: RU
#   --accept=DE,PL,BR     Optional allowed WARP loc values. Empty = accept any not denied
#   --no-timer            Do not install periodic recheck timer
#   --debug               Verbose shell trace

SCRIPT_NAME="Eclipse WARP Manager"
SCRIPT_VERSION="1.1.0"
PROJECT_CHANNEL="t.me/light_eclipse"

IFACE="warp"
WG_DIR="/etc/wireguard"
WGCF_BIN="/usr/local/bin/wgcf"
CONF="${WG_DIR}/${IFACE}.conf"
ACCOUNT="${WG_DIR}/wgcf-account.toml"
PROFILE="${WG_DIR}/wgcf-profile.conf"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
LOG_FILE="/var/log/warp-auto-install.log"

DENY_LOCS="${WARP_DENY_LOCS:-RU}"
ACCEPT_LOCS="${WARP_ACCEPT_LOCS:-}"
INSTALL_TIMER=1
RESCAN_ONLY=0
MODE="menu"

PORTS="${WARP_PORTS:-2408 500 1701 4500}"
ENDPOINT_IPS="${WARP_ENDPOINT_IPS:-}"

# Colors
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  CYAN='\033[0;36m'
  WHITE='\033[1;37m'
  GRAY='\033[0;90m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' GRAY='' BOLD='' RESET=''
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" 2>/dev/null || true

log_file() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

say() {
  printf "${GREEN}[%s]${RESET} %s\n" "OK" "$*"
  log_file "OK: $*"
}

info() {
  printf "${CYAN}[%s]${RESET} %s\n" "INFO" "$*"
  log_file "INFO: $*"
}

warn() {
  printf "${YELLOW}[%s]${RESET} %s\n" "WARN" "$*" >&2
  log_file "WARN: $*"
}

fail() {
  printf "${RED}[%s]${RESET} %s\n" "ERROR" "$*" >&2
  log_file "ERROR: $*"
}

step() {
  printf "\n${MAGENTA}━━━ %s${RESET}\n" "$*"
  log_file "STEP: $*"
}

line() {
  printf "${GRAY}%s${RESET}\n" "────────────────────────────────────────────────────────────"
}

pause_enter() {
  [[ "$MODE" == "menu" ]] || return 0
  printf "\n${GRAY}Нажми Enter для продолжения...${RESET}"
  read -r _ || true
}

banner() {
  clear 2>/dev/null || true
  printf "${CYAN}"
  cat <<'EOF'
███████╗ ██████╗██╗     ██╗██████╗ ███████╗███████╗
██╔════╝██╔════╝██║     ██║██╔══██╗██╔════╝██╔════╝
█████╗  ██║     ██║     ██║██████╔╝███████╗█████╗
██╔══╝  ██║     ██║     ██║██╔═══╝ ╚════██║██╔══╝
███████╗╚██████╗███████╗██║██║     ███████║███████╗
╚══════╝ ╚═════╝╚══════╝╚═╝╚═╝     ╚══════╝╚══════╝
EOF
  printf "${RESET}"
  printf "${WHITE}             WARP Manager для Remnawave Node${RESET}\n"
  printf "${GRAY}             %s • version %s${RESET}\n" "$PROJECT_CHANNEL" "$SCRIPT_VERSION"
  line
}

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

Usage:
  $0
  $0 --auto
  $0 --status
  $0 --rescan-only
  $0 --uninstall

Options:
  --auto               Automatic install without interactive menu
  --manual             Show manual commands
  --status             Show current WARP status
  --rescan-only        Re-scan endpoints using existing warp.conf
  --uninstall          Remove WARP interface, timer and generated files
  --deny=RU,CN         Denied WARP loc values. Default: RU
  --accept=DE,PL,BR    Optional allowed WARP loc values. Empty = accept any not denied
  --no-timer           Do not install watchdog timer
  --debug              Show executed shell commands
  -h, --help           Show help

Environment:
  WARP_DENY_LOCS       Same as --deny
  WARP_ACCEPT_LOCS     Same as --accept
  WARP_PORTS           Ports to scan. Default: 2408 500 1701 4500
  WARP_ENDPOINT_IPS    Space-separated endpoint IPs to scan
EOF
}

for arg in "$@"; do
  case "$arg" in
    --auto) MODE="auto" ;;
    --manual) MODE="manual" ;;
    --status) MODE="status" ;;
    --uninstall) MODE="uninstall" ;;
    --rescan-only) MODE="rescan"; RESCAN_ONLY=1 ;;
    --deny=*) DENY_LOCS="${arg#*=}" ;;
    --accept=*) ACCEPT_LOCS="${arg#*=}" ;;
    --no-timer) INSTALL_TIMER=0 ;;
    --debug) set -x ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

run_cmd() {
  local desc="$1"
  shift
  info "$desc"
  log_file "CMD: $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Запусти от root: sudo -i"
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  else
    fail "Сейчас поддерживаются Debian/Ubuntu с apt-get."
    exit 1
  fi
}

install_deps() {
  step "Установка базовых пакетов"
  local pm
  pm="$(detect_pkg_manager)"
  if [[ "$pm" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    run_cmd "apt update" apt-get update
    run_cmd "Установка wireguard-tools curl jq" \
      apt-get install -y wireguard-tools curl jq ca-certificates iproute2
  fi
}

download_wgcf() {
  step "Установка wgcf"
  local url
  url="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
    | jq -r '.assets[] | select(.name | test("linux_amd64$")) | .browser_download_url' \
    | head -n1)"

  if [[ -z "$url" || "$url" == "null" ]]; then
    fail "Не удалось получить URL wgcf linux_amd64."
    exit 1
  fi

  info "wgcf URL: $url"
  curl -fL "$url" -o "$WGCF_BIN" 2>&1 | tee -a "$LOG_FILE"
  chmod +x "$WGCF_BIN"
  "$WGCF_BIN" --help >/dev/null
  say "wgcf установлен: $WGCF_BIN"
}

csv_contains() {
  local csv="$1"
  local needle="$2"
  [[ -z "$csv" || -z "$needle" ]] && return 1
  IFS=',' read -ra arr <<< "$csv"
  for item in "${arr[@]}"; do
    item="$(echo "$item" | tr '[:lower:]' '[:upper:]' | xargs)"
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

trace_field() {
  local trace="$1"
  local field="$2"
  echo "$trace" | awk -F= -v k="$field" '$1==k {print $2; exit}'
}

trace_direct() {
  curl -4 --max-time 8 -s "$TRACE_URL" || true
}

trace_warp() {
  curl -4 --interface "$IFACE" --max-time 8 -s "$TRACE_URL" || true
}

server_country() {
  local tr loc
  tr="$(trace_direct)"
  loc="$(trace_field "$tr" "loc")"
  echo "${loc:-UNKNOWN}"
}

server_region() {
  local c="$1"
  case "$c" in
    RU) echo "Россия" ;;
    AL|AD|AT|BY|BE|BA|BG|HR|CY|CZ|DK|EE|FI|FR|DE|GR|HU|IS|IE|IT|XK|LV|LI|LT|LU|MT|MD|MC|ME|NL|MK|NO|PL|PT|RO|SM|RS|SK|SI|ES|SE|CH|UA|GB|VA) echo "Европа" ;;
    US|CA|MX|GT|BZ|SV|HN|NI|CR|PA|CU|DO|HT|JM|BS|BB|TT|AG|DM|GD|KN|LC|VC) echo "Северная Америка" ;;
    AR|BO|BR|CL|CO|EC|GY|PY|PE|SR|UY|VE) echo "Южная Америка" ;;
    CN|HK|MO|TW|JP|KR|KP|MN|SG|MY|TH|VN|ID|PH|IN|PK|BD|LK|NP|KZ|UZ|KG|TJ|TM|AE|SA|QA|KW|BH|OM|TR|IL|GE|AM|AZ) echo "Азия" ;;
    AU|NZ|FJ|PG) echo "Океания" ;;
    *) echo "Unknown" ;;
  esac
}

generate_endpoints() {
  if [[ -n "$ENDPOINT_IPS" ]]; then
    echo "$ENDPOINT_IPS"
    return
  fi

  for net in 162.159.192 162.159.193 188.114.96 188.114.97; do
    for i in $(seq 1 20); do
      echo "${net}.${i}"
    done
  done
}

create_profile() {
  step "Создание WARP WireGuard профиля"
  mkdir -p "$WG_DIR"
  chmod 700 "$WG_DIR"
  cd "$WG_DIR"

  if [[ "$RESCAN_ONLY" -eq 1 ]]; then
    [[ -f "$CONF" ]] || { fail "$CONF не найден для --rescan-only"; exit 1; }
    return
  fi

  systemctl disable --now "wg-quick@${IFACE}" >/dev/null 2>&1 || true

  rm -f "$ACCOUNT" "$PROFILE" "$CONF"

  info "Регистрируем новый Cloudflare WARP аккаунт"
  if "$WGCF_BIN" register --accept-tos >/dev/null 2>&1; then
    :
  else
    yes | "$WGCF_BIN" register 2>&1 | tee -a "$LOG_FILE"
  fi

  "$WGCF_BIN" generate 2>&1 | tee -a "$LOG_FILE"

  if [[ ! -f "$PROFILE" ]]; then
    fail "wgcf-profile.conf не создан."
    exit 1
  fi

  cp "$PROFILE" "$CONF"
  chmod 600 "$CONF"

  grep -q '^Table = off' "$CONF" || sed -i '/^\[Interface\]/a Table = off' "$CONF"
  sed -i '/^DNS =/d' "$CONF"

  say "Создан безопасный конфиг: $CONF"
  info "Table=off включён, DNS строка удалена"
}

ensure_safe_conf() {
  [[ -f "$CONF" ]] || { fail "$CONF не найден."; exit 1; }
  grep -q '^Table = off' "$CONF" || sed -i '/^\[Interface\]/a Table = off' "$CONF"
  sed -i '/^DNS =/d' "$CONF"
  chmod 600 "$CONF"
}

start_warp() {
  step "Запуск интерфейса ${IFACE}"
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${IFACE}" 2>&1 | tee -a "$LOG_FILE"
  say "Интерфейс ${IFACE} запущен"
}

endpoint_set() {
  local endpoint="$1"
  sed -i "s#^Endpoint = .*#Endpoint = ${endpoint}#g" "$CONF"
}

warp_acceptable() {
  local loc="$1"
  [[ -z "$loc" ]] && return 1
  loc="$(echo "$loc" | tr '[:lower:]' '[:upper:]')"

  if [[ -n "$ACCEPT_LOCS" ]]; then
    csv_contains "$ACCEPT_LOCS" "$loc" || return 1
  fi

  if [[ -n "$DENY_LOCS" ]]; then
    csv_contains "$DENY_LOCS" "$loc" && return 1
  fi

  return 0
}

format_status_value() {
  local k="$1"
  local v="$2"
  printf "  ${WHITE}%-18s${RESET} %s\n" "$k:" "${v:-—}"
}

current_warp_status_line() {
  local tr warp loc colo ip
  tr="$(trace_warp)"
  warp="$(trace_field "$tr" "warp")"
  loc="$(trace_field "$tr" "loc")"
  colo="$(trace_field "$tr" "colo")"
  ip="$(trace_field "$tr" "ip")"
  echo "warp=${warp:-} loc=${loc:-} colo=${colo:-} ip=${ip:-}"
}

scan_endpoints() {
  step "Сканирование WARP endpoints"
  local backup="${CONF}.bak.$(date +%s)"
  cp "$CONF" "$backup"

  info "Запрещённые loc: ${DENY_LOCS:-нет}"
  info "Разрешённые loc: ${ACCEPT_LOCS:-любой, кроме запрещённых}"
  info "Порты: $PORTS"
  info "Default route перед сканом:"
  ip route | grep '^default' | tee -a "$LOG_FILE" || true

  local endpoint ip port tr warp loc colo outip n
  n=0
  for ip in $(generate_endpoints); do
    for port in $PORTS; do
      n=$((n + 1))
      endpoint="${ip}:${port}"

      printf "${GRAY}[%03d]${RESET} %-24s " "$n" "$endpoint"

      endpoint_set "$endpoint"

      if ! systemctl restart "wg-quick@${IFACE}" >/dev/null 2>&1; then
        printf "${RED}restart=failed${RESET}\n"
        log_file "endpoint=$endpoint restart=failed"
        continue
      fi

      sleep 3

      tr="$(trace_warp)"
      warp="$(trace_field "$tr" "warp")"
      loc="$(trace_field "$tr" "loc")"
      colo="$(trace_field "$tr" "colo")"
      outip="$(trace_field "$tr" "ip")"

      if [[ "$warp" == "on" ]] && warp_acceptable "$loc"; then
        printf "${GREEN}warp=%s loc=%s colo=%s ip=%s${RESET}\n" "${warp:-}" "${loc:-}" "${colo:-}" "${outip:-}"
        say "Выбран endpoint: $endpoint / loc=$loc / colo=$colo / ip=$outip"
        systemctl enable "wg-quick@${IFACE}" >/dev/null
        return 0
      fi

      printf "warp=%s loc=%s colo=%s ip=%s\n" "${warp:-}" "${loc:-}" "${colo:-}" "${outip:-}"
      log_file "endpoint=$endpoint warp=${warp:-} loc=${loc:-} colo=${colo:-} ip=${outip:-}"
    done
  done

  warn "Подходящий endpoint не найден. Восстанавливаю предыдущий конфиг."
  cp "$backup" "$CONF"
  systemctl restart "wg-quick@${IFACE}" || true
  return 1
}

install_watchdog() {
  [[ "$INSTALL_TIMER" -eq 1 ]] || return 0

  step "Установка watchdog timer"

  cat >/usr/local/sbin/warp-auto-recheck.sh <<'EOF_RECHECK'
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="/etc/wireguard/warp.conf"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
DENY_LOCS="${WARP_DENY_LOCS:-RU}"
ACCEPT_LOCS="${WARP_ACCEPT_LOCS:-}"

trace_field() {
  local trace="$1"
  local field="$2"
  echo "$trace" | awk -F= -v k="$field" '$1==k {print $2; exit}'
}

csv_contains() {
  local csv="$1"
  local needle="$2"
  [[ -z "$csv" || -z "$needle" ]] && return 1
  IFS=',' read -ra arr <<< "$csv"
  for item in "${arr[@]}"; do
    item="$(echo "$item" | tr '[:lower:]' '[:upper:]' | xargs)"
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

acceptable() {
  local loc="$1"
  [[ -z "$loc" ]] && return 1
  loc="$(echo "$loc" | tr '[:lower:]' '[:upper:]')"

  if [[ -n "$ACCEPT_LOCS" ]]; then
    csv_contains "$ACCEPT_LOCS" "$loc" || return 1
  fi

  if [[ -n "$DENY_LOCS" ]]; then
    csv_contains "$DENY_LOCS" "$loc" && return 1
  fi

  return 0
}

tr="$(curl -4 --interface warp --max-time 8 -s "$TRACE_URL" || true)"
warp="$(trace_field "$tr" "warp")"
loc="$(trace_field "$tr" "loc")"

if [[ "$warp" == "on" ]] && acceptable "$loc"; then
  exit 0
fi

logger -t warp-auto "Bad WARP state: warp=${warp:-empty} loc=${loc:-empty}; rescanning endpoints"
/root/warp-auto-install.sh --rescan-only --deny="${DENY_LOCS}" ${ACCEPT_LOCS:+--accept="${ACCEPT_LOCS}"} --no-timer
EOF_RECHECK

  chmod +x /usr/local/sbin/warp-auto-recheck.sh

  cat >/etc/systemd/system/warp-auto-recheck.service <<'EOF_SERVICE'
[Unit]
Description=Eclipse WARP egress location recheck

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warp-auto-recheck.sh
EOF_SERVICE

  cat >/etc/systemd/system/warp-auto-recheck.timer <<'EOF_TIMER'
[Unit]
Description=Periodic Eclipse WARP egress location recheck

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

  systemctl daemon-reload
  systemctl enable --now warp-auto-recheck.timer 2>&1 | tee -a "$LOG_FILE"
  say "Watchdog включён: warp-auto-recheck.timer"
}

show_status() {
  banner
  step "Статус WARP"

  local direct direct_ip direct_loc direct_colo direct_warp
  local wtrace wip wloc wcolo wwarp endpoint default_route timer region

  direct="$(trace_direct)"
  direct_ip="$(trace_field "$direct" "ip")"
  direct_loc="$(trace_field "$direct" "loc")"
  direct_colo="$(trace_field "$direct" "colo")"
  direct_warp="$(trace_field "$direct" "warp")"
  region="$(server_region "${direct_loc:-UNKNOWN}")"

  if ip link show "$IFACE" >/dev/null 2>&1; then
    wtrace="$(trace_warp)"
    wip="$(trace_field "$wtrace" "ip")"
    wloc="$(trace_field "$wtrace" "loc")"
    wcolo="$(trace_field "$wtrace" "colo")"
    wwarp="$(trace_field "$wtrace" "warp")"
  else
    wip=""
    wloc=""
    wcolo=""
    wwarp="interface-not-found"
  fi

  endpoint="$(grep '^Endpoint' "$CONF" 2>/dev/null | awk -F'= ' '{print $2}' || true)"
  default_route="$(ip route | awk '/^default/ {print; exit}')"
  timer="$(systemctl is-enabled warp-auto-recheck.timer 2>/dev/null || echo disabled)"

  format_status_value "Server loc" "${direct_loc:-UNKNOWN} / ${region}"
  format_status_value "Server IP" "$direct_ip"
  format_status_value "Server colo" "$direct_colo"
  format_status_value "Direct WARP" "$direct_warp"
  line
  format_status_value "Interface" "$IFACE"
  format_status_value "Endpoint" "$endpoint"
  format_status_value "WARP status" "$wwarp"
  format_status_value "WARP loc" "$wloc"
  format_status_value "WARP colo" "$wcolo"
  format_status_value "WARP IP" "$wip"
  format_status_value "Default route" "$default_route"
  format_status_value "Timer" "$timer"
  format_status_value "Log" "$LOG_FILE"
  line

  if [[ "$wwarp" == "on" ]] && warp_acceptable "$wloc"; then
    say "Состояние нормальное: WARP работает, loc допустимый."
  else
    warn "Состояние требует внимания: WARP выключен или loc недопустимый."
  fi
}

print_final_summary() {
  banner
  step "Итог установки"

  local direct_loc region warpstat endpoint default_route timer
  direct_loc="$(server_country)"
  region="$(server_region "${direct_loc:-UNKNOWN}")"
  warpstat="$(current_warp_status_line)"
  endpoint="$(grep '^Endpoint' "$CONF" 2>/dev/null | awk -F'= ' '{print $2}' || true)"
  default_route="$(ip route | awk '/^default/ {print; exit}')"
  timer="$(systemctl is-enabled warp-auto-recheck.timer 2>/dev/null || echo disabled)"

  format_status_value "Server loc" "${direct_loc:-UNKNOWN} / ${region}"
  format_status_value "WireGuard iface" "$IFACE"
  format_status_value "Endpoint" "$endpoint"
  format_status_value "Config" "$CONF"
  format_status_value "Default route" "$default_route"
  format_status_value "WARP trace" "$warpstat"
  format_status_value "Timer" "$timer"
  format_status_value "Log" "$LOG_FILE"

  cat <<'EOF'

Remnawave/Xray outbound:

{
  "tag": "warp-out",
  "protocol": "freedom",
  "settings": {
    "domainStrategy": "UseIPv4"
  },
  "streamSettings": {
    "sockopt": {
      "interface": "warp",
      "tcpFastOpen": true
    }
  }
}

Проверки:
  ip route
  wg show warp
  curl -4 --interface warp https://www.cloudflare.com/cdn-cgi/trace
  curl -4 https://www.cloudflare.com/cdn-cgi/trace
EOF
}

manual_page() {
  banner
  cat <<'EOF'
Ручная установка WARP через wgcf + wg-quick

1. Пакеты:
   apt update
   apt install -y wireguard-tools curl jq ca-certificates iproute2

2. Скачать wgcf:
   WGCF_URL="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r '.assets[] | select(.name | test("linux_amd64$")) | .browser_download_url' | head -n1)"
   curl -fL "$WGCF_URL" -o /usr/local/bin/wgcf
   chmod +x /usr/local/bin/wgcf

3. Создать WARP профиль:
   mkdir -p /etc/wireguard
   cd /etc/wireguard
   wgcf register
   wgcf generate
   cp wgcf-profile.conf warp.conf
   chmod 600 warp.conf

4. Безопасные правки:
   sed -i '/^\[Interface\]/a Table = off' /etc/wireguard/warp.conf
   sed -i '/^DNS =/d' /etc/wireguard/warp.conf

5. Поднять:
   systemctl enable --now wg-quick@warp

6. Проверить:
   ip route
   wg show warp
   curl -4 --interface warp https://www.cloudflare.com/cdn-cgi/trace
EOF
}

uninstall_warp() {
  banner
  step "Удаление WARP Manager"

  systemctl disable --now warp-auto-recheck.timer >/dev/null 2>&1 || true
  systemctl disable --now wg-quick@warp >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/warp-auto-recheck.timer
  rm -f /etc/systemd/system/warp-auto-recheck.service
  rm -f /usr/local/sbin/warp-auto-recheck.sh
  rm -f /root/warp-auto-install.sh

  systemctl daemon-reload

  warn "Конфиги WireGuard не удалены автоматически: $WG_DIR"
  warn "Если надо удалить полностью: rm -f /etc/wireguard/warp.conf /etc/wireguard/wgcf-*"
  say "Сервисы отключены."
}

auto_install() {
  banner

  local c region
  c="$(server_country)"
  region="$(server_region "$c")"

  step "Проверка сервера"
  format_status_value "Country" "$c"
  format_status_value "Region" "$region"
  format_status_value "Deny locs" "$DENY_LOCS"
  format_status_value "Accept locs" "${ACCEPT_LOCS:-any except denied}"
  format_status_value "Log" "$LOG_FILE"

  install_deps
  download_wgcf
  create_profile
  ensure_safe_conf
  start_warp

  if ! scan_endpoints; then
    fail "WARP установлен, но допустимый egress loc не найден."
    print_final_summary || true
    exit 2
  fi

  install_watchdog
  print_final_summary
}

menu() {
  while true; do
    banner
    cat <<EOF
${WHITE}Выбери действие:${RESET}

  ${GREEN}1)${RESET} Автоматическая установка WARP
  ${GREEN}2)${RESET} Пересканировать WARP endpoints
  ${GREEN}3)${RESET} Статус WARP
  ${GREEN}4)${RESET} Ручная инструкция
  ${GREEN}5)${RESET} Удалить/отключить WARP Manager
  ${GREEN}0)${RESET} Выход

${GRAY}Настройки сейчас: deny=${DENY_LOCS:-none}, accept=${ACCEPT_LOCS:-any}, iface=${IFACE}${RESET}
EOF
    printf "\nВведите номер: "
    read -r choice || true

    case "$choice" in
      1) MODE="auto"; auto_install; pause_enter ;;
      2) MODE="rescan"; RESCAN_ONLY=1; require_root; ensure_safe_conf; start_warp; scan_endpoints; print_final_summary; pause_enter ;;
      3) show_status; pause_enter ;;
      4) manual_page; pause_enter ;;
      5) uninstall_warp; pause_enter ;;
      0) exit 0 ;;
      *) warn "Неверный пункт меню"; sleep 1 ;;
    esac
  done
}

main() {
  require_root

  case "$MODE" in
    auto) auto_install ;;
    menu) menu ;;
    manual) manual_page ;;
    status) show_status ;;
    rescan)
      banner
      ensure_safe_conf
      start_warp
      scan_endpoints
      print_final_summary
      ;;
    uninstall) uninstall_warp ;;
    *) fail "Unknown mode: $MODE"; exit 1 ;;
  esac
}

main "$@"
