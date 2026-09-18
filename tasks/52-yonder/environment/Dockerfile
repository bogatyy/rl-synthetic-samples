ARG CORE_IMAGE=rl-exploits-foundry-core:latest
FROM ${CORE_IMAGE}

RUN cp -R /opt/rl-foundry-project/. /app/
COPY --chown=rltool:rltool project/ /app/
COPY scenario/ /opt/scenario/
RUN env -u FOUNDRY_SOLC forge build --root /opt/scenario \
    && install -m 0755 /root/.svm/0.8.28/solc-0.8.28 /usr/local/bin/solc-0.8.28 \
    && forge build --offline \
    && rm -rf /root/.svm /app/cache /app/out /opt/scenario/cache /opt/scenario/out /opt/scenario/broadcast \
    && chown -R rltool:rltool /app /opt/scenario

ENV TASK_ID=52-yonder
ENV CHAIN_MODE=local
ENV CHAIN_ID=56
ENV ANVIL_HARDFORK=cancun
ENV SCENARIO_SETUP_SCRIPT=script/Setup.s.sol:Setup
ENV SCENARIO_SOLC=/usr/local/bin/solc-0.8.28
ENV SCENARIO_TARGET_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3
ENV SCENARIO_SOURCE_REGISTRY=/opt/scenario/source-registry.json
ENV LOCAL_SOURCE_COMPILER_VERSION=v0.8.28+commit.7893614a
ENV LOCAL_SOURCE_OPTIMIZATION_USED=1
ENV LOCAL_SOURCE_OPTIMIZER_RUNS=200
ENV LOCAL_SOURCE_EVM_VERSION=cancun
ENV LOCAL_SOURCE_LICENSE_TYPE=MIT
