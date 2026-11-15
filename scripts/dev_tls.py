#!/usr/bin/env python3
"""Create a private, task-local development CA and SAN certificate; never install trust."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def openssl(directory, *arguments):
    result = subprocess.run(['openssl', *arguments], cwd=directory, capture_output=True, umask=0o077)
    if result.returncode:
        raise RuntimeError('OpenSSL failed; check certificate inputs (private diagnostics suppressed)')


def initialize(directory, name='stairclimb.local', addresses=('127.0.0.1',)):
    directory = Path(directory).resolve()
    if not directory.is_relative_to((ROOT / '.runtime').resolve()):
        raise ValueError('Development TLS material must stay under ignored .runtime')
    if len(name) > 253 or any(not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', label) for label in name.split('.')):
        raise ValueError('Use a literal DNS name without wildcard or URL syntax')
    addresses = sorted({str(ipaddress.ip_address(ip)) for ip in addresses})
    expected = {'name': name, 'addresses': addresses}
    metadata = directory / 'certificate.json'
    if metadata.exists():
        if json.loads(metadata.read_text()) != expected:
            raise ValueError('Existing CA retained; use a separate ignored directory for different SANs')
        if not all((directory / p).is_file() for p in ['ca.pem', 'ca-key.pem', 'server.pem', 'server-key.pem', 'server.env']):
            raise ValueError('Incomplete existing CA retained; inspect it instead of overwriting')
        return directory
    if directory.exists() and any(directory.iterdir()):
        raise ValueError('Refusing to overwrite existing private TLS material')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    openssl(directory, 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', 'ca-key.pem')
    # Explicit config avoids duplicate CA extensions from the host's openssl.cnf
    # when older OpenSSL combines its defaults with repeated -addext arguments.
    (directory / 'ca.cnf').write_text(
        '[req]\ndistinguished_name=dn\nx509_extensions=ca_ext\nprompt=no\n'
        '[dn]\nCN=StairClimb local development CA\n'
        '[ca_ext]\nbasicConstraints=critical,CA:TRUE,pathlen:0\n'
        'keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
    openssl(directory, 'req', '-new', '-x509', '-sha256', '-days', '3650', '-key', 'ca-key.pem',
            '-config', 'ca.cnf', '-out', 'ca.pem')
    openssl(directory, 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', 'server-key.pem')
    openssl(directory, 'req', '-new', '-sha256', '-key', 'server-key.pem', '-subj', '/CN=' + name, '-out', 'server.csr')
    san = ['DNS:' + name, 'DNS:localhost', *['IP:' + ip for ip in addresses]]
    (directory / 'server.ext').write_text('subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=' + ','.join(san) + '\n')
    openssl(directory, 'x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca-key.pem',
            '-CAcreateserial', '-days', '30', '-sha256', '-extfile', 'server.ext', '-out', 'server.pem')
    (directory / 'server.env').write_text(
        'export STAIRCLIMB_TLS_CERT=' + shlex.quote(str(directory / 'server.pem')) + '\n'
        'export STAIRCLIMB_TLS_KEY=' + shlex.quote(str(directory / 'server-key.pem')) + '\n'
        'export STAIRCLIMB_HOST=127.0.0.1\nexport STAIRCLIMB_PORT=8443\n')
    metadata.write_text(json.dumps(expected, sort_keys=True) + '\n')
    for path in directory.iterdir():
        path.chmod(0o600)
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / '.runtime/tls')
    parser.add_argument('--name', default='stairclimb.local')
    parser.add_argument('--ip', action='append', default=['127.0.0.1'])
    args = parser.parse_args()
    directory = initialize(args.directory, args.name, args.ip)
    print(json.dumps({'directory': str(directory.relative_to(ROOT)), 'trust_installed': False,
                      'ca_certificate': str((directory / 'ca.pem').relative_to(ROOT)),
                      'configuration': str((directory / 'server.env').relative_to(ROOT))}))


if __name__ == '__main__':
    main()
