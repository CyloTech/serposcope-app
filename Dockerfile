FROM java:8-jre

ENV SERPOSCOPE_VERSION=2.9.0
ENV SERPOSCOPE_PORT=80
ENV ADMIN_EMAIL=test@test.com
ENV ADMIN_PASS=test123

# Install packages
RUN apt-get update && apt-get install -my \
    supervisor \
    net-tools \
    \
    && rm /etc/timezone \
    && echo "Europe/London" > /etc/timezone \
    && chmod 644 /etc/timezone \
    && dpkg-reconfigure -f noninteractive tzdata \
    \
	&& apt-get purge -y --auto-remove \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

RUN setcap cap_net_bind_service=+ep /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java

RUN wget https://serposcope.serphacker.com/download/${SERPOSCOPE_VERSION}/serposcope_${SERPOSCOPE_VERSION}_all.deb -O /tmp/serposcope.deb \
    && dpkg --force-confold -i /tmp/serposcope.deb \
    && rm /tmp/serposcope.deb

# Add configuration files
COPY supervisord.conf /etc/supervisor/conf.d/
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY serposcope /etc/default/serposcope

RUN chmod 755 /docker-entrypoint.sh

VOLUME /var/lib/serposcope/

EXPOSE 80

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]