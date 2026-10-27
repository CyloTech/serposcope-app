#!/usr/bin/env python3
"""Exercise a Serposcope image on the builder with Docker and dummy credentials.

Usage: image-tests.py IMAGE

Scenarios (each with its own volume, labelled and removed afterwards):
  empty       ADMIN_PASS empty on a new volume: Serposcope never starts,
              setup exits 1, no callback
  fresh       new install with a password containing & # + % and a space:
              the administrator logs in with it, /create-admin is closed, one
              installed callback after that, no secret in any log
  restart     the same container restarted: no setup, no callback
  race        the volume of a new install already has an administrator that
              someone else created: the installation credentials do not log
              in, so setup stops Serposcope and exits 1 without a callback
  upgrade     the current published image installs, then this image starts on
              the same volume with a different ADMIN_PASS (as if the customer
              had changed the password in Serposcope): the existing
              administrator is kept, one callback; then a restart
Callbacks go to a local mock API; api.cylo.net and api.cylo.io resolve to
127.0.0.1 inside every container, so nothing reaches the real API.
"""
import http.cookiejar
import http.server
import importlib.util
import io
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

spec = importlib.util.spec_from_file_location('registry_check', Path(__file__).with_name('registry-check.py'))
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)

if len(sys.argv) != 2:
    raise SystemExit('Usage: image-tests.py IMAGE')
image = sys.argv[1]
run_id = 'serposcope-gate-' + uuid.uuid4().hex[:10]
label = 'appbox.release-gate=' + run_id
containers = []
volumes = []
hidden = []
callbacks = []
DATA = '/var/lib/serposcope/'


def hide(value):
    hidden.append(value)
    hidden.append(urllib.parse.quote_plus(value))
    return value


def redact(text):
    for value in hidden:
        text = text.replace(value, '[redacted]')
    return text


def docker(*args, check=True, timeout=600):
    result = subprocess.run(['docker', *args], capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('docker ' + args[0] + ' failed: ' + redact(result.stderr.decode(errors='replace')[-1500:]))
    return result


class Callback(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        target = urllib.parse.urlsplit(self.path)
        match = re.fullmatch(r'/v1/apps/installed/(\d+)', target.path)
        callbacks.append({
            'instance': match.group(1) if match else target.path,
            'query_token': urllib.parse.parse_qs(target.query).get('callback_token', [None])[0],
            'header_token': self.headers.get('X-Cylo-Callback-Token'),
        })
        self.send_response(200 if match else 404)
        self.end_headers()

    def log_message(self, *args):
        pass


gateway = json.loads(docker('network', 'inspect', 'bridge').stdout)[0]['IPAM']['Config'][0]['Gateway']
server = http.server.ThreadingHTTPServer((gateway, 0), Callback)
threading.Thread(target=server.serve_forever, daemon=True).start()
callback_base = 'http://host.docker.internal:' + str(server.server_port)


def volume(suffix):
    name = run_id + '-' + suffix
    docker('volume', 'create', '--label', label, name)
    volumes.append(name)
    return name


def install_env(instance, email, password, query_token=None, header_token=None):
    env = {
        'ADMIN_EMAIL': email,
        'ADMIN_PASS': password,
        'URL': 'https://serposcope.example.test/',
        'INSTANCE_ID': instance + ('?callback_token=' + query_token if query_token else ''),
        'APPBOX_CALLBACK_BASE': callback_base,
    }
    if header_token:
        env['CALLBACK_TOKEN'] = header_token
    return env


def launch(suffix, selected_image, data_volume, env):
    name = run_id + '-' + suffix
    args = ['create', '--platform', 'linux/amd64', '--name', name, '--label', label, '--init',
            '--add-host', 'host.docker.internal:host-gateway',
            '--add-host', 'api.cylo.net:127.0.0.1', '--add-host', 'api.cylo.io:127.0.0.1',
            '-p', '127.0.0.1::80', '-v', data_volume + ':' + DATA]
    for key, value in env.items():
        args += ['-e', key + '=' + value]
    # Track the name first: a slow create can time out here and still finish.
    containers.append(name)
    docker(*args, selected_image)
    docker('start', name)
    return name


def all_logs(name):
    """Container log plus the supervisor, Serposcope and old create-admin logs."""
    text = subprocess.run(['docker', 'logs', name], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          timeout=60).stdout.decode(errors='replace')
    text += docker('exec', name, 'sh', '-c',
                   'cat /var/log/supervisor/* /var/log/serposcope/* /var/log/serpuser.log 2>/dev/null; true',
                   check=False).stdout.decode(errors='replace')
    return text


def evidence(name):
    return '\n--- last log lines of ' + name + ' ---\n' + redact('\n'.join(all_logs(name).splitlines()[-40:]))


def base_url(name):
    return 'http://' + docker('port', name, '80/tcp').stdout.decode().splitlines()[0].strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def get_status(name, path):
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(base_url(name) + path, timeout=10) as response:
            return str(response.status)
    except urllib.error.HTTPError as error:
        return str(error.code) + ' ' + urllib.parse.urlsplit(error.headers.get('Location', '')).path


def answering(name):
    try:
        get_status(name, '/')
        return True
    except (urllib.error.URLError, ConnectionError, OSError):
        return False


def login(name, email, password):
    """True when the credentials open the dashboard."""
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    data = urllib.parse.urlencode({'email': email, 'password': password}).encode()
    with opener.open(base_url(name) + '/login', data=data, timeout=15) as response:
        response.read()
    with opener.open(base_url(name) + '/', timeout=15) as response:
        response.read()
        return response.status == 200 and urllib.parse.urlsplit(response.geturl()).path == '/'


def wait_until(name, check, what, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if check():
                return
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        time.sleep(2)
    raise RuntimeError(name + ': ' + what + ' timed out' + evidence(name))


def program_state(name):
    out = docker('exec', name, 'supervisorctl', 'status', 'serposcope', check=False).stdout.decode()
    return out.split()[1] if len(out.split()) > 1 else out.strip()


def volume_files(name):
    """Names in the data volume of container NAME (running or stopped)."""
    archive = docker('cp', name + ':' + DATA, '-').stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        return {Path(member.name).name for member in tar.getmembers()
                if len(Path(member.name).parts) == 2}


def touch_pending(name):
    """Create the new-install marker in the data volume of stopped container NAME."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w') as tar:
        tar.addfile(tarfile.TarInfo('.appbox_install_pending'), io.BytesIO(b''))
    subprocess.run(['docker', 'cp', '-', name + ':' + DATA], input=buffer.getvalue(), check=True,
                   capture_output=True, timeout=600)


def callbacks_for(instance):
    return [c for c in callbacks if c['instance'] == instance]


def check_no_secrets(name):
    text = all_logs(name)
    assert not [value for value in hidden if value in text], 'secret value in the logs of ' + name


def check_runtime(name):
    pid = docker('exec', name, 'cat', '/var/run/serposcope.pid').stdout.decode().strip()
    status = docker('exec', name, 'cat', '/proc/' + pid + '/status').stdout.decode()
    assert re.search(r'^Uid:\s+1000\s+1000\s+1000\s+1000$', status, re.M), 'Serposcope is not running as UID 1000'


try:
    details = json.loads(docker('image', 'inspect', image).stdout)[0]
    assert details['Architecture'] == 'amd64' and details['Os'] == 'linux'
    assert details['Config']['Entrypoint'] == ['/usr/bin/supervisord', '-c', '/etc/supervisor/supervisord.conf']
    env = dict(item.split('=', 1) for item in details['Config']['Env'])
    assert env['ADMIN_EMAIL'] == '' and env['ADMIN_PASS'] == '', 'default administrator still set'
    assert env['SERPOSCOPE_PORT'] == '80'
    probe = ('bash -n /docker-entrypoint.sh && test -x /usr/local/bin/appbox-installed-callback'
             ' && dpkg-query -W -f="\\${Version}" serposcope')
    version = docker('run', '--rm', '--network', 'none', '--entrypoint', 'sh', image, '-c', probe).stdout.decode()
    assert version == '2.13.0', version
    print('PASS static: linux/amd64, supervisord entrypoint, no default administrator, Serposcope 2.13.0', flush=True)

    legacy_password = hide('Legacy' + secrets.token_hex(6))
    legacy_volume = volume('upgrade')
    baseline = launch('baseline', registry.CURRENT, legacy_volume,
                      install_env('900001141', 'legacy@example.com', legacy_password))

    empty_volume = volume('empty')
    empty = launch('empty', image, empty_volume,
                   install_env('900001142', 'empty@example.com', '', hide(secrets.token_urlsafe(16))))
    wait_until(empty, lambda: program_state(empty) in ('FATAL', 'EXITED'), 'empty setup exit', 180)
    time.sleep(5)
    assert not answering(empty), 'Serposcope answered without installation credentials'
    assert 'ADMIN_EMAIL and ADMIN_PASS must be set for a new installation' in all_logs(empty)
    assert not callbacks_for('900001142')
    assert volume_files(empty) == set(), volume_files(empty)
    print('PASS empty: setup exits before Serposcope starts; no callback, nothing created', flush=True)

    fresh_email = 'gate+test@example.com'
    fresh_password = hide('Gate&#+% ' + secrets.token_hex(6) + ' =?;')
    fresh_query = hide(secrets.token_urlsafe(18))
    fresh_header = hide(secrets.token_urlsafe(18))
    fresh_volume = volume('fresh')
    fresh = launch('fresh', image, fresh_volume,
                   install_env('900001143', fresh_email, fresh_password, fresh_query, fresh_header))
    wait_until(fresh, lambda: callbacks_for('900001143'), 'installed callback')
    sent = callbacks_for('900001143')
    assert len(sent) == 1 and sent[0]['query_token'] == fresh_query and sent[0]['header_token'] == fresh_header, sent
    assert get_status(fresh, '/create-admin') == '303 /login'
    assert login(fresh, fresh_email, fresh_password), 'installation credentials do not log in'
    assert not login(fresh, fresh_email, fresh_password.split('&')[0]), 'truncated password logs in'
    assert not login(fresh, 'test@test.com', 'test123'), 'old default administrator logs in'
    logs = all_logs(fresh)
    assert 'Serposcope administrator account created and verified.' in logs, evidence(fresh)
    assert docker('exec', fresh, 'test', '-e', '/var/log/serpuser.log', check=False).returncode != 0
    files = volume_files(fresh)
    assert 'db.mv.db' in files and '.appbox_install_pending' not in files, files
    assert program_state(fresh) == 'RUNNING'
    check_runtime(fresh)
    check_no_secrets(fresh)
    print('PASS fresh: special-character password logs in, /create-admin closed, one authenticated callback, '
          'no secrets in logs', flush=True)

    docker('restart', '--time', '20', fresh)
    wait_until(fresh, lambda: answering(fresh), 'restart')
    time.sleep(15)
    assert all_logs(fresh).count('Creating the Serposcope administrator account.') == 1
    assert len(callbacks_for('900001143')) == 1, 'restart sent another callback'
    assert login(fresh, fresh_email, fresh_password)
    check_runtime(fresh)
    check_no_secrets(fresh)
    print('PASS restart: no setup, no callback, administrator unchanged', flush=True)
    docker('stop', '--time', '20', fresh)

    # Someone else created the administrator before this installation could.
    touch_pending(fresh)
    race_password = hide('Race' + secrets.token_hex(6))
    race = launch('race', image, fresh_volume,
                  install_env('900001144', 'race@example.com', race_password, hide(secrets.token_urlsafe(16))))
    wait_until(race, lambda: program_state(race) in ('EXITED', 'FATAL'), 'race setup exit', 300)
    time.sleep(3)
    assert 'does not accept the installation credentials' in all_logs(race), evidence(race)
    assert not answering(race), 'Serposcope left running after failed verification'
    assert not callbacks_for('900001144'), 'callback sent after failed verification'
    assert '.appbox_install_pending' in volume_files(race)
    check_no_secrets(race)
    print('PASS race: unverified administrator, Serposcope stopped, exit 1, no callback', flush=True)

    wait_until(baseline, lambda: answering(baseline) and login(baseline, 'legacy@example.com', legacy_password),
               'current image install')
    docker('stop', '--time', '20', baseline)
    changed_env = install_env('900001141', 'legacy@example.com', hide('Changed' + secrets.token_hex(6)))
    upgraded = launch('upgraded', image, legacy_volume, changed_env)
    wait_until(upgraded, lambda: callbacks_for('900001141'), 'upgrade callback')
    logs = all_logs(upgraded)
    assert 'Serposcope already has an administrator account; keeping it.' in logs, evidence(upgraded)
    assert 'Creating the Serposcope administrator account.' not in logs
    assert len(callbacks_for('900001141')) == 1
    assert login(upgraded, 'legacy@example.com', legacy_password), 'existing administrator lost'
    assert not login(upgraded, 'legacy@example.com', changed_env['ADMIN_PASS'])
    assert get_status(upgraded, '/create-admin') == '303 /login'
    check_runtime(upgraded)
    check_no_secrets(upgraded)
    docker('restart', '--time', '20', upgraded)
    wait_until(upgraded, lambda: answering(upgraded), 'restart after upgrade')
    time.sleep(15)
    assert len(callbacks_for('900001141')) == 1, 'restart after upgrade sent another callback'
    assert login(upgraded, 'legacy@example.com', legacy_password)
    print('PASS upgrade from the current image: administrator and data kept, one callback, restart quiet',
          flush=True)
    print('PASS image tests', flush=True)
except Exception as error:
    print('FAIL image tests: ' + type(error).__name__ + ': ' + redact(str(error)), flush=True)
    raise SystemExit(1)
finally:
    for name in reversed(containers):
        try:
            inspected = docker('inspect', '--format', '{{index .Config.Labels "appbox.release-gate"}}', name, check=False)
            if inspected.returncode and b'No such' in inspected.stderr:
                continue
            found = inspected.stdout.decode().strip()
            if found != run_id:
                raise RuntimeError('Container cleanup identity mismatch')
            docker('rm', '-f', name)
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    for name in volumes:
        try:
            found = docker('volume', 'inspect', '--format', '{{index .Labels "appbox.release-gate"}}', name).stdout.decode().strip()
            if found != run_id:
                raise RuntimeError('Volume cleanup identity mismatch')
            docker('volume', 'rm', name)
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    server.shutdown()
