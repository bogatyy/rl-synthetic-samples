FROM rl-exploits-foundry-core:latest

RUN cp -R /opt/rl-foundry-project/. /app/
COPY --chown=rltool:rltool project/ /app/
COPY scenario/ /opt/scenario/
RUN forge build --root /opt/scenario --offline     && forge build --offline     && rm -rf /app/cache /app/out /opt/scenario/cache /opt/scenario/out /opt/scenario/broadcast     && chown -R rltool:rltool /app /opt/scenario

ENV TASK_ID=24-willow
ENV CHAIN_MODE=local
ENV CHAIN_ID=1
ENV ANVIL_HARDFORK=cancun
ENV SCENARIO_SETUP_SCRIPT=script/Setup.s.sol:Setup
ENV SCENARIO_TARGET_ADDRESS=0xa513E6E4b8f2a923D98304ec87F64353C4D5C853
ENV SCENARIO_SOURCE_REGISTRY=/opt/scenario/source-registry.json
