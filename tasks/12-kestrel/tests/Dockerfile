FROM rl-exploits-12-kestrel:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=12-kestrel
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
