#!/usr/bin/env bash
set -uo pipefail

artifact=/logs/artifacts/Exploit.sol
verifier_dir=/logs/verifier
run_log=$verifier_dir/run.log
task_id=${TASK_ID:?TASK_ID is required}
pid_file=/tmp/rl-task-anvil.pid

mkdir -p "$verifier_dir"
: > "$run_log"

result() {
  local reward=$1 message=$2 status=failed passed=0
  if [[ "$reward" == 1 ]]; then status=passed; passed=1; fi
  printf '{"reward":%s}\n' "$reward" > "$verifier_dir/reward.json"
  printf '{"reportFormat":"CTRF","specVersion":"1.0.0","results":{"tool":{"name":"forge"},"summary":{"tests":1,"passed":%s,"failed":%s,"skipped":0},"tests":[{"name":"%s","status":"%s","message":"%s"}]}}\n' \
    "$passed" "$((1-passed))" "$task_id" "$status" "$message" > "$verifier_dir/ctrf.json"
}

cleanup() {
  if [[ -f "$pid_file" ]]; then
    pid=$(<"$pid_file")
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  [[ -f "$verifier_dir/reward.json" ]] || result 0 "verifier crashed"
  cp "$run_log" "$verifier_dir/test-stdout.txt" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -f "$artifact" || -L "$artifact" ]] || (( $(wc -c < "$artifact") > 131072 )); then
  result 0 "missing or invalid Exploit.sol"
  exit 0
fi

cp "$artifact" /app/src/Exploit.sol
cp /tests/ExploitGrader.sol /app/src/ExploitGrader.sol

if ! (cd /app && forge build --offline) 2>&1 | tee -a "$run_log"; then
  result 0 "submission did not compile"
  exit 0
fi

run_grade() {
  local private_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  local deployment deploy_status grader send_output send_status passed
  start-anvil --restart 2>&1 | tee -a "$run_log" || return 1

  deployment=$(cd /app && forge create src/ExploitGrader.sol:ExploitGrader \
    --offline --broadcast --rpc-url "$RPC_URL" --private-key "$private_key" \
    --value "${GRADER_STARTING_VALUE:-1ether}" --gas-limit 100000000 \
    --legacy --gas-price 0 -vv 2>&1)
  deploy_status=$?
  printf '%s\n' "$deployment" | tee -a "$run_log"
  (( deploy_status == 0 )) || return 1

  grader=$(printf '%s\n' "$deployment" | awk '/Deployed to:/ {print $3}' | tail -1)
  [[ "$grader" =~ ^0x[0-9a-fA-F]{40}$ ]] || return 1

  send_output=$(cast send "$grader" 'grade()' --rpc-url "$RPC_URL" --private-key "$private_key" \
    --gas-limit 100000000 --legacy --gas-price 0 2>&1)
  send_status=$?
  printf '%s\n' "$send_output" | tee -a "$run_log"
  (( send_status == 0 )) || return 1

  passed=$(cast call "$grader" 'passed()(bool)' --rpc-url "$RPC_URL" | awk '{print $1}')
  [[ "$passed" == true ]]
}

passed=0
run_grade && passed=1

if (( passed )); then
  result 1 "target state change verified"
else
  result 0 "Solidity grader reverted"
fi

echo "[verifier] $(<"$verifier_dir/reward.json")"
exit 0
