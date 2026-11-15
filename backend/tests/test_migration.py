"""Legacy data fixtures are imported, then verified over real Rust/PostgreSQL HTTP."""
from datetime import datetime, timezone
import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from backend.storage import Store  # Historical fixture generation only; never serves HTTP.
from backend.tests.pg_fixture import Database, RustServer
from scripts.import_sqlite import import_backup
from scripts import postgres_dev as pg


class PostgreSQLMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='stairclimb-import-')
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name)/'legacy.sqlite3'
        self.database = Database()
        self.addCleanup(self.database.close)
        self.now = datetime(2026, 11, 14, 10, 30, tzinfo=timezone.utc)
        self.legacy = Store(self.source)
        old_backups = set((pg.RUNTIME/'backups').glob('*.sqlite3'))
        def cleanup_test_backups():
            for backup in set((pg.RUNTIME/'backups').glob('*.sqlite3')) - old_backups:
                if self.database.schema in backup.name:
                    backup.unlink(missing_ok=True)
        self.addCleanup(cleanup_test_backups)

    def migrate(self):
        report = import_backup(self.source, self.database.schema)
        self.addCleanup(lambda: (pg.ROOT/report['backup']).unlink(missing_ok=True))
        return report

    def request(self, server, path, token):
        connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
        try:
            connection.request('GET', path, headers={'Authorization': 'Bearer ' + token})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return json.loads(response.read())
        finally:
            connection.close()

    def test_import_preserves_credentials_consents_history_and_circle_on_rust_restart(self):
        first = self.legacy.register('保留本人', self.now)
        second = self.legacy.register('保持私有', self.now)
        auth = 'Bearer ' + first['token']
        self.legacy.sharing(auth, True, 0)
        self.legacy.circle_participation(auth, True, 1, update=True)
        self.legacy.sync_steps(auth, '2026-11-14', 1001, 2, lambda: self.now)
        report = self.migrate()
        self.assertEqual((report['users'], report['days'], report['participation']), (2, 1, 1))
        with sqlite3.connect(self.source) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM users').fetchone()[0], 2)
        for _ in range(2):
            server = RustServer(self.database, lambda: self.now)
            try:
                profile = self.request(server, '/v1/me', first['token'])['user']
                self.assertEqual(profile, dict(first['user'], sharing_enabled=True, consent_revision=2))
                self.assertEqual(self.request(server, '/v1/me/steps', first['token'])['progress']['steps'], 1001)
                circle = self.request(server, '/v1/circles/current', first['token'])
                self.assertEqual(circle['circle']['id'], '2026-11-14:1000-1999')
                self.assertEqual(circle['total'], 1)
                self.assertFalse(self.request(server, '/v1/me', second['token'])['user']['sharing_enabled'])
            finally:
                server.close()

    def test_old_identity_only_schema_imports_without_auto_participation(self):
        user = self.legacy.register('旧身份', self.now)
        self.legacy.sharing('Bearer ' + user['token'], True, 0)
        with sqlite3.connect(self.source) as db:
            db.execute('DROP TABLE daily_steps')
            db.execute('DROP TABLE circle_participation')
        self.migrate()
        server = RustServer(self.database, lambda: self.now)
        try:
            self.assertTrue(self.request(server, '/v1/me', user['token'])['user']['sharing_enabled'])
            self.assertFalse(self.request(server, '/v1/circles/current', user['token'])['participating'])
            self.assertFalse(self.request(server, '/v1/me/steps', user['token'])['progress']['synced'])
        finally:
            server.close()

    def test_nonempty_target_rejected_without_resetting_either_database(self):
        user = self.legacy.register('不可清空', self.now)
        self.migrate()
        with self.assertRaises(RuntimeError):
            import_backup(self.source, self.database.schema)
        self.assertEqual(self.database.execute('SELECT COUNT(*) FROM users').fetchone()[0], 1)
        self.assertEqual(self.database.execute('SELECT id FROM users').fetchone()[0], user['user']['id'])
