#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
requested=${1:-all}
exploit_override=${SMOKE_EXPLOIT_PATH:-}
next_port=${SMOKE_PORT_BASE:-$((20000 + ($$ % 30000)))}
rpc_url=""
private_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
anvil_pid=""

tasks=()
for task_file in "$repo_root"/tasks/*/task.toml; do
  [[ -f "$task_file" ]] || continue
  tasks+=("$(basename "$(dirname "$task_file")")")
done

is_task() {
  local candidate=$1 known
  for known in "${tasks[@]}"; do
    [[ "$candidate" == "$known" ]] && return 0
  done
  return 1
}

if [[ "$requested" != all ]] && ! is_task "$requested"; then
  echo "unknown smoke task: $requested" >&2
  exit 2
fi

task_environment_value() {
  local task_id=$1 key=$2
  awk -v key="$key" '
    $1 == "ENV" && index($2, key "=") == 1 {
      sub("^" key "=", "", $2)
      print $2
    }
  ' "$repo_root/tasks/$task_id/environment/Dockerfile" | tail -1
}

task_verifier_value() {
  local task_id=$1 key=$2
  awk -F'"' -v key="$key" '
    /^\[verifier\.env\]$/ { in_section=1; next }
    in_section && /^\[/ { exit }
    in_section && $1 ~ "^" key "[[:space:]]*=[[:space:]]*$" { print $2; exit }
  ' "$repo_root/tasks/$task_id/task.toml"
}

smoke_root=$(mktemp -d /tmp/rl-synthetic-smoke.XXXXXX)

stop_anvil() {
  if [[ -n "$anvil_pid" ]]; then
    kill "$anvil_pid" 2>/dev/null || true
    wait "$anvil_pid" 2>/dev/null || true
    anvil_pid=""
  fi
}

cleanup() {
  stop_anvil
  if [[ "${SMOKE_KEEP_TMP:-0}" == 1 ]]; then
    echo "[smoke] kept diagnostics at $smoke_root" >&2
  else
    case "$smoke_root" in
      /tmp/rl-synthetic-smoke.*) rm -rf -- "$smoke_root" ;;
    esac
  fi
}
trap cleanup EXIT

terminate() {
  trap - EXIT HUP INT TERM
  cleanup
  exit 143
}
trap terminate HUP INT TERM

prepare_project() {
  local task_id=$1
  local task_dir="$repo_root/tasks/$task_id"
  local project_dir="$smoke_root/$task_id"
  local exploit_source="$task_dir/solution/Exploit.sol"
  if [[ -n "$exploit_override" ]]; then
    exploit_source=$exploit_override
  fi
  [[ -f "$exploit_source" ]]
  mkdir -p "$project_dir"
  cp -R "$repo_root/docker/core/project/." "$project_dir/"
  cp -R "$task_dir/environment/project/." "$project_dir/"
  cp "$exploit_source" "$project_dir/src/Exploit.sol"
  cp "$task_dir/tests/ExploitGrader.sol" "$project_dir/src/ExploitGrader.sol"
  forge clean --root "$project_dir"
  forge build --root "$project_dir" --offline --jobs 1 -q >/dev/null
  printf '%s\n' "$project_dir"
}

validate_source_registry() {
  local task_id=$1 scenario_dir=$2 chain_id=$3 setup_script=$4
  local registry="$scenario_dir/source-registry.json"
  local script_file=${setup_script%%:*}
  local broadcast="$scenario_dir/broadcast/$(basename "$script_file")/$chain_id/run-latest.json"
  [[ -f "$registry" && -f "$broadcast" ]] || {
    echo "[smoke] missing source registry or setup broadcast for $task_id" >&2
    return 1
  }

  python3 - "$registry" "$broadcast" <<'PY'
import json
import pathlib
import sys

registry_path = pathlib.Path(sys.argv[1])
broadcast_path = pathlib.Path(sys.argv[2])
registry = {
    address.lower(): entry
    for address, entry in json.loads(registry_path.read_text()).items()
}
creates = [
    tx
    for tx in json.loads(broadcast_path.read_text())["transactions"]
    if tx.get("transactionType") == "CREATE"
]
deployed = {tx["contractAddress"].lower(): tx["contractName"] for tx in creates}

missing = sorted(set(deployed) - set(registry))
extra = sorted(set(registry) - set(deployed))
wrong = sorted(
    address
    for address in set(deployed) & set(registry)
    if deployed[address] != registry[address]["name"]
)
if missing or extra or wrong:
    for address in missing:
        print(f"missing source entry: {address} ({deployed[address]})", file=sys.stderr)
    for address in extra:
        print(
            f"source entry has no setup deployment: {address} ({registry[address]['name']})",
            file=sys.stderr,
        )
    for address in wrong:
        print(
            f"wrong source entry at {address}: deployed {deployed[address]}, "
            f"registry names {registry[address]['name']}",
            file=sys.stderr,
        )
    raise SystemExit(1)
PY
}

start_scenario() {
  local task_id=$1
  local task_dir="$repo_root/tasks/$task_id"
  local scenario_dir
  local chain_id hardfork setup_script target current
  if [[ -n "${SMOKE_SCENARIO_PATH:-}" ]]; then
    scenario_dir=$SMOKE_SCENARIO_PATH
  else
    scenario_dir="$smoke_root/$task_id-scenario"
    cp -R "$task_dir/environment/scenario" "$scenario_dir"
  fi
  chain_id=$(task_environment_value "$task_id" CHAIN_ID)
  chain_id=${chain_id:-1}
  hardfork=$(task_environment_value "$task_id" ANVIL_HARDFORK)
  hardfork=${hardfork:-cancun}
  setup_script=$(task_environment_value "$task_id" SCENARIO_SETUP_SCRIPT)
  target=$(task_environment_value "$task_id" SCENARIO_TARGET_ADDRESS)
  [[ -d "$scenario_dir" && -n "$setup_script" && -n "$target" ]]

  stop_anvil
  next_port=$((next_port + 1))
  rpc_url="http://127.0.0.1:$next_port"
  anvil --chain-id "$chain_id" --host 127.0.0.1 --port "$next_port" \
    --hardfork "$hardfork" --base-fee 0 --gas-price 0 --gas-limit 100000000 \
    --silent >"$smoke_root/anvil.log" 2>&1 &
  anvil_pid=$!

  current=""
  for _ in $(seq 1 120); do
    current=$(cast block-number --rpc-url "$rpc_url" 2>/dev/null || true)
    [[ "$current" == 0 ]] && break
    if ! kill -0 "$anvil_pid" 2>/dev/null; then
      echo "[smoke] local Anvil failed to start" >&2
      return 1
    fi
    sleep 0.25
  done
  [[ "$current" == 0 ]]

  forge script --root "$scenario_dir" "$scenario_dir/$setup_script" \
    --offline --broadcast --slow --rpc-url "$rpc_url"
  [[ "$(cast code "$target" --rpc-url "$rpc_url")" != 0x ]]
  validate_source_registry "$task_id" "$scenario_dir" "$chain_id" "$setup_script"
}

run_grade() {
  local task_id=$1 project_dir=$2
  local starting_value grade_timeout deployment grader passed_value
  starting_value=$(task_verifier_value "$task_id" GRADER_STARTING_VALUE)
  starting_value=${starting_value:-1ether}
  grade_timeout=${SMOKE_GRADE_TIMEOUT:-300}

  deployment=$(cd "$project_dir" && forge create src/ExploitGrader.sol:ExploitGrader \
    --offline --broadcast --rpc-url "$rpc_url" --private-key "$private_key" \
    --value "$starting_value" --gas-limit 100000000 \
    --legacy --gas-price 0 -vv)
  printf '%s\n' "$deployment"
  grader=$(printf '%s\n' "$deployment" | awk '/Deployed to:/ {print $3}' | tail -1)
  [[ "$grader" =~ ^0x[0-9a-fA-F]{40}$ ]]

  if ! cast send "$grader" 'grade()' --rpc-url "$rpc_url" \
    --private-key "$private_key" --gas-limit 100000000 --legacy --gas-price 0 \
    --timeout "$grade_timeout" >/dev/null; then
    passed_value=$(cast call "$grader" 'passed()(bool)' --rpc-url "$rpc_url" \
      2>/dev/null | awk '{print $1}')
    [[ "$passed_value" == true ]] && return 0
    echo "[smoke] grade transaction failed" >&2
    if [[ "${SMOKE_TRACE_ON_FAILURE:-1}" == 1 ]]; then
      cast call "$grader" 'grade()' \
        --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
        --rpc-url "$rpc_url" --gas-limit 100000000 --trace >&2 2>&1 || true
    fi
    return 1
  fi

  passed_value=$(cast call "$grader" 'passed()(bool)' --rpc-url "$rpc_url" | awk '{print $1}')
  [[ "$passed_value" == true ]] || {
    echo "[smoke] grader did not pass" >&2
    return 1
  }
}

run_one() {
  local task_id=$1 project_dir
  project_dir=$(prepare_project "$task_id")
  start_scenario "$task_id"
  run_grade "$task_id" "$project_dir"
  echo "[smoke] $task_id passed"
}

for task_id in "${tasks[@]}"; do
  if [[ "$requested" == all || "$requested" == "$task_id" ]]; then
    run_one "$task_id"
  fi
done

echo "[smoke] requested reference controls passed"
