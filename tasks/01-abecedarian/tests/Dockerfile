FROM rl-exploits-01-abecedarian:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=01-abecedarian
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
