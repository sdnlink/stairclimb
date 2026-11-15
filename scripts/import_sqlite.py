#!/usr/bin/env python3
"""Back up legacy SQLite and import into an EMPTY schema of task PostgreSQL."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts import postgres_dev as pg


def literal(value):
    if isinstance(value, int):
        return str(value)
    return "'" + value.replace("'", "''") + "'"


def import_backup(source, schema):
    if not re.fullmatch(r'(test|import)_[a-f0-9]{32}', schema):
        raise ValueError('Only an explicit generated import/test schema is accepted')
    source = Path(source).resolve(strict=True)
    backups = pg.RUNTIME/'backups'
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = backups/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S') + '-' + schema + '.sqlite3')
    # SQLite online backup is consistent even if the legacy DB uses WAL.
    with sqlite3.connect('file:' + str(source) + '?mode=ro', uri=True) as original, sqlite3.connect(backup) as saved:
        original.backup(saved)
    backup.chmod(0o600)
    with sqlite3.connect(backup) as db:
        db.row_factory = sqlite3.Row
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {'users', 'metadata'} <= tables:
            raise ValueError('Unsupported legacy schema; backup retained')
        rows = {table: [dict(row) for row in db.execute('SELECT * FROM ' + table)] if table in tables else []
                for table in ['users', 'metadata', 'daily_steps', 'circle_participation']}
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok' or db.execute('PRAGMA foreign_key_check').fetchall():
            raise ValueError('Legacy integrity check failed; backup retained')
    for user in rows['users']:
        if not re.fullmatch(r'[a-f0-9]{64}', user['token_hash']) or user['sharing_enabled'] not in (0, 1) or user['consent_revision'] < 0:
            raise ValueError('Invalid legacy identity/consent data; backup retained')
    statements = ['BEGIN', 'CREATE SCHEMA IF NOT EXISTS ' + schema, 'SET LOCAL search_path TO ' + schema]
    for migration in sorted((pg.ROOT/'backend/migrations').glob('*.sql')):
        statements.append(migration.read_text())
    # Fail atomically rather than clearing or merging target identity data.
    statements.append("DO $$ BEGIN IF EXISTS(SELECT 1 FROM users) OR EXISTS(SELECT 1 FROM daily_steps) OR EXISTS(SELECT 1 FROM circle_participation) THEN RAISE EXCEPTION 'Target must be empty'; END IF; END $$")
    for table in ['users', 'daily_steps', 'circle_participation']:
        for row in rows[table]:
            columns = list(row)
            allowed = {'users': {'id','token_hash','nickname','sharing_enabled','consent_revision','created_at'},
                       'daily_steps': {'user_id','date','steps','updated_at'},
                       'circle_participation': {'user_id','enabled'}}[table]
            if set(columns) != allowed:
                raise ValueError('Unsupported legacy columns; backup retained')
            statements.append('INSERT INTO ' + table + '(' + ','.join(columns) + ') VALUES (' + ','.join(literal(row[c]) for c in columns) + ')')
    version = next((r['value'] for r in rows['metadata'] if r['key'] == 'leaderboard_revision'), 0)
    statements.append("UPDATE metadata SET value=" + str(int(version)) + " WHERE key='leaderboard_revision'")
    statements.append('COMMIT')
    pg.sql(';\n'.join(statements) + ';')
    # Compare every persisted field, including hashes/versions/history, without logging values.
    for table in ['users', 'daily_steps', 'circle_participation']:
        actual = json.loads(pg.sql('SET search_path TO ' + schema + "; SELECT COALESCE(json_agg(t),'[]'::json) FROM (SELECT * FROM " + table + ') t;'))
        canonical = lambda items: sorted(json.dumps(row, sort_keys=True, ensure_ascii=True) for row in items)
        if canonical(actual) != canonical(rows[table]):
            raise RuntimeError('Import field verification failed; backup and target retained for inspection')
    actual_version = pg.sql('SET search_path TO ' + schema + "; SELECT value FROM metadata WHERE key='leaderboard_revision'")
    if int(actual_version) != version:
        raise RuntimeError('Imported pagination version does not match backup')
    return {'backup': str(backup.relative_to(pg.ROOT)), 'backup_sha256': hashlib.sha256(backup.read_bytes()).hexdigest(),
            'schema': schema, 'users': len(rows['users']), 'days': len(rows['daily_steps']),
            'participation': len(rows['circle_participation']), 'verified_fields': 'all identity/hash/consent/history/circle fields'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sqlite', type=Path, required=True)
    parser.add_argument('--schema', required=True, help='import_<32 random lowercase hex>; never overwrites data')
    args = parser.parse_args()
    pg.ensure()
    print(json.dumps(import_backup(args.sqlite, args.schema), ensure_ascii=False))


if __name__ == '__main__':
    main()
