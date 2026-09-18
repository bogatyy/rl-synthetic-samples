#!/usr/bin/env bash
set -euo pipefail

rpc_url=${RPC_URL:-http://127.0.0.1:8545}
anvil_host=${ANVIL_HOST:-127.0.0.1}
chain_id=${CHAIN_ID:-1}
hardfork=${ANVIL_HARDFORK:-cancun}
chain_mode=${CHAIN_MODE:-local}
pid_file=/tmp/rl-task-anvil.pid
log_file=/tmp/rl-task-anvil.log
ready_file=/tmp/rl-task-scenario.ready
pid=""
keep_child=0

[[ "$chain_mode" == local ]] || {
  echo "[task] only local chain mode is supported" >&2
  exit 1
}

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

scenario_contract=${SCENARIO_CONTRACT:-}
scenario_setup_script=${SCENARIO_SETUP_SCRIPT:-}
scenario_solc=${SCENARIO_SOLC:-}
scenario_target=${SCENARIO_TARGET_ADDRESS:?SCENARIO_TARGET_ADDRESS is required}
scenario_value=${SCENARIO_DEPLOY_VALUE:-0}
scenario_ready_delay=${SCENARIO_READY_DELAY_SECONDS:-0}

[[ "$scenario_ready_delay" =~ ^[0-9]+$ ]] || {
  echo "[task] SCENARIO_READY_DELAY_SECONDS must be a non-negative integer" >&2
  exit 1
}

if [[ -z "$scenario_contract" && -z "$scenario_setup_script" ]]; then
  echo "[task] SCENARIO_CONTRACT or SCENARIO_SETUP_SCRIPT is required" >&2
  exit 1
fi
if [[ -n "$scenario_contract" && -n "$scenario_setup_script" ]]; then
  echo "[task] configure only one scenario deployment method" >&2
  exit 1
fi

if cast block-number --rpc-url "$rpc_url" >/dev/null 2>&1; then
  if [[ "$(cast code "$scenario_target" --rpc-url "$rpc_url")" != 0x ]]; then
    touch "$ready_file"
    exit 0
  fi
  echo "[task] RPC is running without the configured scenario" >&2
  exit 1
fi

anvil --chain-id "$chain_id" --host "$anvil_host" --port 8545 \
  --hardfork "$hardfork" --base-fee 0 --gas-price 0 --gas-limit 100000000 \
  --silent >"$log_file" 2>&1 &
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

if [[ -n "$scenario_setup_script" ]]; then
  setup=(
    forge script --root /opt/scenario "/opt/scenario/$scenario_setup_script"
    --offline --broadcast --slow --gas-estimate-multiplier 200 --rpc-url "$rpc_url"
  )
  if [[ -n "$scenario_solc" ]]; then
    setup+=(--use "$scenario_solc")
  fi
  setup_environment=(env)
  if [[ -n "$scenario_solc" ]]; then
    setup_environment+=(-u FOUNDRY_SOLC)
  fi
  deployment=$("${setup_environment[@]}" "${setup[@]}" 2>&1) || {
    printf '%s\n' "$deployment" >&2
    exit 1
  }
  [[ "$(cast code "$scenario_target" --rpc-url "$rpc_url")" != 0x ]] || {
    echo "[task] setup did not deploy the target" >&2
    exit 1
  }
else
  private_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  deploy=(
    forge create --root /opt/scenario "$scenario_contract" --offline --broadcast
    --rpc-url "$rpc_url" --private-key "$private_key" --gas-limit 100000000
    --legacy --gas-price 0
  )
  if [[ "$scenario_value" != 0 ]]; then
    deploy+=(--value "$scenario_value")
  fi
  deployment=$("${deploy[@]}" 2>&1) || {
    printf '%s\n' "$deployment" >&2
    exit 1
  }
  deployed=$(printf '%s\n' "$deployment" | awk '/Deployed to:/ {print $3}' | tail -1)
  [[ "${deployed,,}" == "${scenario_target,,}" ]] || {
    echo "[task] scenario deployed to an unexpected address" >&2
    exit 1
  }
fi

if (( scenario_ready_delay > 0 )); then
  sleep "$scenario_ready_delay"
fi
touch "$ready_file"
echo "[task] local scenario ready at block $(cast block-number --rpc-url "$rpc_url")"
keep_child=1
