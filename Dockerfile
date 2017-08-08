################################################################################
# Base image
################################################################################

FROM java:8-jre

################################################################################
# Build instructions
################################################################################

# Envronment variables
ENV SERPOSCOPE_VERSION=2.7.1

# Install packages
RUN apt-get update && apt-get install -my \
    supervisor \
    \
    && rm /etc/timezone \
    && echo "Europe/Paris" > /etc/timezone \
    && chmod 644 /etc/timezone \
    && dpkg-reconfigure -f noninteractive tzdata \
    \
	&& apt-get purge -y --auto-remove \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

RUN wget https://serposcope.serphacker.com/download/${SERPOSCOPE_VERSION}/serposcope_${SERPOSCOPE_VERSION}_all.deb -O /tmp/serposcope.deb \
    && dpkg --force-confold -i /tmp/serposcope.deb \
    && rm /tmp/serposcope.deb

# Add configuration files
COPY supervisord.conf /etc/supervisor/conf.d/
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY serposcope /etc/default/serposcope

RUN chmod 755 /docker-entrypoint.sh

################################################################################
# Volumes
################################################################################

VOLUME /var/lib/serposcope/

################################################################################
# Ports
################################################################################

EXPOSE 7134

################################################################################
# Entrypoint
################################################################################

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]