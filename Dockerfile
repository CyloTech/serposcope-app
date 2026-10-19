FROM openjdk:8-jre-slim

ENV SERPOSCOPE_VERSION=2.13.0
ENV SERPOSCOPE_PORT=80
ENV ADMIN_EMAIL=test@test.com
ENV ADMIN_PASS=test123

# Install packages
RUN apt-get update && apt-get install -my \
    supervisor \
    net-tools \
    libcap2-bin \
    wget \
    curl \
    \
    && rm /etc/timezone \
    && echo "Europe/London" > /etc/timezone \
    && chmod 644 /etc/timezone \
    && dpkg-reconfigure -f noninteractive tzdata \
    \
	&& apt-get purge -y --auto-remove \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

RUN setcap cap_net_bind_service=+ep /usr/local/openjdk-8/bin/java

RUN wget https://serposcope.serphacker.com/download/${SERPOSCOPE_VERSION}/serposcope_${SERPOSCOPE_VERSION}_all.deb -O /tmp/serposcope.deb \
    && dpkg --force-confold -i /tmp/serposcope.deb \
    && rm /tmp/serposcope.deb

# Add configuration files
COPY supervisord.conf /etc/supervisor/conf.d/
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY serposcope /etc/default/serposcope

RUN chmod 755 /docker-entrypoint.sh

# Sends POST /v1/apps/installed/${INSTANCE_ID} for the entrypoint. It retries
# network errors, 408, 429 and 5xx and stops on any other status.
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod 755 /usr/local/bin/appbox-installed-callback

VOLUME /var/lib/serposcope/

RUN groupmod -g 9999 nogroup && \
    usermod -g 9999 nobody && \
    usermod -u 9999 nobody && \
    usermod -g 9999 sync && \
    usermod -g 9999 _apt

EXPOSE 80

# Clean up APT when done.
RUN apt autoremove -y
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]