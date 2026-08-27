FROM rl-exploits-16-opal:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=16-opal
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
