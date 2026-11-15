"""Actual PostgreSQL + compiled Rust process fixture. Python implements no HTTP business logic."""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import uuid

from scripts import postgres_dev as pg

ROOT = Path(__file__).resolve().parents[2]
_built = False
_base_url = None


def prepare():
    global _built, _base_url
    if _base_url is None:
        _base_url = pg.ensure()
    if not _built:
        result = subprocess.run(['cargo', 'build', '--locked', '--manifest-path', str(ROOT/'backend/Cargo.toml'),
                                 '--features', 'test-support', '--bins'], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Rust fixture build failed: ' + result.stderr[-5000:])
        _built = True
    return _base_url


class Rows:
    def __init__(self, rows):
        self.rows = rows
    def fetchone(self):
        return self.rows[0] if self.rows else None
    def fetchall(self):
        return self.rows


class Database:
    def __init__(self):
        self.schema = 'test_' + uuid.uuid4().hex
        self.url = pg.schema_url(prepare(), self.schema)
        pg.sql('CREATE SCHEMA ' + self.schema)

    def __str__(self):
        return self.schema  # No credential in assertion diagnostics.

    def execute(self, query, parameters=()):
        for value in parameters:
            literal = str(value) if isinstance(value, int) else "'" + str(value).replace("'", "''") + "'"
            query = query.replace('?', literal, 1)
        prefix = 'SET search_path TO ' + self.schema + '; '
        if query.lstrip().upper().startswith('SELECT'):
            output = pg.sql(prefix + "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (" + query + ') t;')
            return Rows([tuple(row.values()) for row in json.loads(output)])
        pg.sql(prefix + query + ';')
        return Rows([])

    @contextmanager
    def connect(self):
        yield self

    @contextmanager
    def outage(self):
        # Real missing PostgreSQL relation, not a stubbed HTTP response or fake DB.
        self.execute('ALTER TABLE users RENAME TO users_offline')
        try:
            yield
        finally:
            self.execute('ALTER TABLE users_offline RENAME TO users')

    @contextmanager
    def write_lock(self, user_id=None):
        command = ['docker', 'exec', '-i', '-u', 'postgres', pg.NAME, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', 'stairclimb']
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        target = "SELECT value FROM metadata WHERE key='leaderboard_revision' FOR UPDATE" if user_id is None else "SELECT id FROM users WHERE id='" + str(user_id).replace("'", "''") + "' FOR UPDATE"
        process.stdin.write('SET search_path TO ' + self.schema + "; BEGIN; " + target + ";\n\\echo LOCKED\n")
        process.stdin.flush()
        while process.stdout.readline().strip() != 'LOCKED':
            if process.poll() is not None:
                raise RuntimeError('Could not acquire actual PostgreSQL transaction lock')
        try:
            yield process
        finally:
            process.stdin.write('COMMIT;\n\\q\n')
            process.stdin.flush()
            process.communicate(timeout=5)
            if process.returncode:
                raise RuntimeError('PostgreSQL blocker transaction failed')

    def wait_for_blocked_writer(self):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            result = pg.sql("SELECT COUNT(*) FROM pg_stat_activity WHERE application_name='" + self.schema + "' AND wait_event_type='Lock'")
            if int(result) > 0:
                return
            time.sleep(.01)
        raise AssertionError('Rust request did not wait on actual PostgreSQL lock')

    def close(self):
        pg.sql('DROP SCHEMA IF EXISTS ' + self.schema + ' CASCADE')


class RustServer:
    def __init__(self, database, clock, *, email_only=False, mail_environment=None, production=False, tls_environment=None, binary=None, pool_environment=None):
        self.database = database
        self.clock = clock
        self.temporary = tempfile.TemporaryDirectory(prefix='stairclimb-rust-http-')
        self.directory = Path(self.temporary.name)
        self.clock_file = self.directory/'clock'
        self.clock_lock = threading.Lock()
        self.set_time(clock())
        self.log_path = self.directory/'server.log'
        self.log = self.log_path.open('w')
        environment = dict(os.environ, DATABASE_URL=database.url)
        for key in list(environment):
            if key.startswith('SMTP_') or key.startswith('STAIRCLIMB_TLS_') or key.startswith('STAIRCLIMB_DB_POOL_'):
                environment.pop(key)
        environment.update(mail_environment or {})
        environment.update(tls_environment or {})
        environment.update(pool_environment or {})
        # application_name lets tests observe actual row lock waits without HTTP test controls.
        from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
        parts = urlsplit(database.url)
        query = dict(parse_qsl(parts.query), application_name=database.schema)
        environment['DATABASE_URL'] = urlunsplit(parts._replace(query=urlencode(query)))
        self.process = subprocess.Popen([str(binary.resolve() if binary else ROOT/('backend/target/debug/stairclimb-server' if production else 'backend/target/debug/stairclimb-test-server')),
                                         '--host', '127.0.0.1', '--port', '0',
                                         *([] if production else ['--clock-file', str(self.clock_file)]),
                                         *(['--email-only', 'true'] if email_only and not production else [])],
                                        env=environment, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            output = self.log_path.read_text()
            match = re.search(r'listening on 127\.0\.0\.1:(\d+);', output)
            if match:
                self.server_port = int(match.group(1))
                return
            if self.process.poll() is not None:
                break
            time.sleep(.01)
        self.close()
        raise RuntimeError('Rust server did not start; inspect sanitized startup diagnostics')

    def set_time(self, now):
        with self.clock_lock:
            new = self.directory/'clock.new'
            new.write_text(now.isoformat())
            new.replace(self.clock_file)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.log.close()
        self.temporary.cleanup()
