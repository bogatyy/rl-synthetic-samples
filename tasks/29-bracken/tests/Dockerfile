FROM rl-exploits-29-bracken:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=29-bracken
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
