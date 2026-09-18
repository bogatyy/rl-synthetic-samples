FROM rl-exploits-41-nacre:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=41-nacre
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
