FROM rl-exploits-foundry-core:latest

RUN cp -R /opt/rl-foundry-project/. /app/
COPY --chown=rltool:rltool project/ /app/
COPY scenario/ /opt/scenario/
RUN env -u FOUNDRY_SOLC forge build --root /opt/scenario \
    && install -m 0755 /root/.svm/0.7.1/solc-0.7.1 /usr/local/bin/solc-0.7.1 \
    && forge build --offline \
    && rm -rf /root/.svm /app/cache /app/out /opt/scenario/cache /opt/scenario/out /opt/scenario/broadcast \
    && chown -R rltool:rltool /app /opt/scenario

ENV TASK_ID=119-org-riven
ENV CHAIN_MODE=local
ENV CHAIN_ID=1
ENV ANVIL_HARDFORK=cancun
ENV SCENARIO_SETUP_SCRIPT=script/Setup.s.sol:Setup
ENV SCENARIO_SOLC=/usr/local/bin/solc-0.7.1
ENV SCENARIO_TARGET_ADDRESS=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
ENV SCENARIO_SOURCE_REGISTRY=/opt/scenario/source-registry.json
ENV LOCAL_SOURCE_COMPILER_VERSION=v0.7.1+commit.f4a555be
ENV LOCAL_SOURCE_OPTIMIZATION_USED=1
ENV LOCAL_SOURCE_OPTIMIZER_RUNS=800
ENV LOCAL_SOURCE_EVM_VERSION=istanbul
ENV LOCAL_SOURCE_LICENSE_TYPE=GPL-3.0-or-later
