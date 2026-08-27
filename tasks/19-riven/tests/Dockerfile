FROM rl-exploits-19-riven:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=19-riven
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
