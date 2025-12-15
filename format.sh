#!/bin/bash
# format.sh - Pretty output formatter (colors only for labels/values, not emojis)

set -euo pipefail

# Colors
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

# Emojis (printed plain, not color-wrapped)
ROCKET="🚀"
GEAR="⚙️"
CHART="📊"
CLOCK="⏱️"
FIRE="🔥"
THREAD="🧵"
CHECK="✓"
CROSS="✗"
HOURGLASS="⏳"

SPINNER_PID_FILE="${TMPDIR:-/tmp}/.bench_spinner_pid"

status() {
  echo -e "${GEAR} ${BLUE}$1${RESET}"
}

error() {
  echo -e "${CROSS} ${RED}Error:${RESET} $1" >&2
}

progress_start() {
  # Start a background spinner that dots every 0.2s
  # Print a one-time header line
  echo -ne "${HOURGLASS} ${YELLOW}Benchmarking${RESET}"
  (
    while true; do
      echo -n "."
      sleep 0.2
    done
  ) &
  echo $! > "$SPINNER_PID_FILE"
}

progress_end() {
  # Stop spinner and print check mark on a new line
  if [[ -f "$SPINNER_PID_FILE" ]]; then
    pid=$(cat "$SPINNER_PID_FILE" || true)
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$SPINNER_PID_FILE"
  fi
  echo -e " ${GREEN}${CHECK}${RESET}"
}

bytes_to_mb() {
  local bytes="$1"
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    awk "BEGIN {printf \"%.2f\", $bytes/1024/1024}"
  else
    echo "0.00"
  fi
}

summary() {
  local script="$1"
  local host="$2"
  local endpoint="$3"
  local requests="$4"
  local concurrency="$5"
  local total="$6"
  local slowest="$7"
  local fastest="$8"
  local average="$9"
  local rps="${10}"
  local total_data="${11}"
  local size_req="${12}"
  local dns_dialup="${13}"
  local dns_lookup="${14}"
  local req_write="${15}"
  local resp_wait="${16}"
  local resp_read="${17}"
  local threads="${18}"
  local avg_ram="${19}"
  local max_ram="${20}"
  local min_ram="${21}"

  echo ""
  echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║${RESET} ${ROCKET}  ${BOLD}${CYAN}BENCHMARK RESULTS${RESET}                                     ${BOLD}${CYAN}\t║${RESET}"
  echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""

  echo -e "${BOLD}${MAGENTA}Test Configuration${RESET}"
  echo -e "  ${BOLD}${BLUE}Script:${RESET}       ${BOLD}$script${RESET}"
  echo -e "  ${BOLD}${BLUE}URL:${RESET}          ${BOLD}${host}${endpoint}${RESET}"
  echo -e "  ${BOLD}${BLUE}Requests:${RESET}     ${BOLD}$requests${RESET}"
  echo -e "  ${BOLD}${BLUE}Concurrency:${RESET}  ${BOLD}$concurrency${RESET}"
  echo ""

  echo -e "${FIRE} ${BOLD}${GREEN}Performance Metrics${RESET}"
  echo -e "  ${BOLD}${BLUE}Total time:${RESET}      ${BOLD}$total${RESET}"
  echo -e "  ${BOLD}${BLUE}Requests/sec:${RESET}    ${BOLD}${GREEN}$rps${RESET}"
  echo -e "  ${BOLD}${BLUE}Average latency:${RESET} ${BOLD}$average${RESET}"
  echo -e "  ${BOLD}${BLUE}Fastest:${RESET}         ${BOLD}${GREEN}$fastest${RESET}"
  echo -e "  ${BOLD}${BLUE}Slowest:${RESET}         ${BOLD}${RED}$slowest${RESET}"
  echo ""

  echo -e "${CHART} ${BOLD}${BLUE}Request Summary${RESET}"
  echo -e "  ${BOLD}${BLUE}Total data:${RESET}      ${BOLD}${total_data} MB${RESET}"
  echo -e "  ${BOLD}${BLUE}Size/request:${RESET}    ${BOLD}${size_req} MB${RESET}"
  echo ""

  echo -e "${CLOCK} ${BOLD}${YELLOW}Details (average, fastest, slowest)${RESET}"
  echo -e "  ${BOLD}${BLUE}DNS+dialup:${RESET}  ${BOLD}$dns_dialup${RESET}"
  echo -e "  ${BOLD}${BLUE}DNS lookup:${RESET}  ${BOLD}$dns_lookup${RESET}"
  echo -e "  ${BOLD}${BLUE}Request:${RESET}     ${BOLD}$req_write${RESET}"
  echo -e "  ${BOLD}${BLUE}Wait:${RESET}        ${BOLD}$resp_wait${RESET}"
  echo -e "  ${BOLD}${BLUE}Response:${RESET}    ${BOLD}$resp_read${RESET}"
  echo ""

  echo -e "${THREAD} ${BOLD}${MAGENTA}Thread Usage${RESET}"
  echo -e "  ${BOLD}${BLUE}Total Threads Spawned:${RESET} ${BOLD}$threads${RESET}"
  echo ""

  echo -e "💾 ${BOLD}${MAGENTA}Memory Usage (MB)${RESET}"
  if [[ "$avg_ram" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf "  ${BOLD}${BLUE}Average:${RESET}     ${BOLD}%.2f MB${RESET}\n" "$avg_ram"
  else
    echo -e "  ${BOLD}${BLUE}Average:${RESET}     ${BOLD}$avg_ram${RESET}"
  fi
  if [[ "$min_ram" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf "  ${BOLD}${BLUE}Min:${RESET}         ${BOLD}%.2f MB${RESET}\n" "$min_ram"
  else
    echo -e "  ${BOLD}${BLUE}Min:${RESET}         ${BOLD}$min_ram${RESET}"
  fi
  if [[ "$max_ram" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf "  ${BOLD}${BLUE}Max:${RESET}         ${BOLD}%.2f MB${RESET}\n" "$max_ram"
  else
    echo -e "  ${BOLD}${BLUE}Max:${RESET}         ${BOLD}$max_ram${RESET}"
  fi
  echo ""
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${RESET}"
  echo ""
}

# Command dispatcher
CMD="${1:-}"
shift || true
case "$CMD" in
  status) status "$@";;
  error) error "$@";;
  progress_start) progress_start ;;
  progress_end) progress_end ;;
  bytes_to_mb) bytes_to_mb "$@";;
  summary) summary "$@";;
  *) echo "Unknown command: $CMD" >&2; exit 1;;
esac