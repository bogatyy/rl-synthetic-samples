FROM rl-exploits-45-rowan:latest
USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=45-rowan
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
