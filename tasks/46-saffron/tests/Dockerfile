FROM rl-exploits-46-saffron:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=46-saffron
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
