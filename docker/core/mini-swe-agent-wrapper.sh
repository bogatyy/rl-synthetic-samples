#!/usr/bin/env bash
set -euo pipefail

# LiteLLM bundles this metadata. Avoid an unrelated GitHub fetch at startup;
# model inference still goes directly to DeepSeek or OpenRouter.
export LITELLM_LOCAL_MODEL_COST_MAP=True

if ! cast block-number --rpc-url "${RPC_URL:-http://127.0.0.1:8545}" >/dev/null 2>&1; then
  start-anvil
fi

model_name=""
has_model_class=0
has_environment_class=0
openrouter_model=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --model|-m)
      ((i + 1 < ${#args[@]})) && model_name=${args[$((i + 1))]}
      ;;
    --model=*) model_name=${args[$i]#*=} ;;
    --model-class)
      has_model_class=1
      ((i + 1 < ${#args[@]})) && ((i += 1))
      ;;
    --model-class=*) has_model_class=1 ;;
    model.model_class=openrouter|-c=model.model_class=openrouter)
      openrouter_model=1
      ;;
    --environment-class)
      has_environment_class=1
      ((i + 1 < ${#args[@]})) && ((i += 1))
      ;;
    --environment-class=*) has_environment_class=1 ;;
  esac
done

export PYTHONPATH="/opt/rl-agent${PYTHONPATH:+:$PYTHONPATH}"

if ((has_environment_class)); then
  echo "[task] refusing a custom mini-swe environment class: tool credential isolation is mandatory" >&2
  exit 2
fi
args+=(--environment-class rl_agent.secure_environment.SecureLocalEnvironment)

if [[ "$model_name" == deepseek/* || "$model_name" == deepseek-* ]]; then
  if ((has_model_class)); then
    echo "[task] refusing a custom model class for DeepSeek: reasoning-content preservation is mandatory" >&2
    exit 2
  fi
  args+=(--model-class rl_agent.deepseek_model.DeepSeekReasoningModel)
fi

if ((openrouter_model)); then
  if ((has_model_class)); then
    echo "[task] refusing a custom model class for OpenRouter: reasoning preservation and provider retries are mandatory" >&2
    exit 2
  fi
  args+=(--model-class rl_agent.openrouter_model.OpenRouterReasoningModel)
fi

exec /root/.local/bin/mini-swe-agent.real "${args[@]}"
