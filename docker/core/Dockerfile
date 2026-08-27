FROM ghcr.io/foundry-rs/foundry:v1.5.1@sha256:3a70bfa9bd2c732a767bb60d12c8770b40e8f9b6cca28efc4b12b1be81c7f28e

USER root
WORKDIR /app

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates jq python3 ripgrep \
    && groupadd --gid 10001 rltool \
    && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash rltool \
    && rm -rf /var/lib/apt/lists/*

COPY start-anvil.sh /usr/local/bin/start-anvil
COPY entrypoint.sh /usr/local/bin/task-entrypoint
COPY mini-swe-agent-wrapper.sh /usr/local/bin/mini-swe-agent-wrapper
COPY collect_artifact.py /usr/local/bin/collect-exploit-artifact
COPY policy_gateway.py /usr/local/lib/rl-task/policy_gateway.py
COPY rl_agent/ /opt/rl-agent/rl_agent/
COPY verifier.sh /usr/local/bin/verify-task
COPY project/ /opt/rl-foundry-project/

RUN forge build --root /opt/rl-foundry-project \
    && cp /root/.svm/0.8.28/solc-0.8.28 /usr/local/bin/solc-0.8.28 \
    && chmod 0755 /usr/local/bin/solc-0.8.28 \
    && rm -rf /root/.svm \
    && rm -rf /opt/rl-foundry-project/cache /opt/rl-foundry-project/out \
    && chmod +x /usr/local/bin/start-anvil /usr/local/bin/task-entrypoint \
    /usr/local/bin/mini-swe-agent-wrapper /usr/local/bin/collect-exploit-artifact \
    /usr/local/bin/verify-task

ENV RPC_URL=http://127.0.0.1:8545
ENV CHAIN_ID=1
ENV CHAIN_MODE=local
ENV ANVIL_HARDFORK=cancun
ENV FOUNDRY_SOLC=/usr/local/bin/solc-0.8.28
ENV RL_TOOL_UID=10001
ENV RL_TOOL_GID=10001
ENV RL_TOOL_HOME=/home/rltool

# The trusted controller starts as root so it can drop model-issued commands to
# rltool. Exploit research itself never runs as root.
ENTRYPOINT ["/usr/local/bin/task-entrypoint"]
CMD ["/bin/bash"]
