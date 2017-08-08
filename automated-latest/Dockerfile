FROM java:8-jre

COPY entrypoint.sh /entrypoint.sh

RUN chmod 700 /entrypoint.sh

VOLUME /var/lib/serposcope/

EXPOSE 7134

ENTRYPOINT ["/entrypoint.sh"]