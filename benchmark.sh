#!/bin/bash
# benchmark.sh - Main benchmark orchestrator using hey and uv

set -euo pipefail

PARSER="$(pwd)/parse_args.sh"
FORMATTER="$(pwd)/format.sh"

# get arguments using the parser script
source "$PARSER" "$@"
SCRIPT_FILE="$BENCH_SCRIPT_FILE"
HOST="$BENCH_HOST"
ENDPOINT="$BENCH_ENDPOINT"
HEY_REQUESTS="$BENCH_REQUESTS"
HEY_CONCURRENCY="$BENCH_CONCURRENCY"

# Start server
"$FORMATTER" status "Starting server: uv run $SCRIPT_FILE"
SERVER_LOG=$(mktemp)
set +e
uv run "$SCRIPT_FILE" > "$SERVER_LOG" 2>&1 &
sleep 0.5
SERVER_PROC=$!
set -e

# Extract PID from log
"$FORMATTER" status "Waiting for server to start..."
PID=""
for _ in {1..50}; do
  if grep -q "Started server process" "$SERVER_LOG"; then
    PID=$(grep "Started server process" "$SERVER_LOG" | tail -n1 | sed -E 's/.*\[(^[]]*)\].*/\1/' | grep -oE '[0-9]+')
    break
  fi
  sleep 0.1
done

if [[ -z "$PID" ]]; then
  # fallback parse with grep -oP if available
  if command -v grep >/dev/null 2>&1; then
    PID=$(grep "Started server process" "$SERVER_LOG" | tail -n1 | grep -oE '\[[0-9]+\]' | tr -d '[]' || true)
  fi
fi

if [[ -z "$PID" ]]; then
  "$FORMATTER" error "Failed to extract PID from server logs"
  kill "$SERVER_PROC" 2>/dev/null || true
  rm -f "$SERVER_LOG"
  exit 1
fi

"$FORMATTER" status "Server started with PID: $PID"

# Wait until endpoint ready
"$FORMATTER" status "Waiting for server to be ready at ${HOST}${ENDPOINT}"
for _ in {1..100}; do
  if curl -sSf "${HOST}${ENDPOINT}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
sleep 0.3
"$FORMATTER" status "Server ready"

# Function to extract value from /proc/PID/status
get_proc_status() {
  local pid="$1"
  local key="$2"
  if [[ -f "/proc/$pid/status" ]]; then
    grep "^${key}:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}' || echo ""
  else
    echo ""
  fi
}

# RAM monitor (sample VmRSS only)
RAM_LOG=$(mktemp)
{
  while kill -0 "$PID" 2>/dev/null; do
    rss=$(get_proc_status "$PID" "VmRSS")
    [[ -n "$rss" ]] && echo "$rss" >> "$RAM_LOG"
    sleep 0.5
  done
} &
MONITOR_PID=$!

# Run hey with live spinner
"$FORMATTER" status "Running benchmark: hey -n $HEY_REQUESTS -c $HEY_CONCURRENCY ${HOST}${ENDPOINT}"
"$FORMATTER" progress_start
HEY_OUTPUT=$(mktemp)
set +e
hey -n "$HEY_REQUESTS" -c "$HEY_CONCURRENCY" "${HOST}${ENDPOINT}" >"$HEY_OUTPUT" 2>&1
HEY_EXIT=$?
set -e
"$FORMATTER" progress_end

if [[ $HEY_EXIT -ne 0 ]]; then
  "$FORMATTER" error "hey failed. Output:"
  cat "$HEY_OUTPUT" >&2
  # Cleanup
  kill "$SERVER_PROC" 2>/dev/null || true
  kill "$MONITOR_PID" 2>/dev/null || true
  wait "$SERVER_PROC" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true
  rm -f "$SERVER_LOG" "$HEY_OUTPUT" "$RAM_LOG"
  exit 1
fi

# Parse hey output (only the requested parts)
Total=$(grep -E "^  Total:" "$HEY_OUTPUT" | sed -E 's/^  Total:[[:space:]]+//' || echo "N/A")
Slowest=$(grep -E "^  Slowest:" "$HEY_OUTPUT" | sed -E 's/^  Slowest:[[:space:]]+//' || echo "N/A")
Fastest=$(grep -E "^  Fastest:" "$HEY_OUTPUT" | sed -E 's/^  Fastest:[[:space:]]+//' || echo "N/A")
Average=$(grep -E "^  Average:" "$HEY_OUTPUT" | sed -E 's/^  Average:[[:space:]]+//' || echo "N/A")
RPS=$(grep -E "^  Requests/sec:" "$HEY_OUTPUT" | awk '{print $2}' || echo "N/A")

TotalData_bytes=$(grep -E "^  Total data:" "$HEY_OUTPUT" | awk '{print $3}' || echo "0")
TotalData=$("$FORMATTER" bytes_to_mb "$TotalData_bytes")
SizeReq_bytes=$(grep -E "^  Size/request:" "$HEY_OUTPUT" | awk '{print $2}' || echo "0")
SizeReq=$("$FORMATTER" bytes_to_mb "$SizeReq_bytes")

DNS_dialup=$(grep -E "^  DNS\+dialup:" "$HEY_OUTPUT" | sed -E 's/^  DNS\+dialup:[[:space:]]+//' || echo "N/A")
DNS_lookup=$(grep -E "^  DNS-lookup:" "$HEY_OUTPUT" | sed -E 's/^  DNS-lookup:[[:space:]]+//' || echo "N/A")
Req_write=$(grep -E "^  req write:" "$HEY_OUTPUT" | sed -E 's/^  req write:[[:space:]]+//' || echo "N/A")
Resp_wait=$(grep -E "^  resp wait:" "$HEY_OUTPUT" | sed -E 's/^  resp wait:[[:space:]]+//' || echo "N/A")
Resp_read=$(grep -E "^  resp read:" "$HEY_OUTPUT" | sed -E 's/^  resp read:[[:space:]]+//' || echo "N/A")

# Get thread count from /proc/PID/status (threads don't die, just get final count)
THREADS=$(get_proc_status "$PID" "Threads")
if [[ -z "$THREADS" ]]; then
  THREADS="N/A"
fi

# RAM stats (convert KB to MB)
if [[ -s "$RAM_LOG" ]]; then
  AVG_RAM=$(awk '{s+=$1;n++} END{if(n>0) printf "%.2f", s/n/1024; else print "0"}' "$RAM_LOG")
  MIN_RAM=$(sort -n "$RAM_LOG" | head -1 | awk '{printf "%.2f", $1/1024}')
  
  # Get peak RAM from VmHWM (High Water Mark)
  hwm=$(get_proc_status "$PID" "VmHWM")
  if [[ -n "$hwm" ]]; then
    MAX_RAM=$(echo "$hwm" | awk '{printf "%.2f", $1/1024}')
  else
    MAX_RAM="N/A"
  fi
else
  AVG_RAM="N/A"
  MAX_RAM="N/A"
  MIN_RAM="N/A"
fi

# Cleanup server and monitor
"$FORMATTER" status "Shutting down server"
kill "$SERVER_PROC" 2>/dev/null || true
kill "$MONITOR_PID" 2>/dev/null || true
wait "$SERVER_PROC" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true

rm -f "$SERVER_LOG" "$HEY_OUTPUT" "$RAM_LOG"

# Print summary
"$FORMATTER" summary \
  "$SCRIPT_FILE" \
  "$HOST" \
  "$ENDPOINT" \
  "$HEY_REQUESTS" \
  "$HEY_CONCURRENCY" \
  "$Total" \
  "$Slowest" \
  "$Fastest" \
  "$Average" \
  "$RPS" \
  "$TotalData" \
  "$SizeReq" \
  "$DNS_dialup" \
  "$DNS_lookup" \
  "$Req_write" \
  "$Resp_wait" \
  "$Resp_read" \
  "$THREADS" \
  "$AVG_RAM" \
  "$MAX_RAM" \
  "$MIN_RAM"