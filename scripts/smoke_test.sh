#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
requested=${1:-all}
exploit_override=${SMOKE_EXPLOIT_PATH:-}
next_port=${SMOKE_PORT_BASE:-$((20000 + ($$ % 30000)))}
rpc_url=""
private_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
anvil_container=""
anvil_log=""
core_image_ready=0
ensured_task_image=""

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

task_docker_image() {
  local task_id=$1
  awk -F'"' '
    /^\[environment\]$/ { in_section=1; next }
    in_section && /^\[/ { exit }
    in_section && $1 ~ /^docker_image[[:space:]]*=[[:space:]]*$/ { print $2; exit }
  ' "$repo_root/tasks/$task_id/task.toml"
}

smoke_root=$(mktemp -d /tmp/rl-synthetic-smoke.XXXXXX)

stop_anvil() {
  if [[ -n "$anvil_container" ]]; then
    if [[ -n "$anvil_log" ]]; then
      docker logs "$anvil_container" >"$anvil_log" 2>&1 || true
    fi
    docker rm --force "$anvil_container" >/dev/null 2>&1 || true
    anvil_container=""
    anvil_log=""
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

ensure_task_image() {
  local task_id=$1 task_image
  local core_image=rl-exploits-foundry-core:latest
  task_image=$(task_docker_image "$task_id")
  [[ -n "$task_image" ]] || {
    echo "[smoke] task $task_id has no Docker image configured" >&2
    return 1
  }

  if (( core_image_ready == 0 )); then
    if [[ "${SMOKE_REBUILD_IMAGES:-0}" == 1 ]] \
      || ! docker image inspect "$core_image" >/dev/null 2>&1; then
      echo "[smoke] building $core_image" >&2
      docker build --tag "$core_image" "$repo_root/docker/core"
    fi
    core_image_ready=1
  fi

  if [[ "${SMOKE_REBUILD_IMAGES:-0}" == 1 ]] \
    || ! docker image inspect "$task_image" >/dev/null 2>&1; then
    echo "[smoke] building $task_image" >&2
    docker build --tag "$task_image" "$repo_root/tasks/$task_id/environment"
  fi
  ensured_task_image=$task_image
}

validate_source_registry() {
  local task_id=$1 scenario_dir=$2 chain_id=$3 setup_script=$4
  local registry="$scenario_dir/source-registry.json"
  local script_file=${setup_script%%:*}
  local broadcast_dir="$scenario_dir/broadcast/$(basename "$script_file")/$chain_id"
  [[ -f "$registry" && -d "$broadcast_dir" ]] || {
    echo "[smoke] missing source registry or setup broadcast for $task_id" >&2
    return 1
  }

  python3 - "$registry" "$broadcast_dir" <<'PY'
import json
import pathlib
import sys

registry_path = pathlib.Path(sys.argv[1])
broadcast_dir = pathlib.Path(sys.argv[2])
registry = {
    address.lower(): entry
    for address, entry in json.loads(registry_path.read_text()).items()
}
broadcasts = []
for path in broadcast_dir.rglob("*.json"):
    document = json.loads(path.read_text())
    if isinstance(document, dict) and isinstance(document.get("transactions"), list):
        broadcasts.append(document)
assert broadcasts, f"no setup broadcasts under {broadcast_dir}"
creates = [
    tx
    for document in broadcasts
    for tx in document["transactions"]
    if tx.get("transactionType") == "CREATE"
]
deployed = {tx["contractAddress"].lower(): tx["contractName"] for tx in creates}

wrong = sorted(
    address
    for address in set(deployed) & set(registry)
    # Foundry cannot assign an artifact name when a constructor deliberately
    # returns an exact historical runtime rather than its own compiled runtime.
    # The registry's source/name shape is validated separately.
    if deployed[address] is not None and deployed[address] != registry[address]["name"]
)
if wrong:
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
  local scenario_source scenario_dir task_image host_uid host_gid
  local setup_script target current code start_timeout deadline
  if [[ -n "${SMOKE_SCENARIO_PATH:-}" ]]; then
    scenario_source=$SMOKE_SCENARIO_PATH
  else
    scenario_source="$task_dir/environment/scenario"
  fi
  scenario_dir="$smoke_root/$task_id-scenario"
  [[ -d "$scenario_source" ]]
  cp -R "$scenario_source" "$scenario_dir"
  rm -rf -- "$scenario_dir/broadcast"
  mkdir -p "$scenario_dir/broadcast"

  setup_script=$(task_environment_value "$task_id" SCENARIO_SETUP_SCRIPT)
  target=$(task_environment_value "$task_id" SCENARIO_TARGET_ADDRESS)
  [[ -d "$scenario_dir" && -n "$setup_script" && -n "$target" ]]
  ensure_task_image "$task_id"
  task_image=$ensured_task_image

  stop_anvil
  next_port=$((next_port + 1))
  rpc_url="http://127.0.0.1:$next_port"
  anvil_log="$smoke_root/$task_id-anvil.log"
  host_uid=$(id -u)
  host_gid=$(id -g)

  # Anvil listens on all interfaces only inside its disposable container.
  # Docker publishes it exclusively on the host loopback interface, so the
  # unlocked development accounts are never reachable from the LAN. Overlay
  # the selected scenario onto the image rather than hiding /opt/scenario:
  # some tasks intentionally bundle compiler-generated deployment bytecode.
  anvil_container=$(docker run --detach \
    --publish "127.0.0.1:$next_port:8545" \
    --env ANVIL_HOST=0.0.0.0 \
    --env HOME=/tmp \
    --env "HOST_UID=$host_uid" \
    --env "HOST_GID=$host_gid" \
    --volume "$scenario_dir:/scenario-input:ro" \
    --volume "$scenario_dir/broadcast:/scenario-output" \
    --entrypoint /bin/bash "$task_image" \
    -lc 'cp -a /scenario-input/. /opt/scenario/ \
      && start-anvil \
      && cp -a /opt/scenario/broadcast/. /scenario-output/ \
      && chown -R "$HOST_UID:$HOST_GID" /scenario-output \
      && exec tail -f /dev/null')

  start_timeout=${SMOKE_START_TIMEOUT:-600}
  [[ "$start_timeout" =~ ^[1-9][0-9]*$ ]] || {
    echo "SMOKE_START_TIMEOUT must be a positive integer" >&2
    return 2
  }
  deadline=$((SECONDS + start_timeout))
  current=""
  code=""
  while (( SECONDS < deadline )); do
    if ! docker inspect --format '{{.State.Running}}' "$anvil_container" \
      2>/dev/null | grep -qx true; then
      echo "[smoke] local scenario container exited during setup" >&2
      docker logs "$anvil_container" >&2 2>&1 || true
      return 1
    fi
    if docker exec "$anvil_container" test -f /tmp/rl-task-scenario.ready \
      >/dev/null 2>&1; then
      # Query from inside the container. Besides avoiding host proxy and
      # networking configuration, this proves the same local endpoint used by
      # the task process is serving the initialized scenario.
      current=$(docker exec "$anvil_container" cast block-number \
        --rpc-url http://127.0.0.1:8545 2>/dev/null || true)
      code=$(docker exec "$anvil_container" cast code "$target" \
        --rpc-url http://127.0.0.1:8545 2>/dev/null || true)
      [[ -n "$current" && "$code" != 0x && -n "$code" ]] && break
    fi
    sleep 0.25
  done
  if [[ -z "$current" || -z "$code" || "$code" == 0x ]]; then
    echo "[smoke] local scenario did not become ready within ${start_timeout}s" >&2
    docker logs "$anvil_container" >&2 2>&1 || true
    return 1
  fi

  local chain_id
  chain_id=$(task_environment_value "$task_id" CHAIN_ID)
  chain_id=${chain_id:-1}
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
    cast call "$grader" 'grade()' \
      --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
      --rpc-url "$rpc_url" --gas-limit 100000000 >&2 2>&1 || true
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
    cast call "$grader" 'grade()' \
      --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
      --rpc-url "$rpc_url" --gas-limit 100000000 >&2 2>&1 || true
    if [[ "${SMOKE_TRACE_ON_FAILURE:-1}" == 1 ]]; then
      cast call "$grader" 'grade()' \
        --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
        --rpc-url "$rpc_url" --gas-limit 100000000 --trace >&2 2>&1 || true
    fi
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
