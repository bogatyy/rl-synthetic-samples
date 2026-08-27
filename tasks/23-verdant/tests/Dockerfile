FROM rl-exploits-23-verdant:latest

USER root
COPY test.sh /tests/test.sh
COPY ExploitGrader.sol /tests/ExploitGrader.sol
RUN chmod +x /tests/test.sh
ENV TASK_ID=23-verdant
USER rltool
ENTRYPOINT []
CMD ["/tests/test.sh"]
