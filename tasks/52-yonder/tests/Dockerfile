FROM rl-exploits-52-yonder:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=52-yonder
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
