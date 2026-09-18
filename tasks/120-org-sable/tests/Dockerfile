FROM rl-exploits-120-org-sable:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=120-org-sable
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
