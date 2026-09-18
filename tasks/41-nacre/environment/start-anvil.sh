#!/usr/bin/env bash
set -euo pipefail

rpc_url=${RPC_URL:-http://127.0.0.1:8545}
anvil_host=${ANVIL_HOST:-127.0.0.1}
chain_id=${CHAIN_ID:-1}
hardfork=${ANVIL_HARDFORK:-cancun}
pid_file=/tmp/rl-task-anvil.pid
log_file=/tmp/rl-task-anvil.log
ready_file=/tmp/rl-task-scenario.ready
target=${SCENARIO_TARGET_ADDRESS:?SCENARIO_TARGET_ADDRESS is required}
pid=""
keep_child=0

cleanup_failed_start() {
  if (( keep_child == 0 )) && [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
  fi
}
trap cleanup_failed_start EXIT

if [[ "${1:-}" == --restart && -f "$pid_file" ]]; then
  pid=$(<"$pid_file")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pid=""
  rm -f "$pid_file"
fi
rm -f "$ready_file"

if cast block-number --rpc-url "$rpc_url" >/dev/null 2>&1; then
  if [[ "$(cast code "$target" --rpc-url "$rpc_url")" != 0x ]]; then
    touch "$ready_file"
    exit 0
  fi
  echo "[task] RPC is running without the configured scenario" >&2
  exit 1
fi

# The production vault advances in fixed fourteen-day epochs. Start at the
# first historical round and advance Anvil's clock between ordinary lifecycle
# calls instead of changing contract storage or patching its runtime.
anvil --chain-id "$chain_id" --host "$anvil_host" --port 8545 \
  --hardfork "$hardfork" --base-fee 0 --gas-price 0 --gas-limit 100000000 \
  --timestamp 1654438000 --silent >"$log_file" 2>&1 &
pid=$!
echo "$pid" > "$pid_file"

current=""
for _ in $(seq 1 120); do
  current=$(cast block-number --rpc-url "$rpc_url" 2>/dev/null || true)
  [[ "$current" == 0 ]] && break
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[task] local Anvil failed to start" >&2
    exit 1
  fi
  sleep 0.25
done
[[ "$current" == 0 ]] || {
  echo "[task] local Anvil did not become ready" >&2
  exit 1
}

run_phase() {
  local signature=$1
  local output
  output=$(forge script --root /opt/scenario /opt/scenario/script/Setup.s.sol:Setup \
    --sig "$signature" --offline --broadcast --slow --gas-estimate-multiplier 200 \
    --rpc-url "$rpc_url" 2>&1) || {
      printf '%s\n' "$output" >&2
      exit 1
    }
}

advance_to() {
  cast rpc --rpc-url "$rpc_url" evm_setNextBlockTimestamp "$1" >/dev/null
  cast rpc --rpc-url "$rpc_url" evm_mine >/dev/null
}

run_phase 'deployAndOpenFirstRound()'
advance_to 1654939000
run_phase 'openSecondRound()'
advance_to 1656256000
run_phase 'openThirdRound()'
advance_to 1657297000
run_phase 'openFourthRound()'
advance_to 1658484000
run_phase 'openFifthRound()'
advance_to 1659686500
run_phase 'settleAndLock()'

[[ "$(cast code "$target" --rpc-url "$rpc_url")" != 0x ]] || {
  echo "[task] setup did not deploy the target" >&2
  exit 1
}

touch "$ready_file"
echo "[task] local scenario ready at block $(cast block-number --rpc-url "$rpc_url")"
keep_child=1
