# Serposcope 2.13.0 on openjdk:8-jre-slim (Debian 10).
#
# The original recipe (see this file's git history) can no longer be rebuilt:
# serposcope.serphacker.com answers 404 for the 2.13.0 package and Debian 10
# has left the main package mirrors. Releases therefore start from the
# published image that catalogue version 2.12.0 runs (it already contains
# Serposcope 2.13.0) and replace only the Appbox start-up files.
FROM repo.cylo.net/serposcope@sha256:b23931c7f39a8d046205780d919f6a4cdd81f5efa99e6dce7e8a3d117ff313ae

# Appbox supplies ADMIN_EMAIL and ADMIN_PASS when the app is installed. The
# base image set a default administrator (test@test.com); clear it so that a
# missing value stops the installation instead of creating that account.
ENV ADMIN_EMAIL="" \
    ADMIN_PASS=""

# Add configuration files
COPY supervisord.conf /etc/supervisor/conf.d/
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY serposcope /etc/default/serposcope

# Sends POST /v1/apps/installed/${INSTANCE_ID} for the entrypoint. It retries
# network errors, 408, 429 and 5xx and stops on any other status.
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback

RUN chmod 755 /docker-entrypoint.sh /usr/local/bin/appbox-installed-callback
