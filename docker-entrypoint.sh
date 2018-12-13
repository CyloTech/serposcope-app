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
    DATA_STR="email=${EMAIL_ENC}&email-confirm=${EMAIL_ENC}&password=${ADMIN_PASS}&password-confirm=${ADMIN_PASS}"
    curl -v 'http://127.0.0.1/create-admin' --data ${DATA_STR} --compressed &> /var/log/serpuser.log

    # Finish App install.
    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"
    touch /etc/app_configured

else
    service serposcope start
fi
tail -F /var/log/serposcope/startup.log