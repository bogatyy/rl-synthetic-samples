FROM rl-exploits-31-dovetail:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=31-dovetail
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
