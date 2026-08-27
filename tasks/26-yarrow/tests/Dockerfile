FROM rl-exploits-26-yarrow:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=26-yarrow
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
