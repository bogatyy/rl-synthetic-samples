FROM rl-exploits-15-nimbus:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=15-nimbus
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
