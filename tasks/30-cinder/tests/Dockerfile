FROM rl-exploits-30-cinder:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=30-cinder
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
