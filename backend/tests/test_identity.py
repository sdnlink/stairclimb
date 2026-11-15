"""Real HTTP tests: every test owns an ephemeral listener and a temporary database."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr
from datetime import datetime, timezone
import hashlib
import http.client
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest

from backend.domain import APIError, MAX_BODY_BYTES, MAX_STEPS, day_context, progress
from backend.tests.pg_fixture import Database, RustServer


class RulesTests(unittest.TestCase):
    def test_floor_and_remaining_boundaries(self):
        for steps, floor, remaining in [(0, 0, 100), (99, 0, 1), (100, 1, 100),
                                        (101, 1, 99), (12789, 127, 11),
                                        (MAX_STEPS, 10000, 100)]:
            with self.subTest(steps=steps):
                self.assertEqual(progress(steps), {
                    "steps": steps, "floor": floor, "remaining_steps": remaining,
                })

    def test_invalid_step_types_and_bounds(self):
        for value in [-1, MAX_STEPS + 1, True, False, 1.0, "100", None, [], {}]:
            with self.subTest(value=value), self.assertRaises(APIError):
                progress(value)

    def test_shanghai_midnight_and_year_boundary(self):
        before = day_context(datetime(2026, 12, 31, 15, 59, 59, tzinfo=timezone.utc))
        after = day_context(datetime(2026, 12, 31, 16, 0, 0, tzinfo=timezone.utc))
        self.assertEqual(before["date"], "2026-12-31")
        self.assertEqual(after["date"], "2027-01-01")
        self.assertEqual(before["day_end"], after["day_start"])
        self.assertEqual(after["day_start"], "2027-01-01T00:00:00+08:00")

    def test_naive_test_clock_is_rejected(self):
        with self.assertRaises(ValueError):
            day_context(datetime(2026, 1, 1))


class IdentityHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="stairclimb-test-")
        self.database = Database()
        self.now = datetime(2026, 11, 14, 10, 30, tzinfo=timezone.utc)
        self.start_server()

    def start_server(self):
        self.server = RustServer(self.database, clock=lambda: self.now)
        self.port = self.server.server_port

    def stop_server(self):
        self.server.close()
        self.assertIsNotNone(self.server.process.poll())

    def tearDown(self):
        self.stop_server()
        self.database.close()
        self.temporary.cleanup()

    def request(self, method, path, body=None, token=None, raw=None, headers=None):
        self.server.set_time(self.now)
        request_headers = dict(headers or {})
        if token is not None:
            request_headers["Authorization"] = f"Bearer {token}"
        if body is not None:
            raw = json.dumps(body).encode("utf-8")
        if raw is not None:
            request_headers.setdefault("Content-Type", "application/json")
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            conn.request(method, path, body=raw, headers=request_headers)
            response = conn.getresponse()
            payload = response.read()
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            self.assertEqual(response.getheader("Content-Type"), "application/json; charset=utf-8")
            return response.status, json.loads(payload)
        finally:
            conn.close()

    def register(self, name="小楼"):
        status, result = self.request("POST", "/v1/users", {"nickname": name})
        self.assertEqual(status, 201)
        self.assertFalse(result["user"]["sharing_enabled"])
        self.assertEqual(result["user"]["consent_revision"], 0)
        self.assertTrue(len(result["token"]) == 43)
        return result

    def assert_error(self, response, status, code):
        actual_status, body = response
        self.assertEqual(actual_status, status)
        self.assertEqual(body["error"]["code"], code)
        self.assertNotIn("Traceback", json.dumps(body))
        return body

    def test_health_has_authoritative_rule_and_date(self):
        status, body = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["date"], "2026-11-14")
        self.assertEqual(body["timezone"], "Asia/Shanghai")
        self.assertEqual(body["steps_per_floor"], 100)
        self.assertEqual(body["max_steps"], MAX_STEPS)

    def test_registration_and_two_independent_profiles(self):
        first = self.register("  小楼  ")
        second = self.register("同行者")
        self.assertNotEqual(first["user"]["id"], second["user"]["id"])
        for result, expected in [(first, "小楼"), (second, "同行者")]:
            status, profile = self.request("GET", "/v1/me", token=result["token"])
            self.assertEqual(status, 200)
            self.assertEqual(profile["user"]["nickname"], expected)
            self.assertEqual(profile["user"]["id"], result["user"]["id"])
            self.assertNotIn("token", profile)
            self.assertNotIn("token_hash", profile["user"])

    def test_authentication_missing_forged_and_malformed_credentials(self):
        self.register()
        for token in [None, "x" * 43, "", "invalid", "a" * 1000]:
            with self.subTest(kind="missing" if token is None else "invalid"):
                self.assert_error(self.request("GET", "/v1/me", token=token), 401, "unauthorized")
        self.assert_error(self.request("GET", "/v1/me", headers={"Authorization": "Basic abc"}),
                          401, "unauthorized")

    def test_nickname_updates_only_authenticated_identity(self):
        first = self.register("A")
        second = self.register("B")
        status, result = self.request("PATCH", "/v1/me", {"nickname": " 新名字 ",}, first["token"])
        self.assertEqual(status, 200)
        self.assertEqual(result["user"]["nickname"], "新名字")
        self.assert_error(self.request("PATCH", "/v1/me", {
            "nickname": "被冒充", "user_id": second["user"]["id"],
        }, first["token"]), 422, "invalid_fields")
        self.assert_error(self.request("PATCH", f'/v1/users/{second["user"]["id"]}',
                                       {"nickname": "被冒充"}, first["token"]), 404, "not_found")
        _, profile = self.request("GET", "/v1/me", token=second["token"])
        self.assertEqual(profile["user"]["nickname"], "B")

    def test_nickname_rules_and_atomic_validation(self):
        first = self.register("原昵称")
        for name in ["", " \n\t", "a" * 25, "a\nb", "a\x00b", "a\u200bb", "a\u00a0b",
                     "a\ud800b", None, 123, True]:
            with self.subTest(kind=type(name).__name__):
                self.assert_error(self.request("PATCH", "/v1/me", {"nickname": name}, first["token"]),
                                  422, "invalid_nickname")
        _, result = self.request("GET", "/v1/me", token=first["token"])
        self.assertEqual(result["user"]["nickname"], "原昵称")
        # Exactly 24 code points, emoji and internal ordinary spaces are valid.
        self.assertEqual(self.request("PATCH", "/v1/me", {"nickname": "楼" * 24}, first["token"])[0], 200)
        self.assertEqual(self.request("PATCH", "/v1/me", {"nickname": "爬楼 🪜 1"}, first["token"])[0], 200)

    def test_unauthenticated_writes_do_not_change_identity_or_consent(self):
        first = self.register("保持原名")
        for token in [None, "f" * 43]:
            self.assert_error(self.request("PATCH", "/v1/me", {"nickname": "篡改"}, token),
                              401, "unauthorized")
            self.assert_error(self.request("PUT", "/v1/me/sharing", {
                "enabled": True, "expected_revision": 0,
            }, token), 401, "unauthorized")
        _, profile = self.request("GET", "/v1/me", token=first["token"])
        self.assertEqual(profile["user"]["nickname"], "保持原名")
        self.assertFalse(profile["user"]["sharing_enabled"])
        self.assertEqual(profile["user"]["consent_revision"], 0)

    def test_consent_explicit_versioned_and_revoke_resists_old_enable(self):
        first = self.register()
        token = first["token"]
        status, consent = self.request("PUT", "/v1/me/sharing", {
            "enabled": True, "expected_revision": 0,
        }, token)
        self.assertEqual(status, 200)
        self.assertTrue(consent["user"]["sharing_enabled"])
        self.assertEqual(consent["user"]["consent_revision"], 1)
        status, same = self.request("PUT", "/v1/me/sharing", {
            "enabled": True, "expected_revision": 1,
        }, token)
        self.assertEqual(status, 200)
        self.assertEqual(same["user"]["consent_revision"], 1)
        status, revoked = self.request("PUT", "/v1/me/sharing", {
            "enabled": False, "expected_revision": 1,
        }, token)
        self.assertEqual(status, 200)
        self.assertFalse(revoked["user"]["sharing_enabled"])
        self.assertEqual(revoked["user"]["consent_revision"], 2)
        self.assert_error(self.request("PUT", "/v1/me/sharing", {
            "enabled": True, "expected_revision": 0,
        }, token), 409, "consent_changed")
        _, profile = self.request("GET", "/v1/me", token=token)
        self.assertFalse(profile["user"]["sharing_enabled"])

    def test_consent_cannot_target_another_user_or_coerce_types(self):
        first, second = self.register("A"), self.register("B")
        invalid = [({"enabled": "true", "expected_revision": 0}, "invalid_sharing"),
                   ({"enabled": 1, "expected_revision": 0}, "invalid_sharing"),
                   ({"enabled": True, "expected_revision": False}, "invalid_revision"),
                   ({"enabled": True, "expected_revision": -1}, "invalid_revision"),
                   ({"enabled": True, "expected_revision": 0, "user_id": second["user"]["id"]},
                    "invalid_fields")]
        for body, code in invalid:
            self.assert_error(self.request("PUT", "/v1/me/sharing", body, first["token"]), 422, code)
        _, profile = self.request("GET", "/v1/me", token=second["token"])
        self.assertFalse(profile["user"]["sharing_enabled"])

    def test_close_before_delayed_enable_creates_persistent_version_barrier(self):
        token = self.register()["token"]
        # An earlier enable/rev0 is still in flight when close/rev0 arrives first.
        status, closed = self.request("PUT", "/v1/me/sharing", {
            "enabled": False, "expected_revision": 0,
        }, token)
        self.assertEqual(status, 200)
        self.assertFalse(closed["user"]["sharing_enabled"])
        self.assertGreater(closed["user"]["consent_revision"], 0)
        for restart in [False, True]:
            with self.subTest(restart=restart):
                if restart:
                    self.stop_server()
                    self.start_server()
                self.assert_error(self.request("PUT", "/v1/me/sharing", {
                    "enabled": True, "expected_revision": 0,
                }, token), 409, "consent_changed")
                status, profile = self.request("GET", "/v1/me", token=token)
                self.assertEqual(status, 200)
                self.assertFalse(profile["user"]["sharing_enabled"])
                self.assertEqual(profile["user"]["consent_revision"], closed["user"]["consent_revision"])
        # Another successful close creates a new barrier even while already closed.
        status, closed_again = self.request("PUT", "/v1/me/sharing", {
            "enabled": False, "expected_revision": closed["user"]["consent_revision"],
        }, token)
        self.assertEqual(status, 200)
        self.assertGreater(closed_again["user"]["consent_revision"], closed["user"]["consent_revision"])
        self.assert_error(self.request("PUT", "/v1/me/sharing", {
            "enabled": True, "expected_revision": closed["user"]["consent_revision"],
        }, token), 409, "consent_changed")

    def test_concurrent_consent_changes_are_serialized(self):
        token = self.register()["token"]
        def enable(_):
            return self.request("PUT", "/v1/me/sharing", {"enabled": True, "expected_revision": 0}, token)[0]
        with ThreadPoolExecutor(max_workers=4) as pool:
            statuses = list(pool.map(enable, range(4)))
        self.assertEqual(statuses.count(200), 1)
        self.assertEqual(statuses.count(409), 3)

    def test_invalid_json_and_unknown_fields_are_rejected(self):
        for raw in [b'{', b'[]', b'null', b'{"nickname":NaN}', b'{"nickname":"A","nickname":"B"}',
                    b'{"nickname":"\xff"}', b'{"nickname":Infinity}']:
            self.assert_error(self.request("POST", "/v1/users", raw=raw), 400, "invalid_json")
        for body in [{}, {"nickname": "A", "sharing_enabled": True},
                     {"nickname": "A", "token": "forged"}, {"nickname": "A", "id": "forged"}]:
            self.assert_error(self.request("POST", "/v1/users", body), 422, "invalid_fields")
        with self.database.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM users").fetchone()[0], 0)

    def test_body_limits_content_type_and_transfer_encoding(self):
        self.assert_error(self.request("POST", "/v1/users", raw=b"x" * (MAX_BODY_BYTES + 1)),
                          413, "body_too_large")
        self.assert_error(self.request("POST", "/v1/users", raw=b'{}',
                                       headers={"Content-Type": "text/plain"}), 415, "json_required")
        self.assert_error(self.request("POST", "/v1/users", raw=b'{}',
                                       headers={"Transfer-Encoding": "chunked"}), 400, "invalid_body")
        self.assert_error(self.request("POST", "/v1/users", raw=b'{}',
                                       headers={"Content-Length": "-1"}), 400, "invalid_body")
        self.assert_error(self.request("POST", "/v1/users", raw=b'{}',
                                       headers={"Content-Length": "9" * 100}), 413, "body_too_large")

    def test_no_query_identity_and_errors_are_json(self):
        self.assert_error(self.request("GET", "/v1/me?user_id=forged"), 400, "invalid_query")
        self.assert_error(self.request("GET", "/missing"), 404, "not_found")
        self.assert_error(self.request("POST", "/health", {}), 405, "method_not_allowed")

    def test_missing_and_duplicate_content_lengths(self):
        for lengths, expected_status, expected_code in [([], 411, "length_required"),
                                                         (["2", "2"], 400, "invalid_body")]:
            conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
            try:
                conn.putrequest("POST", "/v1/users")
                conn.putheader("Content-Type", "application/json")
                for value in lengths:
                    conn.putheader("Content-Length", value)
                conn.endheaders()
                response = conn.getresponse()
                self.assertEqual(response.status, expected_status)
                self.assertEqual(json.loads(response.read())["error"]["code"], expected_code)
            finally:
                conn.close()

    def test_storage_failure_is_service_unavailable_without_details(self):
        first = self.register()
        with self.database.outage():
            body = self.assert_error(self.request("GET", "/v1/me", token=first["token"]),
                                     503, "storage_unavailable")
            self.assertNotIn(str(self.database), json.dumps(body))
            self.assertNotIn("postgres", json.dumps(body))
        self.assertEqual(self.request("GET", "/v1/me", token=first["token"])[0], 200)

    def test_restart_preserves_auth_nickname_and_revoked_consent(self):
        first, second = self.register("A"), self.register("B")
        self.request("PATCH", "/v1/me", {"nickname": "重启以后"}, first["token"])
        for user in (first, second):
            self.request("PUT", "/v1/me/sharing", {"enabled": True, "expected_revision": 0}, user["token"])
        self.request("PUT", "/v1/me/sharing", {"enabled": False, "expected_revision": 1}, first["token"])
        self.stop_server()
        self.start_server()
        status, profile = self.request("GET", "/v1/me", token=first["token"])
        self.assertEqual(status, 200)
        self.assertEqual(profile["user"]["nickname"], "重启以后")
        self.assertEqual(profile["user"]["consent_revision"], 2)
        self.assertFalse(profile["user"]["sharing_enabled"])
        status, profile = self.request("GET", "/v1/me", token=second["token"])
        self.assertEqual(status, 200)
        self.assertTrue(profile["user"]["sharing_enabled"])
        self.assertEqual(profile["user"]["consent_revision"], 1)

    def test_credentials_are_hashed_in_database_and_not_logged(self):
        output = io.StringIO()
        with redirect_stderr(output):
            first = self.register()
            self.request("GET", "/v1/me", token=first["token"])
            self.request("GET", "/missing", token=first["token"])
        self.assertFalse(bool(output.getvalue()), "HTTP server unexpectedly logged a request")
        with self.database.connect() as db:
            digest = db.execute("SELECT token_hash FROM users").fetchone()[0]
        self.assertTrue(digest == hashlib.sha256(first["token"].encode()).hexdigest())
        self.assertTrue(digest != first["token"])
        # Dump the actual isolated PostgreSQL schema; inspect without logging it.
        from scripts import postgres_dev as pg
        dump = pg.run(['docker', 'exec', '-u', 'postgres', pg.NAME, 'pg_dump', '-d', 'stairclimb',
                       '--schema', self.database.schema, '--data-only'])
        self.assertNotIn(first["token"], dump, "Raw credential persisted")
        self.assertNotIn(first["token"], self.server.log_path.read_text())


if __name__ == "__main__":
    unittest.main()
