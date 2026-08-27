FROM rl-exploits-14-marrow:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=14-marrow
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
