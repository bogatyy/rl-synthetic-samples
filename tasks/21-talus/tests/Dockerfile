FROM rl-exploits-21-talus:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=21-talus
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
