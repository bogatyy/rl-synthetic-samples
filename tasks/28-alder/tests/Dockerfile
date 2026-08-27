FROM rl-exploits-28-alder:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=28-alder
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
