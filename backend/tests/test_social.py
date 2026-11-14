"""Social behavior through real HTTP, isolated clocks, databases and ephemeral ports."""

import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
import sqlite3
import threading
import unittest
from urllib.parse import urlencode

from backend.domain import MAX_STEPS, day_context
import backend.tests.test_identity as identity


class SocialHTTPTests(unittest.TestCase):
    # Reuse the verified HTTP fixture without inheriting/re-running identity tests.
    setUp = identity.IdentityHTTPTests.setUp
    start_server = identity.IdentityHTTPTests.start_server
    stop_server = identity.IdentityHTTPTests.stop_server
    tearDown = identity.IdentityHTTPTests.tearDown
    request = identity.IdentityHTTPTests.request
    register = identity.IdentityHTTPTests.register
    assert_error = identity.IdentityHTTPTests.assert_error

    def share(self, user, enabled=True, revision=0):
        status, result = self.request("PUT", "/v1/me/sharing", {
            "enabled": enabled, "expected_revision": revision,
        }, user["token"])
        self.assertEqual(status, 200)
        return result["user"]["consent_revision"]

    def sync(self, user, steps, revision=1, date=None):
        return self.request("PUT", "/v1/me/steps", {
            "date": date or day_context(self.now)["date"],
            "steps": steps, "expected_revision": revision,
        }, user["token"])

    def today(self, user):
        status, result = self.request("GET", "/v1/me/steps", token=user["token"])
        self.assertEqual(status, 200)
        return result

    def board(self, user, **params):
        path = "/v1/leaderboard" + ("?" + urlencode(params) if params else "")
        status, result = self.request("GET", path, token=user["token"])
        self.assertEqual(status, 200)
        return result

    def locate(self, user, **params):
        path = "/v1/leaderboard/me" + ("?" + urlencode(params) if params else "")
        status, result = self.request("GET", path, token=user["token"])
        self.assertEqual(status, 200)
        return result

    def test_two_users_snapshot_conversion_and_replacement(self):
        first, second = self.register("登楼者"), self.register("同行者")
        self.assert_error(self.sync(first, 100, revision=0), 403, "sharing_required")
        self.assertFalse(self.today(first)["progress"]["synced"])
        self.share(first)
        self.share(second)
        self.assertEqual(self.sync(second, 340)[0], 200)
        for steps, floor, remaining in [(0, 0, 100), (99, 0, 1), (100, 1, 100),
                                        (101, 1, 99), (MAX_STEPS, 10000, 100), (99, 0, 1)]:
            with self.subTest(steps=steps):
                status, result = self.sync(first, steps)
                self.assertEqual(status, 200)
                self.assertEqual(result["progress"]["steps"], steps)
                self.assertEqual(result["progress"]["floor"], floor)
                self.assertEqual(result["progress"]["remaining_steps"], remaining)
                self.assertEqual(self.today(first)["progress"], result["progress"])
                own = self.locate(first)["entry"]
                self.assertEqual((own["steps"], own["floor"]), (steps, floor))
        self.assertEqual(self.today(second)["progress"]["steps"], 340)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM daily_steps").fetchone()[0], 2)

    def test_duplicate_sync_does_not_add_change_timestamp_or_invalidate_pages(self):
        first, second = self.register("A"), self.register("B")
        for user in (first, second):
            self.share(user)
            self.assertEqual(self.sync(user, 101)[0], 200)
        original = self.today(first)
        page = self.board(first, limit=1)
        self.now += timedelta(seconds=10)
        status, repeated = self.sync(first, 101)
        self.assertEqual(status, 200)
        self.assertEqual(original["progress"], repeated["progress"])
        continuation = self.board(first, limit=1, cursor=page["next_cursor"])
        self.assertEqual(continuation["snapshot"], page["snapshot"])
        self.assertIsNone(continuation["next_cursor"])
        self.assertEqual(self.locate(first)["entry"]["steps"], 101)

    def test_invalid_steps_dates_revisions_fields_are_atomic(self):
        first, second = self.register("A"), self.register("B")
        self.share(first)
        self.assertEqual(self.sync(first, 321)[0], 200)
        valid = {"date": "2026-11-14", "steps": 444, "expected_revision": 1}
        cases = []
        for steps in [-1, MAX_STEPS + 1, True, False, 1.0, "100", None, [], {}]:
            cases.append(({**valid, "steps": steps}, 422, "invalid_steps"))
        for date in ["2026-2-01", "2026-02-30", "2026-13-01", "0000-01-01",
                     "2026-11-14T00:00:00+08:00", "", None, True, 20261114]:
            cases.append(({**valid, "date": date}, 422, "invalid_date"))
        for date in ["2026-11-13", "2026-11-15"]:
            cases.append(({**valid, "date": date}, 409, "day_changed"))
        for revision in [True, -1, 1.0, "1", None, 2**63]:
            cases.append(({**valid, "expected_revision": revision}, 422, "invalid_revision"))
        cases.append(({**valid, "expected_revision": 0}, 409, "consent_changed"))
        for extra in [{"floor": 99}, {"user_id": second["user"]["id"]},
                      {"samples": [{"steps": 1}]}, {"source": "iPhone"}, {"id": "forged"}]:
            cases.append(({**valid, **extra}, 422, "invalid_fields"))
        for missing in valid:
            cases.append(({key: value for key, value in valid.items() if key != missing},
                          422, "invalid_fields"))
        for body, status, code in cases:
            with self.subTest(body=body):
                self.assert_error(self.request("PUT", "/v1/me/steps", body, first["token"]), status, code)
        self.assert_error(self.request("PUT", "/v1/me/steps", token=first["token"],
                                       raw=b'{"steps":1,"steps":2}'), 400, "invalid_json")
        self.assertEqual(self.today(first)["progress"]["steps"], 321)
        self.assertFalse(self.today(second)["progress"]["synced"])

    def test_social_endpoints_authentication_and_cross_user_writes(self):
        first, second = self.register("A"), self.register("B")
        for user in (first, second):
            self.share(user)
            self.assertEqual(self.sync(user, 123)[0], 200)
        for token in [None, "f" * 43]:
            for method, path, body in [
                ("GET", "/v1/leaderboard", None), ("GET", "/v1/leaderboard/me", None),
                ("GET", "/v1/me/steps", None),
                ("PUT", "/v1/me/steps", {"date": "2026-11-14", "steps": 999, "expected_revision": 1}),
                ("DELETE", "/v1/me/steps", {"expected_revision": 1}),
                ("DELETE", "/v1/me", {"expected_revision": 1}),
            ]:
                with self.subTest(method=method, path=path, missing=token is None):
                    self.assert_error(self.request(method, path, body, token), 401, "unauthorized")
        for path in ("/v1/me/steps", "/v1/me"):
            self.assert_error(self.request("DELETE", path, {
                "expected_revision": 1, "user_id": second["user"]["id"],
            }, first["token"]), 422, "invalid_fields")
        self.assert_error(self.request("GET", "/v1/me/steps?user_id=forged", token=first["token"]),
                          400, "invalid_query")
        self.assert_error(self.request("PUT", f'/v1/users/{second["user"]["id"]}/steps',
                                       {"steps": 999}, first["token"]), 404, "not_found")
        for user in (first, second):
            self.assertEqual(self.today(user)["progress"]["steps"], 123)

    def test_full_pagination_ties_zero_users_and_nonfirst_page_self(self):
        users = [self.register(name) for name in ["领先", "并列甲", "并列乙", "未同步", "本人", "不公开"]]
        for user in users[:-1]:
            self.share(user)
        for user, steps in zip(users[:3], [500, 200, 200]):
            self.assertEqual(self.sync(user, steps)[0], 200)
        viewer = users[4]
        collected, cursor, snapshots = [], None, set()
        for page_number in range(3):
            params = {"limit": 2, **({"cursor": cursor} if cursor else {})}
            page = self.board(viewer, **params)
            self.assertEqual(page["total"], 5)
            snapshots.add(page["snapshot"])
            collected.extend(page["items"])
            cursor = page["next_cursor"]
            self.assertEqual(cursor is None, page_number == 2)
        expected = sorted(users[:-1], key=lambda user: (
            -({users[0]["user"]["id"]: 500, users[1]["user"]["id"]: 200,
               users[2]["user"]["id"]: 200}.get(user["user"]["id"], 0)), user["user"]["id"]))
        self.assertEqual([row["user_id"] for row in collected], [user["user"]["id"] for user in expected])
        self.assertEqual([row["rank"] for row in collected], [1, 2, 2, 4, 4])
        self.assertEqual([row["position"] for row in collected], [1, 2, 3, 4, 5])
        self.assertEqual([row["steps"] for row in collected], [500, 200, 200, 0, 0])
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(sum(row["is_me"] for row in collected), 1)
        own = self.locate(viewer, limit=2, snapshot=page["snapshot"])
        self.assertGreater(own["entry"]["position"], 2)
        located_page = self.board(viewer, limit=2, cursor=own["page_cursor"])
        self.assertIn(own["entry"], located_page["items"])
        self.assertEqual(own["entry"], next(row for row in collected if row["is_me"]))
        for row in collected:
            self.assertEqual(set(row), {"user_id", "nickname", "steps", "floor", "remaining_steps",
                                        "rank", "position", "is_me"})

    def test_nonsharing_viewer_empty_board_and_self_not_public(self):
        first, second = self.register("本地查看"), self.register("已共享")
        empty = self.board(first)
        self.assertEqual((empty["items"], empty["total"], empty["next_cursor"]), ([], 0, None))
        self.assertIsNone(self.locate(first)["entry"])
        self.share(second)
        public = self.board(first)
        self.assertEqual(public["total"], 1)
        self.assertFalse(public["items"][0]["is_me"])
        self.assertEqual((public["items"][0]["steps"], public["items"][0]["floor"]), (0, 0))
        self.assertIsNone(self.locate(first)["page_cursor"])

    def test_each_public_mutation_invalidates_continuation_and_locate(self):
        first, second, third = [self.register(name) for name in ["A", "B", "C"]]
        # Keep two public users after the stronger delete rule hides first.
        anchor = self.register("分页保留者")
        for user in (first, second, anchor):
            self.share(user)
            self.assertEqual(self.sync(user, 100)[0], 200)
        mutations = [
            lambda: self.sync(first, 200),
            lambda: self.request("PATCH", "/v1/me", {"nickname": "新昵称"}, first["token"]),
            lambda: (200, self.share(third)),
            lambda: self.request("DELETE", "/v1/me/steps", {"expected_revision": 1}, first["token"]),
            lambda: (200, self.share(third, False, 1)),
            lambda: self.request("DELETE", "/v1/me", {"expected_revision": 2}, third["token"]),
        ]
        for mutation in mutations:
            before = self.board(second, limit=1)
            self.assertIsNotNone(before["next_cursor"])
            self.assertEqual(mutation()[0], 200)
            self.assert_error(self.request("GET", "/v1/leaderboard?" + urlencode({
                "limit": 1, "cursor": before["next_cursor"],
            }), token=second["token"]), 409, "leaderboard_changed")
            self.assert_error(self.request("GET", "/v1/leaderboard/me?" + urlencode({
                "limit": 1, "snapshot": before["snapshot"],
            }), token=second["token"]), 409, "leaderboard_changed")
            self.assertNotEqual(self.board(second)["snapshot"], before["snapshot"])
        # Shared-data deletion now hides the account; the private name is kept.
        status, profile = self.request("GET", "/v1/me", token=first["token"])
        self.assertEqual(status, 200)
        self.assertEqual(profile["user"]["nickname"], "新昵称")
        self.assertIsNone(self.locate(first)["entry"])

    def test_invalid_paging_parameters_and_cursors(self):
        user = self.register()
        self.share(user)
        board = self.board(user)
        for limit in ["0", "101", "-1", "true", "1.0", "", "9" * 100]:
            self.assert_error(self.request("GET", "/v1/leaderboard?" + urlencode({"limit": limit}),
                                           token=user["token"]), 422, "invalid_limit")
        self.assertEqual(self.board(user, limit=100)["limit"], 100)
        for query in ["limit=1&limit=2", "user_id=forged", "limit", "cursor=x&snapshot=x",
                      "&".join(f"k{i}=1" for i in range(11))]:
            self.assert_error(self.request("GET", "/v1/leaderboard?" + query, token=user["token"]),
                              400, "invalid_query")
        def encode(value):
            return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
        invalid_cursors = ["", "!", "a", "a" * 257, encode({}), encode([board["snapshot"], 0]),
                           encode([board["snapshot"], -1, 20]), encode([board["snapshot"], True, 20]),
                           encode([board["snapshot"], "0", 20]), encode([board["snapshot"], 2**63, 20]),
                           encode([board["snapshot"], 0, 1]), encode(["bad", 0, 20]),
                           encode([board["snapshot"], 2, 20])]
        for cursor in invalid_cursors:
            with self.subTest(cursor=cursor):
                self.assert_error(self.request("GET", "/v1/leaderboard?" + urlencode({"cursor": cursor}),
                                               token=user["token"]), 422, "invalid_cursor")
        for snapshot in ["", "bad", "2026-11-14.-1", "2026-11-14." + "1" * 30]:
            self.assert_error(self.request("GET", "/v1/leaderboard/me?" + urlencode({"snapshot": snapshot}),
                                           token=user["token"]), 422, "invalid_snapshot")
        self.assert_error(self.request("GET", "/v1/leaderboard/me?snapshot=2026-11-13.0",
                                       token=user["token"]), 409, "leaderboard_changed")

    def test_shanghai_midnight_resets_board_and_rejects_old_day(self):
        self.now = datetime(2026, 12, 31, 15, 59, 59, tzinfo=timezone.utc)
        first, second = self.register("A"), self.register("B")
        for user, steps in [(first, 999), (second, 250)]:
            self.share(user)
            self.assertEqual(self.sync(user, steps)[0], 200)
        old = self.board(first, limit=1)
        self.now += timedelta(seconds=1)
        fresh = self.board(first)
        self.assertEqual(fresh["date"], "2027-01-01")
        self.assertEqual([row["steps"] for row in fresh["items"]], [0, 0])
        self.assertEqual([row["floor"] for row in fresh["items"]], [0, 0])
        self.assertFalse(self.today(first)["progress"]["synced"])
        error = self.assert_error(self.sync(first, 999, date="2026-12-31"), 409, "day_changed")
        self.assertEqual(error["date"], "2027-01-01")
        self.assert_error(self.request("GET", "/v1/leaderboard?" + urlencode({
            "limit": 1, "cursor": old["next_cursor"],
        }), token=first["token"]), 409, "leaderboard_changed")
        self.assertEqual(self.sync(first, 99)[0], 200)
        self.assertEqual(self.locate(first)["entry"]["steps"], 99)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM daily_steps").fetchone()[0], 3)

    def test_upload_waiting_for_write_lock_rechecks_date_after_midnight(self):
        self.now = datetime(2026, 11, 14, 15, 59, 59, tzinfo=timezone.utc)
        user = self.register()
        self.share(user)
        first_sample = threading.Event()
        def clock():
            sample = self.now
            first_sample.set()
            return sample
        self.server.application.clock = clock
        with sqlite3.connect(self.database) as blocker, ThreadPoolExecutor(max_workers=1) as pool:
            blocker.execute("BEGIN IMMEDIATE")
            future = pool.submit(self.sync, user, 900, 1, "2026-11-14")
            try:
                self.assertTrue(first_sample.wait(timeout=2))
                self.now += timedelta(seconds=1)
            finally:
                blocker.commit()
            self.assert_error(future.result(timeout=3), 409, "day_changed")
        self.assertFalse(self.today(user)["progress"]["synced"])

    def test_revocation_hides_record_blocks_replays_and_survives_restart(self):
        first, second = self.register("A"), self.register("B")
        for user in (first, second):
            self.share(user)
            self.assertEqual(self.sync(user, 500)[0], 200)
        self.share(first, False, 1)
        for restart in (False, True):
            if restart:
                self.stop_server()
                self.start_server()
            self.assertEqual(self.board(second)["total"], 1)
            self.assertIsNone(self.locate(first)["entry"])
            self.assert_error(self.sync(first, 900, revision=1), 409, "consent_changed")
            self.assert_error(self.sync(first, 900, revision=2), 403, "sharing_required")
            self.assert_error(self.request("PUT", "/v1/me/sharing", {
                "enabled": True, "expected_revision": 1,
            }, first["token"]), 409, "consent_changed")
            self.assertEqual(self.today(first)["progress"]["steps"], 500)
        # An explicit new grant may expose retained data; withdrawal is not deletion.
        self.share(first, True, 2)
        self.assertEqual(self.locate(first)["entry"]["steps"], 500)
        self.assert_error(self.sync(first, 1000, revision=1), 409, "consent_changed")
        self.assertEqual(self.sync(first, 101, revision=3)[0], 200)

    def test_delete_all_days_is_persistent_barrier_without_affecting_other_user(self):
        first, second = self.register("删除我的记录"), self.register("保留的用户")
        for user in (first, second):
            self.share(user)
            self.assertEqual(self.sync(user, 800)[0], 200)
        self.now += timedelta(days=1)
        for user in (first, second):
            self.assertEqual(self.sync(user, 999)[0], 200)
        status, deleted = self.request("DELETE", "/v1/me/steps", {"expected_revision": 1}, first["token"])
        self.assertEqual(status, 200)
        self.assertEqual(deleted["deleted_days"], 2)
        # The daily-circle amendment makes shared-data deletion stop uploads too.
        self.assertFalse(deleted["user"]["sharing_enabled"])
        self.assertEqual(deleted["user"]["consent_revision"], 2)
        for restart in (False, True):
            if restart:
                self.stop_server()
                self.start_server()
            self.assertFalse(self.today(first)["progress"]["synced"])
            self.assertEqual(self.today(second)["progress"]["steps"], 999)
            self.assert_error(self.sync(first, 1000, revision=1), 409, "consent_changed")
            self.assert_error(self.request("DELETE", "/v1/me/steps", {"expected_revision": 1},
                                           first["token"]), 409, "consent_changed")
            self.assertIsNone(self.locate(first)["entry"])
        self.now -= timedelta(days=1)
        self.assertFalse(self.today(first)["progress"]["synced"])
        self.assertEqual(self.today(second)["progress"]["steps"], 800)
        self.assert_error(self.sync(first, 50, revision=2), 403, "sharing_required")
        # Uploading again requires a new explicit sharing decision.
        self.share(first, True, 2)
        self.assertEqual(self.sync(first, 50, revision=3)[0], 200)

    def test_delete_steps_while_revoked_and_repeated_empty_delete(self):
        user = self.register()
        self.share(user)
        self.assertEqual(self.sync(user, 300)[0], 200)
        self.share(user, False, 1)
        for expected, count in [(2, 1), (3, 0)]:
            status, result = self.request("DELETE", "/v1/me/steps", {"expected_revision": expected}, user["token"])
            self.assertEqual(status, 200)
            self.assertEqual(result["deleted_days"], count)
            self.assertFalse(result["user"]["sharing_enabled"])
            self.assertEqual(result["user"]["consent_revision"], expected + 1)
        self.assert_error(self.request("PUT", "/v1/me/sharing", {
            "enabled": True, "expected_revision": 2,
        }, user["token"]), 409, "consent_changed")
        self.assertFalse(self.today(user)["progress"]["synced"])

    def test_account_delete_cascades_invalidates_token_and_cannot_revive_after_restart(self):
        first, second = self.register("A"), self.register("B")
        for user in (first, second):
            self.share(user)
            self.assertEqual(self.sync(user, 101)[0], 200)
        self.now += timedelta(days=1)
        self.assertEqual(self.sync(first, 999)[0], 200)
        self.assert_error(self.request("DELETE", "/v1/me", {"expected_revision": 0}, first["token"]),
                          409, "consent_changed")
        status, result = self.request("DELETE", "/v1/me", {"expected_revision": 1}, first["token"])
        self.assertEqual(status, 200)
        self.assertTrue(result["deleted"])
        for restart in (False, True):
            if restart:
                self.stop_server()
                self.start_server()
            for method, path, body in [
                ("GET", "/v1/me", None), ("GET", "/v1/leaderboard", None),
                ("PUT", "/v1/me/sharing", {"enabled": True, "expected_revision": 1}),
                ("PUT", "/v1/me/steps", {"date": "2026-11-15", "steps": 999, "expected_revision": 1}),
                ("DELETE", "/v1/me", {"expected_revision": 1}),
            ]:
                self.assert_error(self.request(method, path, body, first["token"]), 401, "unauthorized")
            self.assertEqual(self.board(second)["total"], 1)
            self.assertEqual(self.locate(second)["entry"]["user_id"], second["user"]["id"])
        self.now -= timedelta(days=1)
        self.assertEqual(self.today(second)["progress"]["steps"], 101)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM users").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM daily_steps").fetchone()[0], 1)
        replacement = self.register("A")
        self.assertNotEqual(replacement["user"]["id"], first["user"]["id"])

    def test_concurrent_duplicate_uploads_keep_one_snapshot(self):
        user = self.register()
        self.share(user)
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.sync(user, 234), range(8)))
        self.assertEqual([status for status, _ in results], [200] * 8)
        self.assertEqual(len({result["progress"]["updated_at"] for _, result in results}), 1)
        self.assertEqual(self.today(user)["progress"]["steps"], 234)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM daily_steps").fetchone()[0], 1)

    def test_concurrent_privacy_operations_win_over_inflight_uploads(self):
        for action in ["delete_steps", "revoke", "delete_account"]:
            with self.subTest(action=action):
                user = self.register(action)
                self.share(user)
                self.assertEqual(self.sync(user, 123)[0], 200)
                barrier = threading.Barrier(2)
                def upload():
                    barrier.wait(timeout=2)
                    return self.sync(user, 999)
                def privacy():
                    barrier.wait(timeout=2)
                    if action == "revoke":
                        return self.request("PUT", "/v1/me/sharing", {
                            "enabled": False, "expected_revision": 1,
                        }, user["token"])
                    path = "/v1/me/steps" if action == "delete_steps" else "/v1/me"
                    return self.request("DELETE", path, {"expected_revision": 1}, user["token"])
                with ThreadPoolExecutor(max_workers=2) as pool:
                    upload_future, privacy_future = pool.submit(upload), pool.submit(privacy)
                    uploaded, private = upload_future.result(timeout=4), privacy_future.result(timeout=4)
                self.assertEqual(private[0], 200)
                self.assertIn(uploaded[0], [200, 401] if action == "delete_account" else [200, 409])
                if action == "delete_steps":
                    self.assertFalse(self.today(user)["progress"]["synced"])
                    self.assert_error(self.sync(user, 999), 409, "consent_changed")
                elif action == "revoke":
                    self.assertIsNone(self.locate(user)["entry"])
                    self.assert_error(self.sync(user, 999), 409, "consent_changed")
                else:
                    self.assert_error(self.sync(user, 999), 401, "unauthorized")

    def test_restart_retains_daily_snapshots_names_and_pagination_version(self):
        first, second = self.register("A"), self.register("B")
        for user, steps in [(first, 100), (second, 250)]:
            self.share(user)
            self.assertEqual(self.sync(user, steps)[0], 200)
        self.request("PATCH", "/v1/me", {"nickname": "重启保留"}, first["token"])
        before = self.board(first, limit=1)
        self.stop_server()
        self.start_server()
        after = self.board(first, limit=1, cursor=before["next_cursor"])
        self.assertEqual(after["snapshot"], before["snapshot"])
        self.assertEqual(after["items"][0]["nickname"], "重启保留")
        self.assertTrue(after["items"][0]["is_me"])
        self.assertEqual(self.today(first)["progress"]["steps"], 100)
        self.assertEqual(self.today(second)["progress"]["steps"], 250)

    def test_existing_identity_schema_upgrades_without_resetting_consent(self):
        user = self.register("保留旧模块")
        self.share(user)
        self.stop_server()
        with sqlite3.connect(self.database) as db:
            # The accepted identity module has these same users/metadata tables,
            # but no daily_steps table. Simulate that exact additive upgrade.
            db.execute("DROP TABLE daily_steps")
        self.start_server()
        status, profile = self.request("GET", "/v1/me", token=user["token"])
        self.assertEqual(status, 200)
        self.assertEqual(profile["user"], {**user["user"], "sharing_enabled": True, "consent_revision": 1})
        self.assertFalse(self.today(user)["progress"]["synced"])
        self.assertEqual(self.sync(user, 101)[0], 200)
        self.assertEqual(self.locate(user)["entry"]["floor"], 1)

    def test_storage_outage_does_not_claim_successful_upload_or_delete(self):
        user = self.register()
        self.share(user)
        self.assertEqual(self.sync(user, 123)[0], 200)
        moved = self.database.with_suffix(".offline")
        self.database.rename(moved)
        self.database.mkdir()
        try:
            for method, path, body in [
                ("PUT", "/v1/me/steps", {"date": "2026-11-14", "steps": 999, "expected_revision": 1}),
                ("DELETE", "/v1/me/steps", {"expected_revision": 1}),
                ("DELETE", "/v1/me", {"expected_revision": 1}),
                ("GET", "/v1/leaderboard", None),
            ]:
                error = self.assert_error(self.request(method, path, body, user["token"]),
                                          503, "storage_unavailable")
                self.assertNotIn(str(self.database), json.dumps(error))
                self.assertNotIn("sqlite", json.dumps(error))
        finally:
            self.database.rmdir()
            moved.rename(self.database)
        self.assertEqual(self.today(user)["progress"]["steps"], 123)
        status, profile = self.request("GET", "/v1/me", token=user["token"])
        self.assertEqual(status, 200)
        self.assertEqual(profile["user"]["consent_revision"], 1)

    def test_never_shared_account_can_delete_and_clock_is_not_remotely_configurable(self):
        user = self.register()
        self.assert_error(self.request("PUT", "/v1/clock", {"date": "2020-01-01"}, user["token"]),
                          404, "not_found")
        self.assert_error(self.request("GET", "/v1/leaderboard?date=2020-01-01", token=user["token"]),
                          400, "invalid_query")
        status, result = self.request("DELETE", "/v1/me", {"expected_revision": 0}, user["token"])
        self.assertEqual(status, 200)
        self.assertTrue(result["deleted"])
        self.assert_error(self.request("GET", "/v1/me", token=user["token"]), 401, "unauthorized")


if __name__ == "__main__":
    unittest.main()
