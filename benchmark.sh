#!/bin/bash
# benchmark.sh - Main benchmark orchestrator using hey and uv

set -euo pipefail

PARSER="$(pwd)/parse_args.sh"
FORMATTER="$(pwd)/formatting/format.sh"

# Load bash loading animations
source "$(pwd)/formatting/bash_loading_animations.sh"

# Stop loading animation if script is interrupted
trap BLA::stop_loading_animation SIGINT

# get arguments using the parser script
source "$PARSER" "$@"
SCRIPT_FILE="$BENCH_SCRIPT_FILE"
HOST="$BENCH_HOST"
ENDPOINT="$BENCH_ENDPOINT"
HEY_REQUESTS="$BENCH_REQUESTS"
HEY_CONCURRENCY="$BENCH_CONCURRENCY"

# Extract worker PIDs to monitor
# Returns space-separated list of PIDs that should be monitored
# Case 1: No workers (1 process) - returns the single python child of uv
# Case 2: Multiple workers - returns only the worker children (excludes parent python and watch process)
get_worker_pids() {
  local uv_pid="$1"
  local max_wait="${2:-10}"  # seconds to wait for processes
  local pids=""
  
  # Wait for uv to spawn its python child
  local python_pid=""
  for _ in $(seq 1 $((max_wait * 10))); do
    python_pid=$(pgrep -P "$uv_pid" 2>/dev/null | head -1 || true)
    if [[ -n "$python_pid" ]]; then
      break
    fi
    sleep 0.1
  done
  
  if [[ -z "$python_pid" ]]; then
    echo ""
    return
  fi
  
  # Wait longer for potential workers to spawn (uvicorn takes time to fork workers)
  # Keep checking until we see workers stabilize or timeout
  local prev_count=0
  local stable_checks=0
  for _ in $(seq 1 $((max_wait * 10))); do
    local worker_pids
    worker_pids=$(pgrep -P "$python_pid" 2>/dev/null || true)
    local current_count=0
    
    if [[ -n "$worker_pids" ]]; then
      current_count=$(echo "$worker_pids" | wc -l)
    fi
    
    if [[ "$current_count" -gt 0 ]]; then
      if [[ "$current_count" -eq "$prev_count" ]]; then
        stable_checks=$((stable_checks + 1))
        # Workers have stabilized (same count for 5 checks = 0.5s)
        if [[ $stable_checks -ge 5 ]]; then
          # Multiple workers case - exclude watch process (first/lowest PID)
          pids=$(echo "$worker_pids" | sort -n | tail -n +2 | tr '\n' ' ')
          echo "$pids"
          return
        fi
      else
        stable_checks=0
      fi
      prev_count=$current_count
    fi
    sleep 0.1
  done
  
  # Check one final time for workers
  local final_workers
  final_workers=$(pgrep -P "$python_pid" 2>/dev/null | sort -n | tail -n +2 || true)
  
  if [[ -n "$final_workers" ]]; then
    # Multiple workers case
    echo "$final_workers" | tr '\n' ' '
  else
    # Single process case - return the main python PID
    echo "$python_pid"
  fi
}

# Start server
"$FORMATTER" status "Starting server: uv run $SCRIPT_FILE"
SERVER_LOG=$(mktemp)
set +e
uv run "$SCRIPT_FILE" > "$SERVER_LOG" 2>&1 &
SERVER_PROC=$!
set -e

# Extract PIDs using pgrep
BLA_loading_text='⏱️  \033[34mWaiting for server processes to start\033[0m '
BLA_loading_color='\033[36m'
BLA::start_loading_animation "${BLA_braille_whitespace[@]}"
WORKER_PIDS=$(get_worker_pids "$SERVER_PROC" 10)
BLA::stop_loading_animation

if [[ -z "$WORKER_PIDS" ]]; then
  "$FORMATTER" error "Failed to detect server processes"
  kill "$SERVER_PROC" 2>/dev/null || true
  rm -f "$SERVER_LOG"
  exit 1
fi

# Convert to array for easier handling
read -ra PID_ARRAY <<< "$WORKER_PIDS"
NUM_WORKERS=${#PID_ARRAY[@]}

if [[ $NUM_WORKERS -eq 1 ]]; then
  "$FORMATTER" status "Server started with PID: ${PID_ARRAY[0]}"
else
  "$FORMATTER" status "Server started with $NUM_WORKERS workers: ${PID_ARRAY[*]}"
fi

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

# Aggregate proc status value across multiple PIDs
get_aggregate_proc_status() {
  local key="$1"
  shift
  local pids=("$@")
  local total=0
  
  for pid in "${pids[@]}"; do
    local val
    val=$(get_proc_status "$pid" "$key")
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      total=$((total + val))
    fi
  done
  
  echo "$total"
}

# RAM monitor - samples VmRSS from all worker PIDs
RAM_LOG=$(mktemp)
{
  # Re-define get_proc_status in subshell since functions don't transfer
  _get_proc_status() {
    local pid="$1"
    local key="$2"
    if [[ -f "/proc/$pid/status" ]]; then
      grep "^${key}:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}' || echo ""
    else
      echo ""
    fi
  }

  while true; do
    # Check if any monitored process is still alive
    any_alive=false
    for pid in "${PID_ARRAY[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        any_alive=true
        break
      fi
    done
    
    if ! $any_alive; then
      break
    fi
    
    # Sum RSS across all workers
    total_rss=0
    for pid in "${PID_ARRAY[@]}"; do
      rss=$(_get_proc_status "$pid" "VmRSS")
      if [[ -n "$rss" && "$rss" =~ ^[0-9]+$ ]]; then
        total_rss=$((total_rss + rss))
      fi
    done
    
    [[ $total_rss -gt 0 ]] && echo "$total_rss" >> "$RAM_LOG"
    sleep 0.5
  done
} &
MONITOR_PID=$!

# Run hey with live spinner
"$FORMATTER" status "Running command: hey -n $HEY_REQUESTS -c $HEY_CONCURRENCY ${HOST}${ENDPOINT}"
BLA_loading_text='⏳ \033[34mBenchmarking\033[0m '
BLA_loading_color='\033[33m'
BLA::start_loading_animation "${BLA_modern_metro[@]}"
HEY_OUTPUT=$(mktemp)
set +e
hey -n "$HEY_REQUESTS" -c "$HEY_CONCURRENCY" "${HOST}${ENDPOINT}" >"$HEY_OUTPUT" 2>&1
HEY_EXIT=$?
set -e
BLA::stop_loading_animation

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

# Capture VmHWM (peak RAM) and thread count AFTER benchmark but BEFORE killing the server
MAX_RAM_KB=0
for pid in "${PID_ARRAY[@]}"; do
  hwm=$(get_proc_status "$pid" "VmHWM")
  if [[ -n "$hwm" && "$hwm" =~ ^[0-9]+$ ]]; then
    MAX_RAM_KB=$((MAX_RAM_KB + hwm))
  fi
done

# Capture thread count NOW (after benchmark, while processes still alive with full thread pools)
THREADS=$(get_aggregate_proc_status "Threads" "${PID_ARRAY[@]}")
if [[ -z "$THREADS" ]] || [[ "$THREADS" == "0" ]]; then
  THREADS="N/A"
fi

# RAM stats (convert KB to MB) - aggregated across all workers
if [[ -s "$RAM_LOG" ]]; then
  AVG_RAM=$(awk '{s+=$1;n++} END{if(n>0) printf "%.2f", s/n/1024; else print "0"}' "$RAM_LOG")
  
  if [[ $MAX_RAM_KB -gt 0 ]]; then
    MAX_RAM=$(echo "$MAX_RAM_KB" | awk '{printf "%.2f", $1/1024}')
  else
    MAX_RAM="N/A"
  fi
else
  AVG_RAM="N/A"
  MAX_RAM="N/A"
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
  "$NUM_WORKERS"