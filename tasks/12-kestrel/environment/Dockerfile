FROM rl-exploits-foundry-core:latest

RUN cp -R /opt/rl-foundry-project/. /app/
COPY --chown=rltool:rltool project/ /app/
COPY scenario/ /opt/scenario/
RUN forge build --root /opt/scenario --offline     && forge build --offline     && rm -rf /app/cache /app/out /opt/scenario/cache /opt/scenario/out /opt/scenario/broadcast     && chown -R rltool:rltool /app /opt/scenario

ENV TASK_ID=12-kestrel
ENV CHAIN_MODE=local
ENV CHAIN_ID=1
ENV ANVIL_HARDFORK=cancun
ENV SCENARIO_SETUP_SCRIPT=script/Setup.s.sol:Setup
ENV SCENARIO_TARGET_ADDRESS=0x68B1D87F95878fE05B998F19b66F4baba5De1aed
ENV SCENARIO_SOURCE_REGISTRY=/opt/scenario/source-registry.json
