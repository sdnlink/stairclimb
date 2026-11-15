#!/usr/bin/env python3
"""Task-only SMTP sink. No outbound delivery, loopback only, private ignored files."""
import argparse
from email import policy
from email.parser import BytesParser
import json
from pathlib import Path
import re
import socketserver
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)
        self.wfile.write(b'220 local-capture ESMTP\r\n')
        for _ in range(100):
            line = self.rfile.readline(8193)
            if not line or len(line) > 8192:
                return
            verb = line.split(b' ', 1)[0].strip().upper()
            if verb in [b'EHLO', b'HELO']:
                self.wfile.write(b'250-local-capture\r\n250 8BITMIME\r\n')
            elif verb in [b'MAIL', b'RCPT', b'RSET', b'NOOP']:
                self.wfile.write(b'250 OK\r\n')
            elif verb == b'DATA':
                self.wfile.write(b'354 End with dot\r\n')
                data = bytearray()
                while True:
                    row = self.rfile.readline(8193)
                    if not row or len(row) > 8192:
                        return
                    if row == b'.\r\n':
                        break
                    data.extend(row[1:] if row.startswith(b'..') else row)
                    if len(data) > 65536:
                        return
                if self.server.reject:
                    self.wfile.write(b'451 local test rejection\r\n')
                else:
                    path = self.server.directory / (uuid.uuid4().hex + '.eml')
                    with path.open('xb') as out:
                        path.chmod(0o600)
                        out.write(data)
                    with self.server.condition:
                        self.server.messages.append(bytes(data))
                        self.server.condition.notify_all()
                    self.wfile.write(b'250 Captured locally\r\n')
            elif verb == b'QUIT':
                self.wfile.write(b'221 Bye\r\n')
                return
            else:
                self.wfile.write(b'502 Unsupported\r\n')


class Capture(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, directory, port=0):
        directory = Path(directory).resolve()
        runtime = (ROOT / '.runtime').resolve()
        if not directory.is_relative_to(runtime):
            raise ValueError('Capture files must stay under ignored .runtime')
        directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        directory.chmod(0o700)
        self.directory = directory
        self.messages = []
        self.condition = threading.Condition()
        self.reject = False
        super().__init__(('127.0.0.1', port), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    @property
    def environment(self):
        return {'SMTP_MODE': 'local-capture', 'SMTP_HOST': '127.0.0.1',
                'SMTP_PORT': str(self.server_address[1]), 'SMTP_FROM': 'noreply@stairclimb.test'}

    def token(self, index=-1):
        with self.condition:
            raw = self.messages[index]
        message = BytesParser(policy=policy.default).parsebytes(raw)
        text = message.get_content()
        tokens = re.findall(r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])', text)
        if len(tokens) != 1:
            raise AssertionError('Captured mail must contain exactly one credential')
        return tokens[0]

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=1025)
    args = parser.parse_args()
    capture = Capture(ROOT / '.runtime/mail-capture', args.port)
    print(json.dumps({'host': '127.0.0.1', 'port': capture.server_address[1],
                      'directory': '.runtime/mail-capture', 'external_delivery': False}), flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        capture.close()


if __name__ == '__main__':
    main()
