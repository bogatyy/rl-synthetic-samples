FROM rl-exploits-foundry-core:latest

RUN cp -R /opt/rl-foundry-project/. /app/
COPY --chown=rltool:rltool project/ /app/
COPY scenario/ /opt/scenario/
RUN forge build --root /opt/scenario --offline     && forge build --offline     && rm -rf /app/cache /app/out /opt/scenario/cache /opt/scenario/out /opt/scenario/broadcast     && chown -R rltool:rltool /app /opt/scenario

ENV TASK_ID=34-garnet
ENV CHAIN_MODE=local
ENV CHAIN_ID=56
ENV ANVIL_HARDFORK=cancun
ENV SCENARIO_SETUP_SCRIPT=script/Setup.s.sol:Setup
ENV SCENARIO_TARGET_ADDRESS=0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6
ENV SCENARIO_SOURCE_REGISTRY=/opt/scenario/source-registry.json
