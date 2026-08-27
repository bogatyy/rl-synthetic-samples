FROM rl-exploits-24-willow:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=24-willow
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
