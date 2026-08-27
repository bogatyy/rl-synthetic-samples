#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
smoke="$repo_root/scripts/smoke_test.sh"
noop="$repo_root/scripts/fixtures/NoopExploit.sol"
parallelism=${RUNTIME_PARALLELISM:-4}
port_base=${RUNTIME_PORT_BASE:-24000}

tasks=(
  01-abecedarian
  12-kestrel
  13-lantern
  14-marrow
  15-nimbus
  16-opal
  17-praxis
  18-quartz
  19-riven
  20-sable
  21-talus
  22-umbra
  23-verdant
  24-willow
  25-xenon
  26-yarrow
  27-zephyr
  28-alder
  29-bracken
  30-cinder
  31-dovetail
)

runtime_root=$(mktemp -d /tmp/rl-independent-runtime.XXXXXX)
cleanup() {
  case "$runtime_root" in
    /tmp/rl-independent-runtime.*) rm -rf -- "$runtime_root" ;;
  esac
}
trap cleanup EXIT

[[ "$parallelism" =~ ^[1-9][0-9]*$ ]] || {
  echo "RUNTIME_PARALLELISM must be a positive integer" >&2
  exit 2
}

run_one() {
  local task=$1
  local ordinal=${task%%-*}
  local task_port_base=$((port_base + 10#$ordinal * 100))
  echo "[synthetic-runtime] $task reference"
  local reference_log="$runtime_root/$task.reference.log"
  if ! SMOKE_PORT_BASE="$task_port_base" SMOKE_TRACE_ON_FAILURE=0 \
    "$smoke" "$task" >"$reference_log" 2>&1; then
    cat "$reference_log" >&2
    return 1
  fi

  echo "[synthetic-runtime] $task no-op control"
  local noop_log="$runtime_root/$task.noop.log"
  if SMOKE_PORT_BASE="$task_port_base" SMOKE_TRACE_ON_FAILURE=0 \
    SMOKE_EXPLOIT_PATH="$noop" \
    "$smoke" "$task" >"$noop_log" 2>&1; then
    echo "no-op unexpectedly passed for $task" >&2
    cat "$noop_log" >&2
    return 1
  fi
  echo "[synthetic-runtime] $task passed"
}

failed=0
pids=()
for task in "${tasks[@]}"; do
  run_one "$task" &
  pids+=("$!")
  if (( ${#pids[@]} == parallelism )); then
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    pids=()
  fi
done
if (( ${#pids[@]} != 0 )); then
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
fi

if (( failed != 0 )); then
  echo "[synthetic-runtime] one or more controls failed" >&2
  exit 1
fi
echo "[synthetic-runtime] all ${#tasks[@]} references passed and no-op controls failed"
