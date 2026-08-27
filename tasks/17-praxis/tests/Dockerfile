FROM rl-exploits-17-praxis:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=17-praxis
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
