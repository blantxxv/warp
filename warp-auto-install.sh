#!/usr/bin/env bash
set -Eeuo pipefail

# Eclipse WARP Manager
# Safe Cloudflare WARP WireGuard installer for Remnawave/Xray nodes.
#
# Design goals:
#   - pretty interactive menu with progress bar
#   - safe wgcf + wg-quick installation
#   - no default-route hijack: Table=off
#   - no system DNS rewrite: DNS line removed
#   - reliable, shuffled, retrying endpoint scan until WARP loc is acceptable
#   - watchdog timer to re-scan if WARP becomes denied-loc or goes offline
#
# Quick usage:
#   bash warp-auto-install.sh
#   bash warp-auto-install.sh --auto
#   bash warp-auto-install.sh --rescan-only
#   bash warp-auto-install.sh --status
#
# Options:
#   --deny=RU,BY,KZ        Denied WARP loc values. Default: RU,BY,KZ,AM,AZ,KG,TJ,TM,UZ,MD
#   --accept=DE,PL,BR      Optional allowed WARP loc values. Empty = accept any not denied
#   --no-timer              Do not install periodic recheck timer
#   --debug                 Verbose shell trace

SCRIPT_NAME="Eclipse WARP Manager"
SCRIPT_VERSION="2.0.0"
PROJECT_CHANNEL="t.me/light_eclipse"

IFACE="warp"
WG_DIR="/etc/wireguard"
WGCF_BIN="/usr/local/bin/wgcf"
CONF="${WG_DIR}/${IFACE}.conf"
ACCOUNT="${WG_DIR}/wgcf-account.toml"
PROFILE="${WG_DIR}/wgcf-profile.conf"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
LOG_FILE="/var/log/warp-auto-install.log"
SCAN_LOG_FILE="/var/log/warp-scan.log"
SELF_PATH_INSTALLED="/root/warp-auto-install.sh"

# CIS / "near abroad" countries are denied by default alongside RU, since WARP
# frequently routes them onto the same flagged egress pool as RU.
DENY_LOCS="${WARP_DENY_LOCS:-RU,BY,KZ,AM,AZ,KG,TJ,TM,UZ,MD}"
ACCEPT_LOCS="${WARP_ACCEPT_LOCS:-}"
INSTALL_TIMER=1
RESCAN_ONLY=0
MODE="menu"

PORTS="${WARP_PORTS:-2408 500 1701 4500}"
ENDPOINT_IPS="${WARP_ENDPOINT_IPS:-}"

# How many endpoints to actually probe in one scan pass before giving up.
# Probing is randomized + capped so one scan finishes in a bounded time
# instead of crawling through hundreds of dead combinations.
MAX_PROBES="${WARP_MAX_PROBES:-60}"
HANDSHAKE_WAIT="${WARP_HANDSHAKE_WAIT:-5}"
HANDSHAKE_RETRIES="${WARP_HANDSHAKE_RETRIES:-2}"

# ----------------------------------------------------------------------------
# Terminal capability detection & colors
# ----------------------------------------------------------------------------
IS_TTY=0
if [[ -t 1 ]]; then
  IS_TTY=1
fi

# Respect NO_COLOR convention and dumb terminals too, not just non-tty output.
if [[ "$IS_TTY" -eq 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  WHITE=$'\033[1;37m'
  GRAY=$'\033[0;90m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
  C_OK="$GREEN"
  C_BAD="$RED"
  C_WARN="$YELLOW"
  C_ACCENT="$CYAN"
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' GRAY='' BOLD='' DIM='' RESET=''
  C_OK='' C_BAD='' C_WARN='' C_ACCENT=''
fi

# Box-drawing glyphs (ASCII fallback if locale isn't UTF-8, so it never
# renders as garbage mojibake on a minimal/serial console).
# Locale strings vary in casing/format (UTF-8, utf8, UTF8), so normalize
# before matching instead of relying on one exact pattern.
_locale_check="${LC_ALL:-}${LC_CTYPE:-}${LANG:-}"
_locale_check="$(echo "$_locale_check" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
if [[ "$_locale_check" == *utf8* ]]; then
  BOX_TL="╭"; BOX_TR="╮"; BOX_BL="╰"; BOX_BR="╯"; BOX_H="─"; BOX_V="│"
  ICON_OK="✔"; ICON_BAD="✘"; ICON_WARN="⚠"; ICON_INFO="ℹ"; ICON_ARROW="➜"
else
  BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"
  ICON_OK="OK"; ICON_BAD="X"; ICON_WARN="!"; ICON_INFO="i"; ICON_ARROW="->"
fi

TERM_WIDTH=$(tput cols 2>/dev/null || echo 78)
[[ "$TERM_WIDTH" -lt 60 ]] && TERM_WIDTH=78
BOX_WIDTH=$(( TERM_WIDTH > 78 ? 78 : TERM_WIDTH ))

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" "$SCAN_LOG_FILE" 2>/dev/null || true

log_file() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

repeat_char() {
  local char="$1" count="$2"
  printf '%*s' "$count" '' | tr ' ' "$char"
}

box_top() {
  printf "${GRAY}%s%s%s${RESET}\n" "$BOX_TL" "$(repeat_char "$BOX_H" $((BOX_WIDTH - 2)))" "$BOX_TR"
}

box_bottom() {
  printf "${GRAY}%s%s%s${RESET}\n" "$BOX_BL" "$(repeat_char "$BOX_H" $((BOX_WIDTH - 2)))" "$BOX_BR"
}

box_line() {
  local text="$1"
  local plain_len
  plain_len="$(printf '%s' "$text" | sed -E 's/\x1b\[[0-9;]*m//g' | wc -m)"
  local pad=$(( BOX_WIDTH - 4 - plain_len ))
  [[ "$pad" -lt 0 ]] && pad=0
  printf "${GRAY}%s${RESET} %s%*s ${GRAY}%s${RESET}\n" "$BOX_V" "$text" "$pad" "" "$BOX_V"
}

say() {
  printf "  ${C_OK}%s${RESET} %s\n" "$ICON_OK" "$*"
  log_file "OK: $*"
}

info() {
  printf "  ${C_ACCENT}%s${RESET} %s\n" "$ICON_INFO" "$*"
  log_file "INFO: $*"
}

warn() {
  printf "  ${C_WARN}%s${RESET} %s\n" "$ICON_WARN" "$*" >&2
  log_file "WARN: $*"
}

fail() {
  printf "  ${C_BAD}%s${RESET} %s\n" "$ICON_BAD" "$*" >&2
  log_file "ERROR: $*"
}

step() {
  printf "\n${BOLD}${MAGENTA}%s %s${RESET}\n" "$ICON_ARROW" "$*"
  log_file "STEP: $*"
}

line() {
  printf "${GRAY}%s${RESET}\n" "$(repeat_char "$BOX_H" "$BOX_WIDTH")"
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
  printf "          ${WHITE}${BOLD}WARP Manager для Remnawave Node${RESET}\n"
  printf "          ${GRAY}%s ${DIM}•${RESET}${GRAY} version %s${RESET}\n" "$PROJECT_CHANNEL" "$SCRIPT_VERSION"
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
  --deny=RU,BY,KZ      Denied WARP loc values. Default: RU,BY,KZ,AM,AZ,KG,TJ,TM,UZ,MD
  --accept=DE,PL,BR    Optional allowed WARP loc values. Empty = accept any not denied
  --no-timer           Do not install watchdog timer
  --debug              Show executed shell commands
  -h, --help           Show help

Environment:
  WARP_DENY_LOCS       Same as --deny
  WARP_ACCEPT_LOCS     Same as --accept
  WARP_PORTS           Ports to scan. Default: 2408 500 1701 4500
  WARP_ENDPOINT_IPS    Space-separated endpoint IPs to scan
  WARP_MAX_PROBES      Max endpoints probed per scan pass. Default: 60
  WARP_HANDSHAKE_WAIT  Seconds to wait for handshake per attempt. Default: 5
  WARP_HANDSHAKE_RETRIES  Retry attempts per endpoint before moving on. Default: 2
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
  "$@" >>"$LOG_FILE" 2>&1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Запусти от root: sudo -i"
    exit 1
  fi
}

require_bin() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1
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
  for bin in wg wg-quick curl jq ip; do
    if ! require_bin "$bin"; then
      fail "Команда '$bin' не найдена после установки пакетов."
      exit 1
    fi
  done
  say "Зависимости на месте"
}

download_wgcf() {
  step "Установка wgcf"

  if require_bin wgcf && [[ -x "$WGCF_BIN" ]]; then
    info "wgcf уже установлен: $($WGCF_BIN --version 2>/dev/null || echo 'версия неизвестна')"
  fi

  local url
  url="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
    | jq -r '.assets[] | select(.name | test("linux_amd64$")) | .browser_download_url' \
    | head -n1)"

  if [[ -z "$url" || "$url" == "null" ]]; then
    fail "Не удалось получить URL wgcf linux_amd64 (GitHub API недоступен или rate-limit)."
    exit 1
  fi

  info "wgcf URL: $url"
  if ! curl -fL "$url" -o "$WGCF_BIN" >>"$LOG_FILE" 2>&1; then
    fail "Не удалось скачать wgcf."
    exit 1
  fi
  chmod +x "$WGCF_BIN"

  if ! "$WGCF_BIN" --help >/dev/null 2>&1; then
    fail "wgcf скачан, но не запускается. Проверь архитектуру (нужен amd64)."
    exit 1
  fi
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
    BY|KZ|AM|AZ|KG|TJ|TM|UZ|MD|UA) echo "СНГ / соседние" ;;
    AL|AD|AT|BE|BA|BG|HR|CY|CZ|DK|EE|FI|FR|DE|GR|HU|IS|IE|IT|XK|LV|LI|LT|LU|MT|MC|ME|NL|MK|NO|PL|PT|RO|SM|RS|SK|SI|ES|SE|CH|GB|VA) echo "Европа" ;;
    US|CA|MX|GT|BZ|SV|HN|NI|CR|PA|CU|DO|HT|JM|BS|BB|TT|AG|DM|GD|KN|LC|VC) echo "Северная Америка" ;;
    AR|BO|BR|CL|CO|EC|GY|PY|PE|SR|UY|VE) echo "Южная Америка" ;;
    CN|HK|MO|TW|JP|KR|KP|MN|SG|MY|TH|VN|ID|PH|IN|PK|BD|LK|NP|AE|SA|QA|KW|BH|OM|TR|IL|GE) echo "Азия" ;;
    AU|NZ|FJ|PG) echo "Океания" ;;
    *) echo "Unknown" ;;
  esac
}

# Builds the endpoint candidate pool, then shuffles it so every scan pass
# (manual rescan, watchdog rescan, fresh install) explores a different order
# instead of always retrying the same dead-on-arrival prefixes first.
generate_endpoints() {
  local pool=()

  if [[ -n "$ENDPOINT_IPS" ]]; then
    for ip in $ENDPOINT_IPS; do
      pool+=("$ip")
    done
  else
    local net
    for net in 162.159.192 162.159.193 162.159.195 188.114.96 188.114.97; do
      local i
      for i in $(seq 0 254); do
        pool+=("${net}.${i}")
      done
    done
  fi

  # Shuffle (Fisher-Yates) so repeated scans don't hammer the same prefix.
  local n="${#pool[@]}"
  local i j tmp
  for ((i = n - 1; i > 0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp="${pool[i]}"
    pool[i]="${pool[j]}"
    pool[j]="$tmp"
  done

  printf '%s\n' "${pool[@]}"
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
  if "$WGCF_BIN" register --accept-tos >>"$LOG_FILE" 2>&1; then
    :
  elif yes | "$WGCF_BIN" register >>"$LOG_FILE" 2>&1; then
    :
  else
    fail "Не удалось зарегистрировать WARP аккаунт (wgcf register). Проверь $LOG_FILE."
    exit 1
  fi

  if ! "$WGCF_BIN" generate >>"$LOG_FILE" 2>&1; then
    fail "wgcf generate завершился с ошибкой."
    exit 1
  fi

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
  if ! systemctl enable --now "wg-quick@${IFACE}" >>"$LOG_FILE" 2>&1; then
    fail "Не удалось поднять интерфейс ${IFACE}. Смотри $LOG_FILE."
    exit 1
  fi
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

# Waits up to HANDSHAKE_WAIT seconds (polling every second) for a live
# WireGuard handshake on $IFACE, instead of a single blind `sleep 3`.
# This is the fix for endpoints that are reachable but just slow to
# complete the handshake — previously they were marked dead too early.
wait_for_handshake() {
  local waited=0
  while (( waited < HANDSHAKE_WAIT )); do
    local hs
    hs="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')"
    if [[ -n "$hs" && "$hs" != "0" ]]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Renders a single-line, self-overwriting progress bar so a scan of dozens
# of endpoints doesn't dump hundreds of lines to the terminal.
render_progress() {
  local current="$1" total="$2" label="$3"
  local width=30
  local filled=$(( current * width / (total > 0 ? total : 1) ))
  [[ "$filled" -gt "$width" ]] && filled="$width"
  local empty=$(( width - filled ))

  local bar
  bar="$(repeat_char '#' "$filled")$(repeat_char '.' "$empty")"

  if [[ "$IS_TTY" -eq 1 ]]; then
    printf "\r  ${CYAN}[%s]${RESET} %3d/%-3d %s" "$bar" "$current" "$total" "$label"
    printf "%-30s" " "
    printf "\r  ${CYAN}[%s]${RESET} %3d/%-3d %s" "$bar" "$current" "$total" "$label"
  else
    # Non-interactive output (logged to a file / panel): emit plain lines,
    # not raw carriage returns that would otherwise look broken.
    printf "  [%s] %d/%d %s\n" "$bar" "$current" "$total" "$label"
  fi
}

scan_endpoints() {
  step "Сканирование WARP endpoints"
  local backup="${CONF}.bak.$(date +%s)"
  cp "$CONF" "$backup"

  info "Запрещённые loc: ${DENY_LOCS:-нет}"
  info "Разрешённые loc: ${ACCEPT_LOCS:-любой, кроме запрещённых}"
  info "Порты: $PORTS"
  info "Максимум попыток за проход: $MAX_PROBES"
  : >"$SCAN_LOG_FILE"

  local endpoints=()
  while IFS= read -r ip; do
    endpoints+=("$ip")
  done < <(generate_endpoints)

  local total_combos=$(( ${#endpoints[@]} * $(echo "$PORTS" | wc -w) ))
  local probes_to_run="$MAX_PROBES"
  [[ "$probes_to_run" -gt "$total_combos" ]] && probes_to_run="$total_combos"

  local n=0
  local found=0
  local best_loc="" best_endpoint=""

  for ip in "${endpoints[@]}"; do
    for port in $PORTS; do
      [[ "$n" -ge "$probes_to_run" ]] && break 2
      n=$((n + 1))
      local endpoint="${ip}:${port}"

      render_progress "$n" "$probes_to_run" "$endpoint"

      endpoint_set "$endpoint"

      if ! systemctl restart "wg-quick@${IFACE}" >/dev/null 2>&1; then
        echo "endpoint=$endpoint restart=failed" >>"$SCAN_LOG_FILE"
        continue
      fi

      local attempt=0
      local warp="" loc="" colo="" outip="" tr=""
      while (( attempt <= HANDSHAKE_RETRIES )); do
        if wait_for_handshake; then
          tr="$(trace_warp)"
          warp="$(trace_field "$tr" "warp")"
          loc="$(trace_field "$tr" "loc")"
          colo="$(trace_field "$tr" "colo")"
          outip="$(trace_field "$tr" "ip")"
          [[ -n "$warp" ]] && break
        fi
        attempt=$((attempt + 1))
      done

      echo "endpoint=$endpoint warp=${warp:-none} loc=${loc:-none} colo=${colo:-none} ip=${outip:-none}" >>"$SCAN_LOG_FILE"

      if [[ "$warp" == "on" ]]; then
        if [[ -z "$best_endpoint" ]]; then
          best_endpoint="$endpoint"
          best_loc="$loc"
        fi
        if warp_acceptable "$loc"; then
          if [[ "$IS_TTY" -eq 1 ]]; then printf "\n"; fi
          say "Найден подходящий endpoint: $endpoint (loc=$loc, colo=$colo, ip=$outip)"
          systemctl enable "wg-quick@${IFACE}" >/dev/null 2>&1 || true
          found=1
          break 2
        fi
      fi
    done
  done

  if [[ "$IS_TTY" -eq 1 ]]; then printf "\n"; fi

  if [[ "$found" -eq 1 ]]; then
    return 0
  fi

  warn "Подходящий endpoint не найден за $n попыток (см. $SCAN_LOG_FILE)."
  if [[ -n "$best_endpoint" ]]; then
    warn "Лучший найденный вариант был loc=$best_loc на $best_endpoint, но это запрещённый/не разрешённый лок."
  else
    warn "Ни один endpoint не дал успешный handshake — возможно блокируется UDP исходящий трафик."
  fi
  info "Восстанавливаю предыдущий конфиг."
  cp "$backup" "$CONF"
  systemctl restart "wg-quick@${IFACE}" >/dev/null 2>&1 || true
  return 1
}

install_watchdog() {
  [[ "$INSTALL_TIMER" -eq 1 ]] || return 0

  step "Установка watchdog timer"

  cat >/usr/local/sbin/warp-auto-recheck.sh <<EOF_RECHECK
#!/usr/bin/env bash
set -Eeuo pipefail

CONF="${CONF}"
TRACE_URL="${TRACE_URL}"
DENY_LOCS_DEFAULT="${DENY_LOCS}"
ACCEPT_LOCS_DEFAULT="${ACCEPT_LOCS}"
DENY_LOCS="\${WARP_DENY_LOCS:-\${DENY_LOCS_DEFAULT}}"
ACCEPT_LOCS="\${WARP_ACCEPT_LOCS:-\${ACCEPT_LOCS_DEFAULT}}"
IFACE="${IFACE}"

trace_field() {
  local trace="\$1"
  local field="\$2"
  echo "\$trace" | awk -F= -v k="\$field" '\$1==k {print \$2; exit}'
}

csv_contains() {
  local csv="\$1"
  local needle="\$2"
  [[ -z "\$csv" || -z "\$needle" ]] && return 1
  IFS=',' read -ra arr <<< "\$csv"
  for item in "\${arr[@]}"; do
    item="\$(echo "\$item" | tr '[:lower:]' '[:upper:]' | xargs)"
    [[ "\$item" == "\$needle" ]] && return 0
  done
  return 1
}

acceptable() {
  local loc="\$1"
  [[ -z "\$loc" ]] && return 1
  loc="\$(echo "\$loc" | tr '[:lower:]' '[:upper:]')"

  if [[ -n "\$ACCEPT_LOCS" ]]; then
    csv_contains "\$ACCEPT_LOCS" "\$loc" || return 1
  fi

  if [[ -n "\$DENY_LOCS" ]]; then
    csv_contains "\$DENY_LOCS" "\$loc" && return 1
  fi

  return 0
}

tr="\$(curl -4 --interface "\$IFACE" --max-time 8 -s "\$TRACE_URL" || true)"
warp="\$(trace_field "\$tr" "warp")"
loc="\$(trace_field "\$tr" "loc")"

if [[ "\$warp" == "on" ]] && acceptable "\$loc"; then
  exit 0
fi

logger -t warp-auto "Bad WARP state: warp=\${warp:-empty} loc=\${loc:-empty}; rescanning endpoints"
"${SELF_PATH_INSTALLED}" --rescan-only --deny="\${DENY_LOCS}" \${ACCEPT_LOCS:+--accept="\${ACCEPT_LOCS}"} --no-timer
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
  if systemctl enable --now warp-auto-recheck.timer >>"$LOG_FILE" 2>&1; then
    say "Watchdog включён: warp-auto-recheck.timer (каждые 15 минут)"
  else
    warn "Не удалось включить watchdog timer. Смотри $LOG_FILE."
  fi

  # Keep a copy of this script where the watchdog/menu can call it back,
  # mirroring the old behaviour where uninstall removed /root/warp-auto-install.sh.
  if [[ "$0" != "$SELF_PATH_INSTALLED" ]]; then
    cp -f "$0" "$SELF_PATH_INSTALLED" 2>/dev/null && chmod +x "$SELF_PATH_INSTALLED" || true
  fi
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

  line
  printf "${WHITE}${BOLD}Remnawave/Xray outbound:${RESET}\n\n"
  cat <<'EOF'
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
EOF

  printf "\n${WHITE}${BOLD}Проверки:${RESET}\n"
  cat <<'EOF'
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
  systemctl disable --now "wg-quick@${IFACE}" >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/warp-auto-recheck.timer
  rm -f /etc/systemd/system/warp-auto-recheck.service
  rm -f /usr/local/sbin/warp-auto-recheck.sh
  rm -f "$SELF_PATH_INSTALLED"

  systemctl daemon-reload

  warn "Конфиги WireGuard не удалены автоматически: $WG_DIR"
  warn "Если надо удалить полностью: rm -f ${CONF} ${WG_DIR}/wgcf-*"
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
    printf "${WHITE}${BOLD}Выбери действие:${RESET}\n\n"
    printf "  ${GREEN}1)${RESET} Автоматическая установка WARP\n"
    printf "  ${GREEN}2)${RESET} Пересканировать WARP endpoints\n"
    printf "  ${GREEN}3)${RESET} Статус WARP\n"
    printf "  ${GREEN}4)${RESET} Ручная инструкция\n"
    printf "  ${GREEN}5)${RESET} Удалить/отключить WARP Manager\n"
    printf "  ${GREEN}0)${RESET} Выход\n"
    printf "\n${GRAY}Настройки сейчас: deny=%s, accept=%s, iface=%s${RESET}\n" \
      "${DENY_LOCS:-none}" "${ACCEPT_LOCS:-any}" "$IFACE"
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
