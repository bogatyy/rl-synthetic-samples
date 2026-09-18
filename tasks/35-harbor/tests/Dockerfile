FROM rl-exploits-35-harbor:latest
USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=35-harbor
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
