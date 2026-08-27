#!/usr/bin/env bash
set -euo pipefail

# LiteLLM bundles this metadata; loading the runner must not fetch a pricing
# file from the internet.
export LITELLM_LOCAL_MODEL_COST_MAP=True

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_id=01-abecedarian

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

source_env_file() {
  local env_file=$1
  if [[ $- == *x* ]]; then
    set +x
    source "$env_file"
  else
    source "$env_file"
  fi
}

if [[ "${1:-}" == --list ]]; then
  printf '%s\n' "${tasks[@]}"
  exit 0
fi

if [[ "${1:-}" == --smoke ]]; then
  shift
  exec "$repo_root/scripts/smoke_test.sh" "${1:-all}"
fi

if [[ "${1:-}" == --task ]]; then
  [[ -n "${2:-}" ]] || { echo "--task requires a task ID" >&2; exit 2; }
  task_id=$2
  shift 2
fi

if ! is_task "$task_id"; then
  echo "unknown task: $task_id" >&2
  echo "use --list to show task IDs" >&2
  exit 2
fi

if [[ -f "$repo_root/.env" ]]; then
  source_env_file "$repo_root/.env"
fi

task_path="$repo_root/tasks/$task_id"
chain=$(awk -F'"' '/^chain = / { print $2; exit }' "$task_path/task.toml")
[[ "$chain" == local ]] || {
  echo "$task_id is not a local-chain task" >&2
  exit 2
}

# This repository is local-only. Discard historical-chain credentials even if
# the caller's shell happens to contain them.
for variable in \
  ALCHEMY_API_KEY ETHERSCAN_API_KEY RL_TASK_ARCHIVE_RPC \
  RL_TASK_POLICY_ARCHIVE_RPC RL_TASK_POLICY_ETHERSCAN_API_KEY \
  ETH_RPC_URL BSC_RPC_URL ARBITRUM_RPC_URL BASE_RPC_URL POLYGON_RPC_URL \
  AVALANCHE_RPC_URL OPTIMISM_RPC_URL LINEA_RPC_URL BLAST_RPC_URL \
  GNOSIS_RPC_URL MANTLE_RPC_URL SEI_RPC_URL; do
  unset "$variable"
done

docker build --tag rl-exploits-foundry-core:latest "$repo_root/docker/core"
docker build --tag "rl-exploits-${task_id}:latest" "$task_path/environment"

if ! command -v pier >/dev/null 2>&1; then
  echo "runner requires pier for isolated agent networking; use --smoke for local verification" >&2
  exit 127
fi

cli_args=("$@")
pier_args=("$@")
agent_name=""
model_name=""
has_agent_version=0
for ((i = 0; i < ${#cli_args[@]}; i++)); do
  case "${cli_args[$i]}" in
    --agent|-a)
      ((i + 1 < ${#cli_args[@]})) && agent_name=${cli_args[$((i + 1))]}
      ;;
    --agent=*|-a=*) agent_name=${cli_args[$i]#*=} ;;
    --model|-m)
      ((i + 1 < ${#cli_args[@]})) && model_name=${cli_args[$((i + 1))]}
      ;;
    --model=*|-m=*) model_name=${cli_args[$i]#*=} ;;
    --ak|--agent-kwarg)
      if ((i + 1 < ${#cli_args[@]})) && [[ "${cli_args[$((i + 1))]}" == version=* ]]; then
        has_agent_version=1
      fi
      ;;
    --ak=version=*|--agent-kwarg=version=*) has_agent_version=1 ;;
  esac
done

if [[ -n "$agent_name" && "$agent_name" != mini-swe-agent \
    && "$agent_name" != oracle && "$agent_name" != nop ]]; then
  echo "runner supports mini-swe-agent plus oracle and no-op controls" >&2
  exit 2
fi

if [[ "$agent_name" == mini-swe-agent ]]; then
  if (( ! has_agent_version )); then
    pier_args+=(--agent-kwarg version=2.4.6)
  fi
  if [[ "$model_name" == deepseek/* || "$model_name" == deepseek-* ]]; then
    : "${DEEPSEEK_API_KEY:?set DEEPSEEK_API_KEY for direct DeepSeek inference}"
    export DEEPSEEK_API_KEY
  elif [[ "$model_name" == openrouter/* ]]; then
    : "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY for OpenRouter inference}"
    export OPENROUTER_API_KEY
  elif [[ "$model_name" == openai/* ]]; then
    : "${OPENAI_API_KEY:?set OPENAI_API_KEY for direct OpenAI inference}"
    export OPENAI_API_KEY
  fi
fi

export PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}"
exec pier run -p "$task_path" \
  --environment-import-path runner.local_environment:LocalTaskDockerEnvironment \
  "${pier_args[@]}"
