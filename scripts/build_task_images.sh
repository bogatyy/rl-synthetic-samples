#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

tasks=("$@")
if (( ${#tasks[@]} == 0 )); then
  for task_file in "$repo_root"/tasks/*/task.toml; do
    [[ -f "$task_file" ]] || continue
    tasks+=("$(basename "$(dirname "$task_file")")")
  done
fi

echo "[images] rl-exploits-foundry-core:latest" >&2
docker build --quiet --tag rl-exploits-foundry-core:latest \
  "$repo_root/docker/core" >/dev/null

for task_id in "${tasks[@]}"; do
  task_dir="$repo_root/tasks/$task_id"
  [[ -f "$task_dir/task.toml" ]] || {
    echo "unknown task: $task_id" >&2
    exit 2
  }
  task_image=$(awk -F'"' '
    /^\[environment\]$/ { in_section=1; next }
    in_section && /^\[/ { exit }
    in_section && $1 ~ /^docker_image[[:space:]]*=[[:space:]]*$/ { print $2; exit }
  ' "$task_dir/task.toml")
  [[ -n "$task_image" ]] || {
    echo "task $task_id has no Docker image configured" >&2
    exit 1
  }
  echo "[images] $task_image" >&2
  docker build --quiet --tag "$task_image" "$task_dir/environment" >/dev/null
done
