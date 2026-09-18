FROM rl-exploits-119-org-riven:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=119-org-riven
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
