FROM rl-exploits-34-garnet:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=34-garnet
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
