FROM rl-exploits-27-zephyr:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=27-zephyr
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
