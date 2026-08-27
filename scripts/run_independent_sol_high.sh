#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
parallelism=${EVAL_PARALLELISM:-6}

default_tasks=(
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

if (( $# )); then
  tasks=("$@")
else
  tasks=("${default_tasks[@]}")
fi

[[ "$parallelism" =~ ^[1-9][0-9]*$ ]] || {
  echo "EVAL_PARALLELISM must be a positive integer" >&2
  exit 2
}

matrix_root=$(mktemp -d /tmp/rl-sol-high.XXXXXX)
cleanup() {
  case "$matrix_root" in
    /tmp/rl-sol-high.*) rm -rf -- "$matrix_root" ;;
  esac
}
trap cleanup EXIT

run_one() {
  local task=$1
  local job_name="${task}-gpt56sol-high"
  local log="$matrix_root/$task.log"

  if [[ -e "$repo_root/runs/$job_name" ]]; then
    echo "refusing to overwrite existing run: runs/$job_name" >&2
    return 2
  fi

  if "$repo_root/runner/run.sh" \
    --task "$task" \
    --agent mini-swe-agent \
    --model openai/gpt-5.6-sol \
    --agent-kwarg reasoning_effort=high \
    --agent-kwarg cost_limit=20 \
    --agent-kwarg "config_file=$repo_root/runner/mini-swe-one-hour.yaml" \
    --agent-kwarg 'extra_python_packages=["litellm==1.95.0"]' \
    --job-name "$job_name" \
    --jobs-dir "$repo_root/runs" \
    --n-concurrent 1 \
    --quiet \
    --yes \
    --cpus ignore \
    --memory ignore \
    >"$log" 2>&1; then
    echo "[sol-high] $task finished"
  else
    echo "[sol-high] $task runner failed" >&2
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
    for pid in "${pids[@]}"; do
      wait "$pid" || failed=1
    done
    pids=()
  fi
done

if (( ${#pids[@]} != 0 )); then
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
fi

(( failed == 0 ))
