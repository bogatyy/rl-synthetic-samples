FROM rl-exploits-foundry-core:latest

COPY --chmod=0755 start-anvil.sh /usr/local/bin/start-anvil
RUN cp -R /opt/rl-foundry-project/. /app/
COPY --chown=rltool:rltool project/ /app/
COPY scenario/ /opt/scenario/
RUN forge build --root /opt/scenario --offline \
    && forge build --offline \
    && rm -rf /app/cache /app/out /opt/scenario/cache /opt/scenario/out /opt/scenario/broadcast \
    && chown -R rltool:rltool /app /opt/scenario

ENV TASK_ID=41-nacre
ENV CHAIN_MODE=local
ENV CHAIN_ID=1
ENV ANVIL_HARDFORK=cancun
ENV SCENARIO_SETUP_SCRIPT=script/Setup.s.sol:Setup
ENV SCENARIO_TARGET_ADDRESS=0x10C6E9530F1C1AF873a391030a1D9E8ed0630D26
ENV SCENARIO_SOURCE_REGISTRY=/opt/scenario/source-registry.json
