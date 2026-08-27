FROM rl-exploits-22-umbra:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=22-umbra
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
