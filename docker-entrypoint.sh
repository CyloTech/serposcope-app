#!/bin/bash
set -x

if [ ! -f /etc/app_configured ]; then

    EMAIL_ENC=`sed "s/@/%40/g" <<<"$ADMIN_EMAIL"`

    conf_file="/etc/serposcope.conf"

    usermod -u 1000 serposcope
    groupmod -g 50 staff

    usermod -g 50 serposcope

    chown -R serposcope:staff /var/lib/serposcope
    chown -R serposcope:staff /var/log/serposcope

    function replace_param {
      sed -i -r -e "/^# *${1}=/ {s|^# *||;s|=.*$|=|;s|$|$(eval echo \$$2)|}" $conf_file
    }

    if [ -n "$SERPOSCOPE_DB_URL" ]
    then
      replace_param "serposcope.db.url" "SERPOSCOPE_DB_URL"
    else
      echo "SERPOSCOPE_DB_URL is not set, keeping the default value"
    fi

    if [ -n "$SERPOSCOPE_DB_OPTIONS" ]
    then
      replace_param  "serposcope.db.options" "SERPOSCOPE_DB_OPTIONS"
    else
      echo "SERPOSCOPE_DB_OPTIONS not set, keeping the default value"
    fi

    if [ -n "$SERPOSCOPE_DB_DEBUG" ]
    then
    replace_param  "serposcope.db.debug" "SERPOSCOPE_DB_DEBUG"
    else
      echo "SERPOSCOPE_DB_DEBUG not set, keeping the default value"
    fi

    if [ -n "$SERPOSCOPE_PORT" ]
    then
      replace_param "serposcope.listenPort" "SERPOSCOPE_PORT"
    else
      echo "SERPOSCOPE_PORT is not set, keeping the default value"
    fi

    service serposcope start

    sleep 5
    DATA_STR="email=${ADMIN_EMAIL}&email-confirm=${ADMIN_EMAIL}&password=${ADMIN_PASS}&password-confirm=${ADMIN_PASS}"
    curl -v 'http://127.0.0.1/create-admin' --data ${DATA_STR} --compressed &> /var/log/serpuser.log

    # Finish App install: mark the installed callback pending (before the
    # configured marker, so a crash in between cannot lose it). It is sent in
    # the background below.
    touch /etc/appbox_callback_pending
    touch /etc/app_configured

else
    service serposcope start
fi

# Send a pending installed callback in the background. The helper retries
# network errors, 408, 429 and 5xx and stops on any other status (e.g. 401
# once the token was used or cleared) instead of retrying forever.
if [ -f /etc/appbox_callback_pending ]; then
    (
        set +e
        /usr/local/bin/appbox-installed-callback
        rm -f /etc/appbox_callback_pending
    ) </dev/null &
fi

tail -F /var/log/serposcope/startup.log