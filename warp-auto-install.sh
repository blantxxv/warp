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
HANDSHAKE_WAIT="${WARP_HANDSHAKE_WAIT:-3}"

# Optional pause between probes. Anti-torrent/DPI daemons that watch for
# P2P-style behaviour (many short-lived connections to many different IPs
# in a short window — exactly what a fast scan looks like) may flag/ban
# based on burst rate. A small inter-probe delay can dodge that heuristic
# without meaningfully slowing down a human-supervised scan. 0 = old
# behaviour (no delay).
PROBE_DELAY_MS="${WARP_PROBE_DELAY_MS:-0}"

# Preferred loc(s) for AI access (US gives the broadest, least-filtered
# access to ChatGPT/Claude/Gemini/etc). Scan phase 1 spends up to
# PREFERRED_BUDGET probes hunting ONLY for these locs; if that budget runs
# out without a hit, phase 2 falls back to the first endpoint that merely
# satisfies DENY_LOCS/ACCEPT_LOCS (old behaviour), so the node is never left
# without WARP just because US specifically wasn't reachable this pass.
PREFERRED_LOCS="${WARP_PREFERRED_LOCS:-US}"
PREFERRED_BUDGET="${WARP_PREFERRED_BUDGET:-40}"

# Domains actually checked end-to-end through the warp interface (not just
# cdn-cgi/trace) — Cloudflare's network-level "warp=on/loc=US" does not
# guarantee these specific providers aren't geo/IP-blocking that same WARP
# egress pool, so we probe them directly.
AI_CHECK_DOMAINS="${WARP_AI_CHECK_DOMAINS:-chatgpt.com claude.ai gemini.google.com api.openai.com anthropic.com}"
# Minimum fraction (in tenths, e.g. 6 = 60%) of AI_CHECK_DOMAINS that must
# respond for the current WARP egress to be considered "good enough" —
# below this the watchdog treats it the same as warp being fully down.
AI_CHECK_MIN_OK_TENTHS="${WARP_AI_CHECK_MIN_OK_TENTHS:-6}"

# How often the systemd timer rechecks WARP health (Cloudflare loc + real
# AI domain reachability) and triggers a rescan if it's gone bad.
WATCHDOG_INTERVAL_MIN="${WARP_WATCHDOG_INTERVAL_MIN:-5}"

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
  --prefer=US          Preferred loc(s), tried first. Default: US
  --watchdog-interval=5  Minutes between watchdog rechecks. Default: 5
  --slow-scan          Add ~800ms delay between probes (dodges anti-torrent/DPI burst detectors)
  --probe-delay=MS     Custom delay between probes in milliseconds. Default: 0
  --no-timer           Do not install watchdog timer
  --debug              Show executed shell commands
  -h, --help           Show help

Environment:
  WARP_DENY_LOCS           Same as --deny
  WARP_ACCEPT_LOCS         Same as --accept
  WARP_PREFERRED_LOCS      Same as --prefer. Default: US
  WARP_PREFERRED_BUDGET    Probes spent hunting preferred loc before fallback. Default: 40
  WARP_WATCHDOG_INTERVAL_MIN  Minutes between watchdog rechecks. Default: 5
  WARP_PROBE_DELAY_MS      Delay between scan probes in ms. Default: 0 (see --slow-scan)
  WARP_PORTS               Ports to scan. Default: 2408 500 1701 4500
  WARP_ENDPOINT_IPS        Space-separated endpoint IPs to scan
  WARP_MAX_PROBES          Max endpoints probed per scan pass. Default: 60
  WARP_HANDSHAKE_WAIT      Seconds to wait for handshake per attempt. Default: 3
  WARP_AI_CHECK_DOMAINS    Domains probed through warp to confirm AI access works
  WARP_AI_CHECK_MIN_OK_TENTHS  Min fraction (in tenths) of domains that must respond. Default: 6
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
    --prefer=*) PREFERRED_LOCS="${arg#*=}" ;;
    --watchdog-interval=*) WATCHDOG_INTERVAL_MIN="${arg#*=}" ;;
    --slow-scan) PROBE_DELAY_MS=800 ;;
    --probe-delay=*) PROBE_DELAY_MS="${arg#*=}" ;;
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
    BY|AM|AZ|KG|TJ|TM|UZ|MD|UA) echo "СНГ / соседние" ;;
    AL|AD|AT|BE|BA|BG|HR|CY|CZ|DK|EE|FI|FR|DE|GR|HU|IS|IE|IT|XK|LV|LI|LT|LU|MT|MC|ME|NL|MK|NO|PL|PT|RO|SM|RS|SK|SI|ES|SE|CH|GB|VA) echo "Европа" ;;
    US|CA|MX|GT|BZ|SV|HN|NI|CR|PA|CU|DO|HT|JM|BS|BB|TT|AG|DM|GD|KN|LC|VC) echo "Северная Америка" ;;
    AR|BO|BR|CL|CO|EC|GY|PY|PE|SR|UY|VE) echo "Южная Америка" ;;
    CN|HK|MO|TW|JP|KZ|KR|KP|MN|SG|MY|TH|VN|ID|PH|IN|PK|BD|LK|NP|AE|SA|QA|KW|BH|OM|TR|IL|GE) echo "Азия" ;;
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

# Returns the peer public key from the WireGuard config, needed to push a
# live endpoint change via `wg set` without restarting the whole interface.
peer_pubkey() {
  awk -F' = ' '/^PublicKey/ {print $2; exit}' "$CONF"
}

# Switches the live peer endpoint via `wg set` instead of `systemctl restart`.
# A full service restart tears down and rebuilds the whole interface (routes,
# DNS resolution, systemd unit bookkeeping) which costs the better part of a
# second every time — across 60 probes that adds up to real, noticeable
# delay. `wg set` just repoints the existing tunnel, taking milliseconds.
endpoint_set_live() {
  local endpoint="$1"
  local pubkey="$2"
  wg set "$IFACE" peer "$pubkey" endpoint "$endpoint" 2>/dev/null
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

# True only if loc is in the preferred list (e.g. US) AND still passes the
# normal accept/deny filters. Used to drive scan phase 1 (US-first hunt).
warp_preferred() {
  local loc="$1"
  [[ -z "$PREFERRED_LOCS" ]] && return 1
  loc="$(echo "$loc" | tr '[:lower:]' '[:upper:]')"
  csv_contains "$PREFERRED_LOCS" "$loc" || return 1
  warp_acceptable "$loc"
}

# Probes real AI provider domains through the warp interface specifically.
# Cloudflare's own cdn-cgi/trace reporting warp=on/loc=US does NOT guarantee
# OpenAI/Anthropic/Google aren't independently blocking that exact WARP
# egress pool (shared consumer WARP IPs get flagged/rate-limited by these
# providers fairly often). Returns "ok_count total domain1=code domain2=code...".
check_ai_domains_via_warp() {
  local ok=0
  local total=0
  local detail=""
  local domain code
  for domain in $AI_CHECK_DOMAINS; do
    total=$((total + 1))
    # curl with -w '%{http_code}' prints "000" itself on a connect-level
    # failure (timeout, refused, no route) AND still returns a non-zero
    # exit code — so a naive `|| echo "000"` fallback double-prints,
    # producing "000000". Just read curl's own %{http_code} output and
    # ignore curl's exit status; fall back to "000" only if curl produced
    # no output at all (e.g. it crashed before writing anything).
    code="$(curl -4 --interface "$IFACE" -o /dev/null -s -w '%{http_code}' \
      --max-time 6 --connect-timeout 5 "https://${domain}/" 2>/dev/null)"
    code="${code:-000}"
    # Defensive: if anything still produced a doubled/garbled value, keep
    # only the last 3 digits so downstream comparisons stay well-formed.
    [[ "$code" =~ ^[0-9]{4,}$ ]] && code="${code: -3}"
    # Anything that isn't a connection-level failure counts as "reachable":
    # AI sites legitimately answer with 200/301/302/403 (region/bot pages)
    # without that meaning the tunnel is broken — 000 means curl couldn't
    # even connect, which is the actual failure signal we care about.
    if [[ "$code" != "000" ]]; then
      ok=$((ok + 1))
    fi
    detail="${detail}${domain}=${code} "
  done
  echo "${ok} ${total} ${detail}"
}

# Convenience wrapper returning 0/1 against AI_CHECK_MIN_OK_TENTHS threshold.
ai_domains_acceptable() {
  local result ok total
  result="$(check_ai_domains_via_warp)"
  ok="$(echo "$result" | awk '{print $1}')"
  total="$(echo "$result" | awk '{print $2}')"
  [[ "$total" -eq 0 ]] && return 1
  # ok*10/total >= AI_CHECK_MIN_OK_TENTHS  <=>  ok*10 >= threshold*total
  (( ok * 10 >= AI_CHECK_MIN_OK_TENTHS * total ))
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

# Waits up to HANDSHAKE_WAIT seconds (polling frequently) for the WireGuard
# handshake timestamp to advance past $baseline_ts. Comparing against a
# baseline (not just "is it non-zero") matters because we now switch peer
# endpoints live with `wg set` rather than restarting the interface — the
# old endpoint's handshake timestamp is still sitting there and would
# otherwise look like a false-positive success for the new endpoint.
# Polling every 0.3s (not every 1s) means a fast handshake is caught
# almost immediately instead of wasting up to a full second per check.
wait_for_handshake() {
  local baseline_ts="$1"
  local waited_ms=0
  local wait_ms=$(( HANDSHAKE_WAIT * 1000 ))
  while (( waited_ms < wait_ms )); do
    local hs
    hs="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')"
    if [[ -n "$hs" && "$hs" != "0" && "$hs" != "$baseline_ts" ]]; then
      return 0
    fi
    sleep 0.3
    waited_ms=$((waited_ms + 300))
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

  info "Приоритетные loc (фаза 1): ${PREFERRED_LOCS:-нет} (бюджет: $PREFERRED_BUDGET попыток)"
  info "Запрещённые loc: ${DENY_LOCS:-нет}"
  info "Разрешённые loc: ${ACCEPT_LOCS:-любой, кроме запрещённых}"
  info "Порты: $PORTS"
  info "Максимум попыток за проход: $MAX_PROBES"
  : >"$SCAN_LOG_FILE"

  local pubkey
  pubkey="$(peer_pubkey)"
  if [[ -z "$pubkey" ]]; then
    fail "Не найден PublicKey в $CONF — нечего сканировать."
    return 1
  fi

  # Interface must already be up so `wg set` has a live peer to retarget;
  # we no longer restart the whole service per probe (see endpoint_set_live).
  if ! ip link show "$IFACE" >/dev/null 2>&1; then
    if ! systemctl restart "wg-quick@${IFACE}" >>"$LOG_FILE" 2>&1; then
      fail "Не удалось поднять интерфейс ${IFACE} для скана."
      return 1
    fi
  fi

  local endpoints=()
  while IFS= read -r ip; do
    endpoints+=("$ip")
  done < <(generate_endpoints)

  local total_combos=$(( ${#endpoints[@]} * $(echo "$PORTS" | wc -w) ))
  local probes_to_run="$MAX_PROBES"
  [[ "$probes_to_run" -gt "$total_combos" ]] && probes_to_run="$total_combos"

  local preferred_budget="$PREFERRED_BUDGET"
  [[ "$preferred_budget" -gt "$probes_to_run" ]] && preferred_budget="$probes_to_run"
  [[ -z "$PREFERRED_LOCS" ]] && preferred_budget=0

  local n=0
  local found=0
  local found_phase=""
  local found_endpoint="" found_loc="" found_colo="" found_ip=""
  local best_loc="" best_endpoint=""
  # First acceptable-but-not-preferred hit, kept as a fallback candidate in
  # case phase 1 (US-only) burns its whole budget without success — this
  # way we don't have to re-scan combinations already probed in phase 1.
  local fallback_endpoint="" fallback_loc="" fallback_colo="" fallback_ip=""
  local scan_started_at
  scan_started_at="$(date +%s)"

  for ip in "${endpoints[@]}"; do
    for port in $PORTS; do
      [[ "$n" -ge "$probes_to_run" ]] && break 2
      n=$((n + 1))
      local endpoint="${ip}:${port}"

      # Once we've exhausted the preferred-loc budget without a hit, and we
      # already have a fallback candidate in hand, there's no point burning
      # the rest of probes_to_run — stop and use the fallback immediately.
      if [[ -n "$PREFERRED_LOCS" && "$n" -gt "$preferred_budget" && -n "$fallback_endpoint" ]]; then
        break 2
      fi

      local label="$endpoint"
      [[ -n "$PREFERRED_LOCS" && "$n" -le "$preferred_budget" ]] && label="${endpoint} [US-поиск]"
      render_progress "$n" "$probes_to_run" "$label"

      if [[ "$PROBE_DELAY_MS" -gt 0 ]]; then
        sleep "$(awk -v ms="$PROBE_DELAY_MS" 'BEGIN{printf "%.3f", ms/1000}')"
      fi

      local baseline_ts
      baseline_ts="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')"

      if ! endpoint_set_live "$endpoint" "$pubkey"; then
        echo "endpoint=$endpoint set=failed" >>"$SCAN_LOG_FILE"
        continue
      fi

      local warp="" loc="" colo="" outip="" tr=""
      if wait_for_handshake "${baseline_ts:-0}"; then
        tr="$(trace_warp)"
        warp="$(trace_field "$tr" "warp")"
        loc="$(trace_field "$tr" "loc")"
        colo="$(trace_field "$tr" "colo")"
        outip="$(trace_field "$tr" "ip")"
      fi

      echo "endpoint=$endpoint warp=${warp:-none} loc=${loc:-none} colo=${colo:-none} ip=${outip:-none}" >>"$SCAN_LOG_FILE"

      if [[ "$warp" == "on" ]]; then
        if [[ -z "$best_endpoint" ]]; then
          best_endpoint="$endpoint"
          best_loc="$loc"
        fi

        # Phase 1: still inside the preferred-loc budget — only a preferred
        # loc (e.g. US) ends the scan outright.
        if [[ -n "$PREFERRED_LOCS" && "$n" -le "$preferred_budget" ]]; then
          if warp_preferred "$loc"; then
            found_endpoint="$endpoint"; found_loc="$loc"; found_colo="$colo"; found_ip="$outip"
            found_phase="preferred"
            found=1
            break 2
          elif warp_acceptable "$loc" && [[ -z "$fallback_endpoint" ]]; then
            # Acceptable but not preferred — remember it for fallback, keep
            # looking for US within the remaining budget.
            fallback_endpoint="$endpoint"; fallback_loc="$loc"; fallback_colo="$colo"; fallback_ip="$outip"
          fi
        else
          # Phase 2 (preferred budget exhausted, or no preference set at
          # all): the old behaviour — first acceptable loc wins immediately.
          if warp_acceptable "$loc"; then
            found_endpoint="$endpoint"; found_loc="$loc"; found_colo="$colo"; found_ip="$outip"
            found_phase="fallback"
            found=1
            break 2
          fi
        fi
      fi
    done
  done

  # Preferred search ran out (budget or whole pool) without a direct hit,
  # but we stashed an acceptable non-preferred endpoint along the way.
  if [[ "$found" -ne 1 && -n "$fallback_endpoint" ]]; then
    found_endpoint="$fallback_endpoint"; found_loc="$fallback_loc"
    found_colo="$fallback_colo"; found_ip="$fallback_ip"
    found_phase="fallback"
    found=1
  fi

  if [[ "$IS_TTY" -eq 1 ]]; then printf "\n"; fi

  if [[ "$found" -eq 1 ]]; then
    # Re-point the live peer at the winner one more time — phase 1 may have
    # moved past it while still hunting for US, or it came from the stashed
    # fallback slot, so the interface might currently be pointed elsewhere.
    local baseline_ts2
    baseline_ts2="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')"
    endpoint_set_live "$found_endpoint" "$pubkey" || true
    wait_for_handshake "${baseline_ts2:-0}" || true

    endpoint_set "$found_endpoint"
    local elapsed=$(( $(date +%s) - scan_started_at ))
    if [[ "$found_phase" == "preferred" ]]; then
      say "Найден ПРИОРИТЕТНЫЙ endpoint: $found_endpoint (loc=$found_loc, colo=$found_colo, ip=$found_ip) за ${elapsed}с / $n попыток"
    else
      warn "Приоритетный loc (${PREFERRED_LOCS}) не найден за бюджет ${preferred_budget} попыток."
      say "Использую допустимый endpoint: $found_endpoint (loc=$found_loc, colo=$found_colo, ip=$found_ip) за ${elapsed}с / $n попыток"
    fi
    systemctl enable "wg-quick@${IFACE}" >/dev/null 2>&1 || true

    # Real-world check: confirm the AI providers themselves are reachable
    # through this exact egress, not just Cloudflare's own trace endpoint.
    info "Проверка доступности AI-сервисов через $IFACE..."
    local ai_result ai_ok ai_total ai_detail
    ai_result="$(check_ai_domains_via_warp)"
    ai_ok="$(echo "$ai_result" | awk '{print $1}')"
    ai_total="$(echo "$ai_result" | awk '{print $2}')"
    ai_detail="$(echo "$ai_result" | cut -d' ' -f3-)"
    echo "ai_check endpoint=$found_endpoint ok=${ai_ok}/${ai_total} ${ai_detail}" >>"$SCAN_LOG_FILE"

    if (( ai_ok * 10 >= AI_CHECK_MIN_OK_TENTHS * ai_total )); then
      say "AI-сервисы доступны: ${ai_ok}/${ai_total} (${ai_detail})"
    else
      warn "AI-сервисы плохо доступны через этот endpoint: ${ai_ok}/${ai_total} (${ai_detail})"
      warn "loc=${found_loc} формально допустим, но именно эта WARP-подсеть может быть зафлагована OpenAI/Google/Anthropic."
      info "Можно перезапустить скан (пункт 2 меню / --rescan-only), он попадёт на другой IP/ASN."
    fi

    return 0
  fi

  local elapsed=$(( $(date +%s) - scan_started_at ))
  warn "Подходящий endpoint не найден за $n попыток (${elapsed}с, см. $SCAN_LOG_FILE)."
  if [[ -n "$best_endpoint" ]]; then
    warn "Лучший найденный вариант был loc=$best_loc на $best_endpoint, но это запрещённый/не разрешённый лок."
  else
    warn "Ни один endpoint не дал успешный handshake (0 успехов из $n) — похоже на блокировку исходящего UDP."
    diagnose_udp_block
  fi
  info "Восстанавливаю предыдущий конфиг."
  cp "$backup" "$CONF"
  systemctl restart "wg-quick@${IFACE}" >/dev/null 2>&1 || true
  return 1
}

# Runs when NOT A SINGLE probed endpoint produced a handshake. Distinguishes
# "this whole server's outbound UDP is filtered" (hosting provider firewall,
# common on budget VPS) from "just these specific Cloudflare IPs are bad"
# so the user isn't left guessing why 60/60 probes failed identically.
diagnose_udp_block() {
  info "Диагностика исходящего UDP..."

  # 1) Can we even reach Cloudflare's anycast IP for the *trace* endpoint
  #    over plain TCP/443? If this also fails, it's likely outbound
  #    filtering in general, not something specific to UDP/WireGuard.
  if curl -4 --max-time 5 -s -o /dev/null "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null; then
    say "TCP/443 до Cloudflare (1.1.1.1) работает — блокировка не на TCP-уровне."
  else
    warn "Даже TCP/443 до Cloudflare (1.1.1.1) не проходит — проблема шире, не только WARP/UDP."
  fi

  # 2) Raw UDP send test against several WARP ports/IPs, bypassing
  #    WireGuard entirely. A successful local `nc` send only proves the
  #    packet left the box without an immediate ICMP-unreachable — it does
  #    NOT prove anything arrived, since UDP is connectionless. This is
  #    just a sanity check that nothing local refuses to even construct
  #    the socket (e.g. a raw-socket cap restriction in some containers).
  if command -v nc >/dev/null 2>&1; then
    local probe_failed=0
    local probe
    for probe in "162.159.192.1:2408" "188.114.96.1:500" "162.159.193.10:4500"; do
      local pip="${probe%:*}" pport="${probe#*:}"
      if ! timeout 4 bash -c "echo -n '' | nc -4u -w2 '$pip' '$pport'" 2>/dev/null; then
        probe_failed=$((probe_failed + 1))
      fi
    done
    if [[ "$probe_failed" -eq 0 ]]; then
      info "Локальная отправка UDP-пакетов на тестовые WARP IP/порты не встретила немедленных ошибок."
    else
      warn "$probe_failed из 3 локальных UDP-отправок завершились с ошибкой — возможна блокировка на уровне ОС/контейнера."
    fi
  fi

  # 3) iptables/nftables: check the chains that actually decide the fate
  #    of OUR traffic specifically, not just grep for any DROP line — the
  #    earlier version flagged P2P/torrent block rules (BitTorrent, eMule,
  #    DC++ ports) that have nothing to do with WARP and just caused
  #    confusion. What actually matters: (a) the OUTPUT chain's default
  #    policy, and (b) whether there's an explicit ACCEPT for the WARP
  #    ports at all — under a default-DROP policy, *absence* of an ACCEPT
  #    rule is the real blocker, not presence of unrelated DROP rules.
  if command -v iptables >/dev/null 2>&1; then
    local output_policy
    output_policy="$(iptables -L OUTPUT -n 2>/dev/null | head -1 | grep -oP '(?<=policy )\w+' || echo "UNKNOWN")"
    info "OUTPUT chain default policy: ${output_policy}"

    if [[ "$output_policy" == "DROP" || "$output_policy" == "REJECT" ]]; then
      local has_warp_accept
      has_warp_accept="$(iptables -L OUTPUT -n 2>/dev/null | grep -E 'ACCEPT.*udp.*(2408|dpt:500|1701|4500)' || true)"
      if [[ -z "$has_warp_accept" ]]; then
        warn "OUTPUT policy=${output_policy} и НЕТ явного ACCEPT для портов WARP (2408/500/1701/4500)."
        warn "Это сильный кандидат на причину: добавь правило вручную, например:"
        warn "  iptables -I OUTPUT -p udp --dport 2408 -j ACCEPT"
      else
        info "Явный ACCEPT для портов WARP найден в OUTPUT — на уровне iptables разрешено."
      fi
    else
      info "OUTPUT policy=${output_policy} (не блокирующая по умолчанию) — iptables, скорее всего, не причина."
    fi

    # Surface any DROP rule that specifically targets a WARP port (rare,
    # but possible) — unrelated P2P-port DROP rules are intentionally NOT
    # shown anymore since they only caused false alarms.
    local warp_drop
    warp_drop="$(iptables -L OUTPUT -n 2>/dev/null | grep -iE 'drop|reject' | grep -E '2408|1701|udp dpt:500($| )|4500' || true)"
    if [[ -n "$warp_drop" ]]; then
      warn "Найдено явное DROP/REJECT правило конкретно для порта WARP:"
      printf '%s\n' "$warp_drop" | while IFS= read -r l; do warn "  $l"; done
    fi
  fi

  # 4) Dynamic anti-torrent / DPI daemons (e.g. ipset+xt_string based
  #    blockers commonly run alongside Xray/Remnawave) ban IPs in real
  #    time based on traffic *behaviour*, not fixed ports — a static
  #    `iptables -L` snapshot can miss this entirely if rules live in an
  #    ipset set, or if the ban already expired by the time we look. A
  #    fast burst of 60 UDP probes to dozens of different Cloudflare IPs
  #    in under a minute (exactly what the scanner just did) looks a lot
  #    like P2P peer-swarming to a behavioural/FIN_WAIT heuristic.
  local found_blocker_svc=""
  local svc
  for svc in torrent-blocker xray-blocker dpi-blocker antitorrent torrentguard; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
      found_blocker_svc="$svc"
      break
    fi
  done

  if [[ -n "$found_blocker_svc" ]]; then
    warn "Обнаружен активный сервис '$found_blocker_svc' — анти-торрент демон с DPI/поведенческим анализом."
    warn "Такие демоны банят IP ДИНАМИЧЕСКИ (через ipset, не только iptables) на основе паттернов трафика,"
    warn "а не только по фиксированным портам — статичный 'iptables -L' выше мог этого не показать."
    warn "Быстрый скан (60 UDP-проб за минуту к разным Cloudflare IP) сам похож на P2P-поведение"
    warn "и может триггерить такой бан по ошибке (false positive)."
    if command -v ipset >/dev/null 2>&1; then
      local ipset_sets
      ipset_sets="$(ipset list -n 2>/dev/null || true)"
      if [[ -n "$ipset_sets" ]]; then
        info "Активные ipset-наборы (проверь, не там ли бан): $ipset_sets"
      fi
    fi
    info "Попробуй сначала просто замедлить скан (он сам похож на burst-паттерн):"
    info "  bash $0 --rescan-only --slow-scan"
    info "Если это не помогло — временно останови демон и повтори обычный скан: systemctl stop $found_blocker_svc"
    info "Если после остановки WARP подключается — это точно он, дальше добавь WARP IP (162.159.0.0/16,"
    info "188.114.0.0/16) или UDP-порт 2408 в исключения/bypass этого демона (флаг --bypass у torrent-blocker)."
  elif command -v ipset >/dev/null 2>&1 && [[ -n "$(ipset list -n 2>/dev/null)" ]]; then
    info "ipset активен (наборы: $(ipset list -n 2>/dev/null | tr '\n' ' ')), хотя известный сервис-блокер не найден."
    info "Если на сервере стоит свой анти-торрент/DPI скрипт — проверь его правила и логи отдельно."
  fi

  line
  info "ВАЖНО: многие хостеры (Hetzner, OVH, DigitalOcean, Vultr, AWS Security Groups и т.п.) держат отдельный"
  info "облачный firewall ВНЕ сервера (в панели управления) — он не виден ни в iptables, ни в nft, и режет"
  info "трафик ДО того, как пакет вообще доходит до ОС. Если правила выше выглядят нормально, в первую очередь"
  info "проверь именно панель хостера: должен быть разрешён исходящий UDP, особенно на порт 2408."
  info "Быстрый способ проверить версию 'не в iptables дело': временно 'iptables -P OUTPUT ACCEPT' и повторить скан."
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
PREFERRED_LOCS_DEFAULT="${PREFERRED_LOCS}"
AI_CHECK_DOMAINS_DEFAULT="${AI_CHECK_DOMAINS}"
AI_CHECK_MIN_OK_TENTHS_DEFAULT="${AI_CHECK_MIN_OK_TENTHS}"
DENY_LOCS="\${WARP_DENY_LOCS:-\${DENY_LOCS_DEFAULT}}"
ACCEPT_LOCS="\${WARP_ACCEPT_LOCS:-\${ACCEPT_LOCS_DEFAULT}}"
PREFERRED_LOCS="\${WARP_PREFERRED_LOCS:-\${PREFERRED_LOCS_DEFAULT}}"
AI_CHECK_DOMAINS="\${WARP_AI_CHECK_DOMAINS:-\${AI_CHECK_DOMAINS_DEFAULT}}"
AI_CHECK_MIN_OK_TENTHS="\${WARP_AI_CHECK_MIN_OK_TENTHS:-\${AI_CHECK_MIN_OK_TENTHS_DEFAULT}}"
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

# Real end-to-end check: confirm chatgpt.com/claude.ai/gemini etc actually
# answer through the warp interface, not just that Cloudflare's own trace
# endpoint says warp=on/loc=OK. A WARP IP can be perfectly fine by
# Cloudflare's own metric while being independently rate-limited/blocked by
# the AI providers themselves (shared consumer WARP egress gets flagged).
ai_domains_ok() {
  local ok=0 total=0 code domain
  for domain in \$AI_CHECK_DOMAINS; do
    total=\$((total + 1))
    code="\$(curl -4 --interface "\$IFACE" -o /dev/null -s -w '%{http_code}' \\
      --max-time 6 --connect-timeout 5 "https://\${domain}/" 2>/dev/null)"
    code="\${code:-000}"
    [[ "\$code" =~ ^[0-9]{4,}\$ ]] && code="\${code: -3}"
    [[ "\$code" != "000" ]] && ok=\$((ok + 1))
  done
  [[ "\$total" -eq 0 ]] && return 1
  (( ok * 10 >= AI_CHECK_MIN_OK_TENTHS * total ))
}

tr="\$(curl -4 --interface "\$IFACE" --max-time 8 -s "\$TRACE_URL" || true)"
warp="\$(trace_field "\$tr" "warp")"
loc="\$(trace_field "\$tr" "loc")"

if [[ "\$warp" == "on" ]] && acceptable "\$loc" && ai_domains_ok; then
  exit 0
fi

if [[ "\$warp" == "on" ]] && acceptable "\$loc"; then
  logger -t warp-auto "WARP loc=\${loc:-empty} OK by Cloudflare, but AI domains unreachable through \$IFACE; rescanning"
else
  logger -t warp-auto "Bad WARP state: warp=\${warp:-empty} loc=\${loc:-empty}; rescanning endpoints"
fi

"${SELF_PATH_INSTALLED}" --rescan-only --deny="\${DENY_LOCS}" \${ACCEPT_LOCS:+--accept="\${ACCEPT_LOCS}"} \${PREFERRED_LOCS:+--prefer="\${PREFERRED_LOCS}"} --no-timer
EOF_RECHECK

  chmod +x /usr/local/sbin/warp-auto-recheck.sh

  cat >/etc/systemd/system/warp-auto-recheck.service <<'EOF_SERVICE'
[Unit]
Description=Eclipse WARP egress location recheck

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warp-auto-recheck.sh
EOF_SERVICE

  cat >/etc/systemd/system/warp-auto-recheck.timer <<EOF_TIMER
[Unit]
Description=Periodic Eclipse WARP egress location recheck

[Timer]
OnBootSec=2min
OnUnitActiveSec=${WATCHDOG_INTERVAL_MIN}min
AccuracySec=30sec
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

  systemctl daemon-reload
  if systemctl enable --now warp-auto-recheck.timer >>"$LOG_FILE" 2>&1; then
    say "Watchdog включён: warp-auto-recheck.timer (каждые ${WATCHDOG_INTERVAL_MIN} мин, проверяет loc + реальную доступность AI-доменов)"
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

  local ai_ok_state=0
  if [[ "$wwarp" == "on" ]]; then
    info "Проверка доступности AI-сервисов через $IFACE..."
    local ai_result ai_ok ai_total ai_detail
    ai_result="$(check_ai_domains_via_warp)"
    ai_ok="$(echo "$ai_result" | awk '{print $1}')"
    ai_total="$(echo "$ai_result" | awk '{print $2}')"
    ai_detail="$(echo "$ai_result" | cut -d' ' -f3-)"
    format_status_value "AI domains" "${ai_ok}/${ai_total} (${ai_detail})"
    line
    if (( ai_ok * 10 >= AI_CHECK_MIN_OK_TENTHS * ai_total )); then
      ai_ok_state=1
    fi
  fi

  if [[ "$wwarp" == "on" ]] && warp_acceptable "$wloc" && [[ "$ai_ok_state" -eq 1 ]]; then
    say "Состояние нормальное: WARP работает, loc допустимый, AI-сервисы отвечают."
  elif [[ "$wwarp" == "on" ]] && warp_acceptable "$wloc"; then
    warn "loc допустимый, но AI-сервисы плохо отвечают через этот endpoint — стоит пересканировать (пункт 2)."
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

  if ip link show "$IFACE" >/dev/null 2>&1; then
    local ai_result ai_ok ai_total ai_detail
    ai_result="$(check_ai_domains_via_warp)"
    ai_ok="$(echo "$ai_result" | awk '{print $1}')"
    ai_total="$(echo "$ai_result" | awk '{print $2}')"
    ai_detail="$(echo "$ai_result" | cut -d' ' -f3-)"
    format_status_value "AI domains" "${ai_ok}/${ai_total} (${ai_detail})"
  fi

  line
  printf "${WHITE}${BOLD}Remnawave/Xray outbound (добавь в outbounds):${RESET}\n\n"
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

  printf "\n${WHITE}${BOLD}Routing rule (добавь В НАЧАЛО списка rules, до общих правил):${RESET}\n\n"
  cat <<'EOF'
{
  "type": "field",
  "domain": [
    "domain:chatgpt.com",
    "domain:openai.com",
    "domain:oaistatic.com",
    "domain:oaiusercontent.com",
    "domain:oaistatsig.com",
    "domain:openaimerge.com",
    "domain:intercom.io",
    "domain:intercomcdn.com",
    "domain:ct.sendgrid.net",
    "domain:sora.com",
    "domain:claude.ai",
    "domain:claude.com",
    "domain:anthropic.com",
    "domain:gemini.google.com",
    "domain:gemini.google",
    "domain:aistudio.google.com",
    "domain:ai.google.dev",
    "full:generativelanguage.googleapis.com",
    "domain:makersuite.google.com",
    "domain:notebooklm.google",
    "domain:notebooklm.google.com",
    "domain:labs.google",
    "domain:flow.google",
    "domain:codeassist.google",
    "domain:copilot.microsoft.com",
    "domain:copilot.cloud.microsoft",
    "domain:m365.cloud.microsoft",
    "domain:bing.com",
    "domain:bingsandbox.com",
    "domain:perplexity.ai",
    "domain:pplx.ai",
    "domain:perplexity.com",
    "domain:mistral.ai",
    "domain:chat.mistral.ai",
    "domain:console.mistral.ai",
    "domain:api.mistral.ai",
    "domain:deepseek.com",
    "domain:chat.deepseek.com",
    "domain:api.deepseek.com",
    "domain:grok.com",
    "domain:x.ai",
    "full:api.x.ai",
    "domain:meta.ai",
    "domain:ai.meta.com",
    "domain:llama.com",
    "domain:poe.com",
    "domain:character.ai",
    "domain:huggingface.co",
    "domain:hf.co",
    "domain:hf.space",
    "domain:huggingfacecdn.com",
    "domain:you.com",
    "domain:phind.com",
    "domain:cursor.com",
    "domain:cursor.sh",
    "domain:anysphere.co",
    "domain:windsurf.com",
    "domain:codeium.com",
    "domain:replit.com"
  ],
  "outboundTag": "warp-out"
}
EOF

  printf "\n${WHITE}${BOLD}Проверки:${RESET}\n"
  cat <<'EOF'
  ip route
  wg show warp
  curl -4 --interface warp https://www.cloudflare.com/cdn-cgi/trace
  curl -4 https://www.cloudflare.com/cdn-cgi/trace
  curl -4 --interface warp -o /dev/null -s -w '%{http_code}\n' https://chatgpt.com/
  curl -4 --interface warp -o /dev/null -s -w '%{http_code}\n' https://claude.ai/
  curl -4 --interface warp -o /dev/null -s -w '%{http_code}\n' https://gemini.google.com/
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
  format_status_value "Preferred locs" "${PREFERRED_LOCS:-нет}"
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
    printf "  ${GREEN}2)${RESET} Пересканировать WARP endpoints (US-приоритет)\n"
    printf "  ${GREEN}3)${RESET} Статус WARP\n"
    printf "  ${GREEN}4)${RESET} Проверить доступность AI-сервисов через WARP\n"
    printf "  ${GREEN}5)${RESET} Ручная инструкция\n"
    printf "  ${GREEN}6)${RESET} Удалить/отключить WARP Manager\n"
    printf "  ${GREEN}0)${RESET} Выход\n"
    printf "\n${GRAY}Настройки сейчас: prefer=%s, deny=%s, accept=%s, iface=%s${RESET}\n" \
      "${PREFERRED_LOCS:-none}" "${DENY_LOCS:-none}" "${ACCEPT_LOCS:-any}" "$IFACE"
    printf "\nВведите номер: "
    read -r choice || true

    case "$choice" in
      1) MODE="auto"; auto_install; pause_enter ;;
      2) MODE="rescan"; RESCAN_ONLY=1; require_root; ensure_safe_conf; start_warp; scan_endpoints; print_final_summary; pause_enter ;;
      3) show_status; pause_enter ;;
      4)
        banner
        step "Проверка AI-сервисов через $IFACE"
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
          fail "Интерфейс $IFACE не найден. Сначала установи WARP (пункт 1)."
        else
          local ai_result ai_ok ai_total ai_detail
          ai_result="$(check_ai_domains_via_warp)"
          ai_ok="$(echo "$ai_result" | awk '{print $1}')"
          ai_total="$(echo "$ai_result" | awk '{print $2}')"
          ai_detail="$(echo "$ai_result" | cut -d' ' -f3-)"
          for pair in $ai_detail; do
            local d="${pair%=*}" c="${pair#*=}"
            if [[ "$c" == "000" ]]; then
              fail "$d -> нет соединения"
            else
              say "$d -> HTTP $c"
            fi
          done
          line
          if (( ai_ok * 10 >= AI_CHECK_MIN_OK_TENTHS * ai_total )); then
            say "Итог: ${ai_ok}/${ai_total} доменов доступны — норма."
          else
            warn "Итог: ${ai_ok}/${ai_total} доменов доступны — мало, стоит пересканировать (пункт 2)."
          fi
        fi
        pause_enter
        ;;
      5) manual_page; pause_enter ;;
      6) uninstall_warp; pause_enter ;;
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
