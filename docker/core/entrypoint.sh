#!/usr/bin/env bash
set -euo pipefail

if getent hosts pier-egress-proxy >/dev/null 2>&1; then
  agent_bin=/root/.local/bin/mini-swe-agent
  real_agent_bin=/root/.local/bin/mini-swe-agent.real
  if [[ -e "$agent_bin" && ! -e "$real_agent_bin" ]]; then
    mv "$agent_bin" "$real_agent_bin"
    ln -s /usr/local/bin/mini-swe-agent-wrapper "$agent_bin"
  fi
elif getent hosts pier-policy >/dev/null 2>&1; then
  # Harbor's local policy sidecar owns the task chain for control agents that
  # do not need the model egress proxy.
  :
elif [[ "${CHAIN_MODE:-local}" == local && -n "${SCENARIO_TARGET_ADDRESS:-}" ]]; then
  start-anvil
fi

exec "$@"
