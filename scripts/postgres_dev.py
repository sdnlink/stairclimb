#!/usr/bin/env python3
"""Manage only this project's loopback-only PostgreSQL container; never print secrets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
from urllib.parse import quote, urlsplit, urlunsplit, parse_qsl, urlencode

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / '.runtime'
NAME = 'stairclimb-pg-' + hashlib.sha256(str(ROOT).encode()).hexdigest()[:10]
IMAGE = 'postgres:17-bookworm'


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        # Docker/psql stderr can contain URLs or SQL data. Keep diagnostics bounded.
        raise RuntimeError(f'{args[0]} {args[1]} failed (exit {result.returncode}); check task container locally')
    return result.stdout.strip()


def private_write(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(value)
    os.chmod(path, 0o600)


def ensure():
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    config = RUNTIME / 'postgres-container.env'
    if not config.exists():
        private_write(config, 'POSTGRES_USER=postgres\nPOSTGRES_DB=stairclimb\nPOSTGRES_PASSWORD=' + secrets.token_urlsafe(32) + '\n')
    found = subprocess.run(['docker', 'inspect', NAME], capture_output=True, text=True)
    if found.returncode:
        run(['docker', 'run', '-d', '--name', NAME, '--label', 'stairclimb.project=' + str(ROOT),
             '--env-file', str(config), '-p', '127.0.0.1::5432',
             '--mount', f'type=volume,source={NAME}-data,target=/var/lib/postgresql/data', IMAGE])
    else:
        details = json.loads(found.stdout)[0]
        if details['Config']['Labels'].get('stairclimb.project') != str(ROOT):
            raise RuntimeError('Refusing to use a container not owned by this project')
        if not details['State']['Running']:
            run(['docker', 'start', NAME])
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        probe = subprocess.run(['docker', 'exec', '-u', 'postgres', NAME, 'pg_isready', '-q', '-d', 'stairclimb'], capture_output=True)
        if probe.returncode == 0:
            break
        time.sleep(.15)
    else:
        raise RuntimeError('Task PostgreSQL readiness timed out')
    details = json.loads(run(['docker', 'inspect', NAME]))[0]
    binding = details['NetworkSettings']['Ports']['5432/tcp'][0]
    if binding['HostIp'] != '127.0.0.1':
        raise RuntimeError('Task database must listen on loopback only')
    password = dict(line.split('=', 1) for line in config.read_text().splitlines())['POSTGRES_PASSWORD']
    url = f"postgresql://postgres:{quote(password, safe='')}@127.0.0.1:{binding['HostPort']}/stairclimb"
    private_write(RUNTIME / 'postgres.env', 'export DATABASE_URL=' + url + '\n')
    metadata = {'container': NAME, 'host': '127.0.0.1', 'port': int(binding['HostPort']), 'database': 'stairclimb', 'image': IMAGE}
    (RUNTIME / 'postgres.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return url


def sql(statement):
    return run(['docker', 'exec', '-i', '-u', 'postgres', NAME, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', 'stairclimb'], input=statement)


def schema_url(base, schema):
    parts = urlsplit(base)
    query = dict(parse_qsl(parts.query))
    query['options'] = '-csearch_path=' + schema
    return urlunsplit(parts._replace(query=urlencode(query)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'status', 'stop', 'test-url', 'drop-test-schema'])
    parser.add_argument('--schema')
    args = parser.parse_args()
    if args.action == 'stop':
        details = json.loads(run(['docker', 'inspect', NAME]))[0]
        if details['Config']['Labels'].get('stairclimb.project') != str(ROOT):
            raise RuntimeError('Container ownership mismatch')
        run(['docker', 'stop', NAME])
        print('Stopped task PostgreSQL; retained project volume ' + NAME + '-data')
        return
    if args.action in ('test-url', 'drop-test-schema'):
        import re
        if not args.schema or not re.fullmatch(r'test_[a-f0-9]{32}', args.schema):
            parser.error('Only a generated test_<32 hex> schema is allowed')
        if args.action == 'test-url':
            base = ensure()
            sql('CREATE SCHEMA ' + args.schema)
            print(schema_url(base, args.schema))  # Only for captured test subprocess output.
        else:
            sql('DROP SCHEMA IF EXISTS ' + args.schema + ' CASCADE')
        return
    ensure()
    print(json.dumps(json.loads((RUNTIME / 'postgres.json').read_text()), ensure_ascii=False))
    print('Credentials: .runtime/postgres.env (mode 600, ignored); stop: python3 scripts/postgres_dev.py stop')


if __name__ == '__main__':
    main()
