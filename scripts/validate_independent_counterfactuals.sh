#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
parallelism=${COUNTERFACTUAL_PARALLELISM:-4}
tasks=(
  12-kestrel 14-marrow 15-nimbus 16-opal
  17-praxis 18-quartz 21-talus
  23-verdant 24-willow 25-xenon
  29-bracken 30-cinder
)

[[ "$parallelism" =~ ^[1-9][0-9]*$ ]] || {
  echo "COUNTERFACTUAL_PARALLELISM must be a positive integer" >&2
  exit 2
}

# Counterfactual checks can be run independently of the runtime suite, so make
# their task images current here as well. Isolated worktrees may opt out when
# another checkout owns the shared tags.
if [[ ${SKIP_IMAGE_BUILD:-0} != 1 ]]; then
  "$repo_root/scripts/build_task_images.sh" "${tasks[@]}"
fi

validation_root=$(mktemp -d /tmp/rl-independent-counterfactual.XXXXXX)
cleanup() {
  case "$validation_root" in
    /tmp/rl-independent-counterfactual.*) rm -rf -- "$validation_root" ;;
  esac
}
trap cleanup EXIT

run_one() {
  local task=$1
  local ordinal=${task%%-*}
  local log="$validation_root/$task.log"
  if SYNTHETIC_COUNTERFACTUAL_TASK="$task" \
    SYNTHETIC_COUNTERFACTUAL_PORT_BASE="$((30000 + 10#$ordinal * 100))" \
    python3 "$repo_root/scripts/test_synthetic_counterfactuals.py" \
    >"$log" 2>&1; then
    echo "[counterfactual] $task root fix rejected the reference"
  else
    cat "$log" >&2
    return 1
  fi
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
  echo "[counterfactual] one or more controls failed" >&2
  exit 1
fi
echo "[counterfactual] all ${#tasks[@]} independent root fixes rejected their references"
