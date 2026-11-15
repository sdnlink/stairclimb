"""Verify documented shell loading and the actual launcher with isolated resources."""

import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
from backend.tests.pg_fixture import Database


ROOT = Path(__file__).resolve().parents[2]
VARIABLES = ("STAIRCLIMB_HOST", "STAIRCLIMB_PORT", "DATABASE_URL")


class LauncherTests(unittest.TestCase):
    def clean_environment(self):
        environment = {key: value for key, value in os.environ.items() if key not in VARIABLES}
        # Use the same supported interpreter as the test runner in the child shell.
        environment["PATH"] = str(Path(sys.executable).parent) + os.pathsep + environment.get("PATH", "")
        return environment

    def test_sourcing_example_exports_all_settings_to_child(self):
        result = subprocess.run(
            ["sh", "-c", '. "$1"; exec "$2" -c "$3"', "config-test",
             str(ROOT / "backend/development.env.example"), sys.executable,
             "import json, os; print(json.dumps({k: os.environ.get(k) for k in " + repr(VARIABLES) + "}))"],
            cwd=ROOT, env=self.clean_environment(), capture_output=True, text=True, timeout=5, check=True,
        )
        self.assertEqual(json.loads(result.stdout), {
            "STAIRCLIMB_HOST": "127.0.0.1", "STAIRCLIMB_PORT": "8787",
            "DATABASE_URL": "postgresql://stairclimb:CHANGE_ME@127.0.0.1:5432/stairclimb",
        })

    def test_sourced_custom_config_starts_real_server_on_temporary_port_and_database(self):
        with tempfile.TemporaryDirectory(prefix="stairclimb-launch-") as temporary:
            directory = Path(temporary)
            database = Database()
            config = directory / "development.env"
            config.write_text((ROOT / "backend/development.env.example").read_text()
                              .replace("STAIRCLIMB_PORT=8787", "STAIRCLIMB_PORT=0")
                              .replace("DATABASE_URL=postgresql://stairclimb:CHANGE_ME@127.0.0.1:5432/stairclimb",
                                       f"DATABASE_URL='{database.url}'"))
            log_path = directory / "server.log"
            with log_path.open("w") as log:
                process = subprocess.Popen(
                    ["sh", "-c", '. "$1"; exec sh "$2"', "launch-test", str(config),
                     str(ROOT / "scripts/run_backend.sh")], cwd=directory,
                    env=self.clean_environment(), stdout=log, stderr=subprocess.STDOUT,
                )
                try:
                    deadline = time.monotonic() + 30
                    listener = None
                    while time.monotonic() < deadline:
                        output = log_path.read_text()
                        listener = re.search(r"listening on 127\.0\.0\.1:(\d+);", output)
                        if listener is not None or process.poll() is not None:
                            break
                        time.sleep(0.02)
                    self.assertIsNotNone(listener, 'Rust launcher did not open its temporary port')
                    port = int(listener.group(1))
                    self.assertGreater(port, 0)
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                    try:
                        connection.request("GET", "/health")
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertEqual(json.loads(response.read())["status"], "ok")
                    finally:
                        connection.close()
                    self.assertEqual(database.execute("SELECT COUNT(*) FROM schema_migrations").fetchone()[0], 1)
                    self.assertTrue(Path(f'/proc/{process.pid}/exe').resolve().name == 'stairclimb-server')
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                    database.close()


if __name__ == "__main__":
    unittest.main()
