FROM rl-exploits-20-sable:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=20-sable
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
