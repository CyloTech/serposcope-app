#!/bin/bash
# No `set -x`: a trace would copy ADMIN_PASS and the callback token in
# INSTANCE_ID into the supervisor logs.

serposcope_url="http://127.0.0.1:${SERPOSCOPE_PORT:-80}"
data_dir=/var/lib/serposcope
# Present in the data volume from the first start of a new installation until
# its administrator account is verified, so a retry is still treated as new.
install_pending="${data_dir}/.appbox_install_pending"

# Wait up to 10 minutes for Serposcope to answer HTTP requests.
wait_for_serposcope() {
    local _
    for _ in $(seq 1 300); do
        curl -s -o /dev/null --max-time 5 "${serposcope_url}/" && return 0
        sleep 2
    done
    return 1
}

# Once an administrator exists, Serposcope redirects /create-admin to /login.
admin_exists() {
    local result
    result=$(curl -s -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}' "${serposcope_url}/create-admin")
    [[ "${result}" == 30[0-9]\ */login ]]
}

# Log in with the installation credentials and check that the dashboard opens.
admin_login_works() {
    local jar status
    jar=$(mktemp) || return 1
    curl -s -o /dev/null --max-time 10 -c "${jar}" -b "${jar}" \
        --data-urlencode "email=${ADMIN_EMAIL}" \
        --data-urlencode "password=${ADMIN_PASS}" \
        "${serposcope_url}/login"
    status=$(curl -s -o /dev/null --max-time 10 -b "${jar}" -w '%{http_code}' "${serposcope_url}/")
    rm -f "${jar}"
    [[ "${status}" == 200 ]]
}

# Stop Serposcope, so /create-admin is not left open, and exit without
# confirming the installation to Appbox.
fail_install() {
    echo "Serposcope setup failed: $1. The installation was not confirmed." >&2
    service serposcope stop
    exit 1
}

if [ ! -f /etc/app_configured ]; then

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

    # A volume without a database is a new installation. It needs the
    # installation credentials before Serposcope starts and /create-admin
    # becomes reachable.
    if ! compgen -G "${data_dir}/db.*" >/dev/null; then
        if [[ -z "${ADMIN_EMAIL}" || -z "${ADMIN_PASS}" ]]; then
            echo "Serposcope setup failed: ADMIN_EMAIL and ADMIN_PASS must be set for a new installation." >&2
            exit 1
        fi
        touch "${install_pending}"
        chown serposcope:staff "${install_pending}"
    fi

    service serposcope start
    wait_for_serposcope || fail_install "Serposcope did not start"

    if [[ ! -f "${install_pending}" ]] && admin_exists; then
        echo "Serposcope already has an administrator account; keeping it."
    else
        if [[ -z "${ADMIN_EMAIL}" || -z "${ADMIN_PASS}" ]]; then
            fail_install "ADMIN_EMAIL and ADMIN_PASS are not set"
        fi
        echo "Creating the Serposcope administrator account."
        curl -s -o /dev/null --max-time 30 \
            --data-urlencode "email=${ADMIN_EMAIL}" \
            --data-urlencode "email-confirm=${ADMIN_EMAIL}" \
            --data-urlencode "password=${ADMIN_PASS}" \
            --data-urlencode "password-confirm=${ADMIN_PASS}" \
            "${serposcope_url}/create-admin"
        admin_exists || fail_install "the administrator account was not created"
        admin_login_works || fail_install "the administrator account does not accept the installation credentials"
        rm -f "${install_pending}"
        echo "Serposcope administrator account created and verified."
    fi

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