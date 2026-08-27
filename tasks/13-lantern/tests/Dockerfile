FROM rl-exploits-13-lantern:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=13-lantern
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
