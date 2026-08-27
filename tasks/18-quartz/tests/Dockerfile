FROM rl-exploits-18-quartz:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=18-quartz
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
