"""Daily circles: actual HTTP, private consent and derived membership; no scheduler."""

import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
import sqlite3
import threading
import unittest
from urllib.parse import urlencode

from backend.domain import APIError, CIRCLE_BAND_STEPS, MAX_STEPS, circle_for_steps, day_context
import backend.tests.test_social as social


class CircleRulesTests(unittest.TestCase):
    def test_band_boundaries_and_stable_daily_channel(self):
        self.assertEqual(CIRCLE_BAND_STEPS, 1000)
        for steps, lower in [(0, 0), (99, 0), (999, 0), (1000, 1000), (1999, 1000),
                             (2000, 2000), (MAX_STEPS, MAX_STEPS)]:
            with self.subTest(steps=steps):
                value = circle_for_steps("2026-11-14", steps)
                self.assertEqual(value, {"id": f"2026-11-14:{lower}-{lower + 999}",
                                        "date": "2026-11-14", "min_steps": lower,
                                        "max_steps": lower + 999, "band_steps": 1000})
                self.assertEqual(value, circle_for_steps("2026-11-14", steps))
                self.assertNotEqual(value["id"], circle_for_steps("2026-11-15", steps)["id"])
        self.assertEqual(day_context(datetime.now(timezone.utc))["circle_band_steps"], 1000)
        for steps in [-1, MAX_STEPS + 1, True, 1.5, "1000"]:
            with self.assertRaises(APIError):
                circle_for_steps("2026-11-14", steps)


class CirclesHTTPTests(unittest.TestCase):
    # Do not subclass the old suites: fixed discovery must not repeat them.
    setUp = social.SocialHTTPTests.setUp
    start_server = social.SocialHTTPTests.start_server
    stop_server = social.SocialHTTPTests.stop_server
    tearDown = social.SocialHTTPTests.tearDown
    request = social.SocialHTTPTests.request
    register = social.SocialHTTPTests.register
    assert_error = social.SocialHTTPTests.assert_error
    share = social.SocialHTTPTests.share
    sync = social.SocialHTTPTests.sync
    today = social.SocialHTTPTests.today
    board = social.SocialHTTPTests.board

    def participate(self, user, enabled=True, revision=1):
        status, result = self.request("PUT", "/v1/me/circle-participation", {
            "enabled": enabled, "expected_revision": revision,
        }, user["token"])
        self.assertEqual(status, 200)
        self.assertEqual(result["participating"], enabled)
        return result["user"]["consent_revision"]

    def member(self, name, steps=None):
        user = self.register(name)
        self.share(user)
        self.assertEqual(self.participate(user), 2)
        if steps is not None:
            self.assertEqual(self.sync(user, steps, revision=2)[0], 200)
        return user

    def circle(self, user, suffix="", **params):
        url = "/v1/circles/current" + suffix + ("?" + urlencode(params) if params else "")
        status, result = self.request("GET", url, token=user["token"])
        self.assertEqual(status, 200)
        self.assertEqual(result["circle_band_steps"], 1000)
        return result

    def test_registration_and_old_sharing_never_imply_circle_consent(self):
        user = self.register("只用本地")
        for stage in ["local", "leaderboard_only"]:
            if stage == "leaderboard_only":
                self.share(user)
                self.assertEqual(self.sync(user, 999)[0], 200)
            status, participation = self.request("GET", "/v1/me/circle-participation", token=user["token"])
            self.assertEqual(status, 200)
            self.assertFalse(participation["participating"])
            for suffix in ["", "/members", "/me"]:
                result = self.circle(user, suffix)
                self.assertFalse(result["participating"])
                self.assertIsNone(result["circle"])
                self.assertEqual(result["total"], 0)
                self.assertEqual(result["items"], [])
                self.assertIsNone(result["entry"])
        self.assertEqual(self.board(user)["total"], 1)

    def test_explicit_participation_validation_and_no_cross_user_authority(self):
        first, second = self.register("A"), self.register("B")
        self.assert_error(self.request("PUT", "/v1/me/circle-participation", {
            "enabled": True, "expected_revision": 0,
        }, first["token"]), 403, "sharing_required")
        self.share(first)
        for enabled in [None, 1, "true", [], {}]:
            self.assert_error(self.request("PUT", "/v1/me/circle-participation", {
                "enabled": enabled, "expected_revision": 1,
            }, first["token"]), 422, "invalid_participation")
        for revision in [True, -1, None, "1", 1.0, 2**63]:
            self.assert_error(self.request("PUT", "/v1/me/circle-participation", {
                "enabled": True, "expected_revision": revision,
            }, first["token"]), 422, "invalid_revision")
        for body in [{"enabled": True}, {"enabled": True, "expected_revision": 1,
                                          "user_id": second["user"]["id"]},
                     {"enabled": True, "expected_revision": 1, "channel": "forged"}]:
            self.assert_error(self.request("PUT", "/v1/me/circle-participation", body, first["token"]),
                              422, "invalid_fields")
        self.assertEqual(self.participate(first), 2)
        self.assertEqual(self.participate(first, revision=2), 2)
        self.assertFalse(self.circle(second)["participating"])
        self.assertEqual(self.circle(first)["total"], 1)

    def test_same_band_same_channel_exact_steps_and_999_1000_boundary(self):
        users = [self.member(name, steps) for name, steps in
                 [("999甲", 999), ("999乙", 999), ("1000", 1000), ("1999", 1999),
                  ("2000", 2000), ("零值未同步", None)]]
        circles = [self.circle(user) for user in users]
        self.assertEqual(circles[0]["circle"], circles[1]["circle"])
        self.assertEqual(circles[2]["circle"], circles[3]["circle"])
        self.assertNotEqual(circles[1]["circle"]["id"], circles[2]["circle"]["id"])
        self.assertEqual(circles[0]["total"], 3)
        self.assertEqual(circles[2]["total"], 2)
        self.assertEqual(circles[4]["total"], 1)
        self.assertEqual(circles[5]["entry"]["steps"], 0)
        self.assertFalse(self.today(users[5])["progress"]["synced"])
        members = self.circle(users[0], "/members")["items"]
        self.assertEqual({entry["nickname"] for entry in members}, {"999甲", "999乙", "零值未同步"})
        self.assertEqual(sum(entry["is_me"] for entry in members), 1)
        self.assertEqual(members[0]["floor"], 9)
        self.assertEqual(set(members[0]), {"user_id", "nickname", "steps", "floor", "remaining_steps",
                                          "position", "is_me"})
        # One-person bands stay one-person; no synthetic or out-of-band members.
        self.assertEqual(len(self.circle(users[4], "/members")["items"]), 1)

    def test_sync_migrates_between_bands_and_cannot_leave_duplicate_members(self):
        moving, low, high = self.member("迁移", 999), self.member("低圈", 0), self.member("高圈", 1000)
        old = self.circle(moving)
        self.assertEqual(self.sync(moving, 1000, revision=2)[0], 200)
        self.assertNotEqual(self.circle(moving)["circle"]["id"], old["circle"]["id"])
        self.assertEqual(self.circle(low)["total"], 1)
        self.assertEqual(self.circle(high)["total"], 2)
        self.assertNotIn(moving["user"]["id"], [row["user_id"] for row in self.circle(low, "/members")["items"]])
        self.assertEqual(self.sync(moving, 0, revision=2)[0], 200)
        self.assertEqual(self.circle(low)["total"], 2)
        self.assertEqual(self.circle(high)["total"], 1)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM circle_participation WHERE enabled = 1").fetchone()[0], 3)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM daily_steps").fetchone()[0], 3)

    def test_three_pages_and_self_location_are_consistent(self):
        users = [self.member(f"圈友{index}", steps) for index, steps in enumerate([999, 800, 600, 400, 200, 1])]
        viewer = users[-1]
        collected, cursor = [], None
        original = self.circle(viewer)
        for index in range(3):
            page = self.circle(viewer, "/members", limit=2, **({"cursor": cursor} if cursor else {}))
            self.assertEqual(page["total"], 6)
            self.assertEqual(page["circle"], original["circle"])
            self.assertEqual(page["snapshot"], original["snapshot"])
            collected.extend(page["items"])
            cursor = page["next_cursor"]
            self.assertEqual(cursor is None, index == 2)
        self.assertEqual([entry["steps"] for entry in collected], [999, 800, 600, 400, 200, 1])
        self.assertEqual(len({entry["user_id"] for entry in collected}), 6)
        self.assertEqual([entry["position"] for entry in collected], list(range(1, 7)))
        own = self.circle(viewer, "/me", limit=2, snapshot=original["snapshot"])
        self.assertEqual(own["entry"]["position"], 6)
        located = self.circle(viewer, "/members", limit=2, cursor=own["page_cursor"])
        self.assertIn(own["entry"], located["items"])
        self.assertTrue(own["entry"]["is_me"])

    def test_duplicates_and_concurrent_syncs_do_not_drift_counts(self):
        user, low, high = self.member("并发", 500), self.member("低圈", 1), self.member("高圈", 1000)
        page = self.circle(low, "/members", limit=1)
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.sync(user, 500, revision=2), range(8)))
        self.assertEqual([status for status, _ in results], [200] * 8)
        next_page = self.circle(low, "/members", limit=1, cursor=page["next_cursor"])
        self.assertEqual(next_page["snapshot"], page["snapshot"])
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda steps: self.sync(user, steps, revision=2), [999, 1000, 1001, 998]))
        self.assertEqual([status for status, _ in results], [200] * 4)
        rows = self.circle(low, "/members")["items"] + self.circle(high, "/members")["items"]
        self.assertEqual(len(rows), 3)
        self.assertEqual(len({entry["user_id"] for entry in rows}), 3)
        self.assertEqual(sum(entry["user_id"] == user["user"]["id"] for entry in rows), 1)
        final = self.today(user)["progress"]["steps"]
        self.assertEqual(self.circle(user)["circle"]["min_steps"], (final // 1000) * 1000)

    def test_midnight_reassigns_without_writes_and_preserves_history(self):
        self.now = datetime(2026, 12, 31, 15, 59, 59, tzinfo=timezone.utc)
        first, second, third = self.member("A", 999), self.member("B", 1000), self.member("C", 999)
        old = self.circle(first, "/members", limit=1)
        old_rows = None
        with sqlite3.connect(self.database) as db:
            old_rows = db.execute("SELECT user_id,date,steps FROM daily_steps ORDER BY user_id").fetchall()
        self.now += timedelta(seconds=1)
        for user in [first, second, third]:
            fresh = self.circle(user)
            self.assertEqual(fresh["date"], "2027-01-01")
            self.assertEqual(fresh["circle"]["id"], "2027-01-01:0-999")
            self.assertEqual(fresh["total"], 3)
            self.assertEqual((fresh["entry"]["steps"], fresh["entry"]["floor"]), (0, 0))
        self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({
            "limit": 1, "cursor": old["next_cursor"],
        }), token=first["token"]), 409, "circle_changed")
        error = self.assert_error(self.sync(first, 999, revision=2, date="2026-12-31"), 409, "day_changed")
        self.assertEqual(error["date"], "2027-01-01")
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT user_id,date,steps FROM daily_steps ORDER BY user_id").fetchall(), old_rows)
        self.assertEqual(self.sync(second, 1000, revision=2)[0], 200)
        self.assertEqual(self.circle(first)["total"], 2)
        self.assertEqual(self.circle(second)["circle"]["id"], "2027-01-01:1000-1999")

    def test_cursor_bound_to_date_channel_version_and_page_size(self):
        first, second, high = self.member("A", 500), self.member("B", 100), self.member("C", 1000)
        page = self.circle(first, "/members", limit=1)
        # Same global version but a different channel: not a valid continuation.
        self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({
            "limit": 1, "cursor": page["next_cursor"],
        }), token=high["token"]), 409, "circle_changed")
        self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({
            "limit": 2, "cursor": page["next_cursor"],
        }), token=first["token"]), 422, "invalid_cursor")
        self.assertEqual(self.sync(first, 1001, revision=2)[0], 200)
        self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({
            "limit": 1, "cursor": page["next_cursor"],
        }), token=first["token"]), 409, "circle_changed")
        for suffix in ["", "/members", "/me"]:
            self.assert_error(self.request("GET", "/v1/circles/current" + suffix + "?" + urlencode({
                "snapshot": page["snapshot"],
            }), token=second["token"]), 409, "circle_changed")

    def test_all_member_changes_invalidate_pagination(self):
        first, second = self.member("A", 500), self.member("B", 100)
        third = self.register("C")
        self.share(third)
        operations = [
            lambda: self.request("PATCH", "/v1/me", {"nickname": "圈友改名"}, first["token"]),
            lambda: self.sync(first, 501, revision=2),
            lambda: (200, self.participate(third)),
            lambda: self.request("DELETE", "/v1/me/steps", {"expected_revision": 2}, third["token"]),
            lambda: self.request("DELETE", "/v1/me", {"expected_revision": 3}, third["token"]),
        ]
        for operation in operations:
            before = self.circle(second, "/members", limit=1)
            self.assertEqual(operation()[0], 200)
            self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({
                "limit": 1, "cursor": before["next_cursor"],
            }), token=second["token"]), 409, "circle_changed")
        self.assertEqual(self.circle(first)["entry"]["nickname"], "圈友改名")

    def test_revoke_clears_participation_and_old_grants_cannot_restore_after_restart(self):
        first, other = self.member("A", 500), self.member("B", 100)
        self.share(first, False, 2)
        for restarted in [False, True]:
            if restarted:
                self.stop_server()
                self.start_server()
            self.assertEqual(self.circle(other)["total"], 1)
            self.assertIsNone(self.circle(first)["circle"])
            self.assert_error(self.request("PUT", "/v1/me/circle-participation", {
                "enabled": True, "expected_revision": 2,
            }, first["token"]), 409, "consent_changed")
            self.assert_error(self.sync(first, 1000, revision=2), 409, "consent_changed")
            self.assert_error(self.sync(first, 1000, revision=3), 403, "sharing_required")
        self.share(first, True, 3)
        self.assertFalse(self.circle(first)["participating"])
        self.assertEqual(self.participate(first, revision=4), 5)
        self.assertEqual(self.circle(other)["total"], 2)

    def test_disable_before_delayed_enable_and_empty_disable_are_persistent_barriers(self):
        user = self.register()
        self.share(user)
        self.assertEqual(self.participate(user, False, 1), 2)
        self.assertEqual(self.participate(user, False, 2), 3)
        self.stop_server()
        self.start_server()
        for stale in [1, 2]:
            self.assert_error(self.request("PUT", "/v1/me/circle-participation", {
                "enabled": True, "expected_revision": stale,
            }, user["token"]), 409, "consent_changed")
        self.assert_error(self.sync(user, 1000, revision=3), 403, "sharing_required")
        self.assertFalse(self.circle(user)["participating"])

    def test_delete_all_shared_days_removes_member_and_stops_uploads_persistently(self):
        user, other = self.member("删除者", 500), self.member("保留者", 600)
        self.now += timedelta(days=1)
        self.assertEqual(self.sync(user, 999, revision=2)[0], 200)
        self.assertEqual(self.sync(other, 100, revision=2)[0], 200)
        status, deleted = self.request("DELETE", "/v1/me/steps", {"expected_revision": 2}, user["token"])
        self.assertEqual(status, 200)
        self.assertEqual(deleted["deleted_days"], 2)
        self.assertFalse(deleted["user"]["sharing_enabled"])
        self.stop_server()
        self.start_server()
        self.assertFalse(self.circle(user)["participating"])
        self.assertEqual(self.circle(other)["total"], 1)
        self.assert_error(self.sync(user, 888, revision=2), 409, "consent_changed")
        self.assert_error(self.sync(user, 888, revision=3), 403, "sharing_required")
        self.share(user, True, 3)
        self.assertFalse(self.circle(user)["participating"])
        self.assertEqual(self.circle(other)["total"], 1)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM daily_steps WHERE user_id = ?",
                                        (user["user"]["id"],)).fetchone()[0], 0)

    def test_account_deletion_cascades_circle_consent_and_rejects_old_token(self):
        first, other = self.member("删账号", 100), self.member("保留", 100)
        self.assertEqual(self.request("DELETE", "/v1/me", {"expected_revision": 2}, first["token"])[0], 200)
        self.stop_server()
        self.start_server()
        for method, path, body in [
            ("GET", "/v1/circles/current", None),
            ("GET", "/v1/me/circle-participation", None),
            ("PUT", "/v1/me/circle-participation", {"enabled": True, "expected_revision": 2}),
        ]:
            self.assert_error(self.request(method, path, body, first["token"]), 401, "unauthorized")
        self.assertEqual(self.circle(other)["total"], 1)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM circle_participation").fetchone()[0], 1)

    def test_concurrent_participation_upload_and_privacy_changes_are_serialized(self):
        for action in ["disable", "revoke", "delete_steps", "delete_account"]:
            with self.subTest(action=action):
                user, observer = self.member("竞态", 500), self.member("观察者", 500)
                barrier = threading.Barrier(3)
                def upload():
                    barrier.wait(timeout=3)
                    return self.sync(user, 1000, revision=2)
                def enable():
                    barrier.wait(timeout=3)
                    return self.request("PUT", "/v1/me/circle-participation", {
                        "enabled": True, "expected_revision": 2,
                    }, user["token"])
                def privacy():
                    barrier.wait(timeout=3)
                    if action in ("disable", "revoke"):
                        path = "/v1/me/circle-participation" if action == "disable" else "/v1/me/sharing"
                        return self.request("PUT", path, {"enabled": False, "expected_revision": 2}, user["token"])
                    path = "/v1/me/steps" if action == "delete_steps" else "/v1/me"
                    return self.request("DELETE", path, {"expected_revision": 2}, user["token"])
                with ThreadPoolExecutor(max_workers=3) as pool:
                    futures = [pool.submit(operation) for operation in (upload, enable, privacy)]
                    results = [future.result(timeout=5) for future in futures]
                self.assertEqual(results[2][0], 200)
                self.assertIn(results[0][0], [200, 401] if action == "delete_account" else [200, 409])
                self.assertIn(results[1][0], [200, 401] if action == "delete_account" else [200, 409])
                self.assertNotIn(user["user"]["id"], [row["user_id"] for row in self.circle(observer, "/members")["items"]])
                if action != "delete_account":
                    self.assertFalse(self.circle(user)["participating"])
                    self.assert_error(self.sync(user, 999, revision=3), 403, "sharing_required")

    def test_invalid_auth_query_and_cursor_inputs_never_expose_members(self):
        user = self.member("成员", 500)
        for token in [None, "f" * 43]:
            for suffix in ["", "/members", "/me"]:
                self.assert_error(self.request("GET", "/v1/circles/current" + suffix, token=token),
                                  401, "unauthorized")
            self.assert_error(self.request("PUT", "/v1/me/circle-participation", {
                "enabled": False, "expected_revision": 2,
            }, token), 401, "unauthorized")
        for query in ["date=2020-01-01", "user_id=forged", "channel=forged", "limit=1&limit=2"]:
            self.assert_error(self.request("GET", "/v1/circles/current/members?" + query, token=user["token"]),
                              400, "invalid_query")
        for limit in [0, 101, "true", "1.0", ""]:
            self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({"limit": limit}),
                                           token=user["token"]), 422, "invalid_limit")
        current = self.circle(user)
        def encode(value):
            return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
        for cursor in ["", "!", "a", "a" * 385, encode({}),
                       encode([current["snapshot"], current["circle"]["id"], True, 20]),
                       encode([current["snapshot"], current["circle"]["id"], 100, 20])]:
            self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({"cursor": cursor}),
                                           token=user["token"]), 422, "invalid_cursor")
        self.assertEqual(self.circle(user)["total"], 1)

    def test_restart_preserves_channel_consents_records_and_current_cursor(self):
        first, second = self.member("A", 500), self.member("B", 999)
        page = self.circle(first, "/members", limit=1)
        original = self.circle(first)
        self.stop_server()
        self.start_server()
        self.assertEqual(self.circle(first), original)
        after = self.circle(first, "/members", limit=1, cursor=page["next_cursor"])
        self.assertEqual(after["snapshot"], page["snapshot"])
        self.assertTrue(after["items"][0]["is_me"])
        self.assertEqual(self.circle(second)["circle"], original["circle"])

    def test_upgrade_old_shared_database_defaults_to_not_participating(self):
        user = self.register("旧共享身份")
        self.share(user)
        self.assertEqual(self.sync(user, 1000)[0], 200)
        self.stop_server()
        with sqlite3.connect(self.database) as db:
            db.execute("DROP TABLE circle_participation")
        self.start_server()
        self.assertFalse(self.circle(user)["participating"])
        self.assertEqual(self.today(user)["progress"]["steps"], 1000)
        self.assertEqual(self.board(user)["total"], 1)
        self.assertEqual(self.participate(user), 2)
        self.assertEqual(self.circle(user)["circle"]["min_steps"], 1000)

    def test_storage_failure_does_not_claim_join_or_exit_succeeded(self):
        user = self.member("暂时离线", 999)
        moved = self.database.with_suffix(".offline")
        self.database.rename(moved)
        self.database.mkdir()
        try:
            for method, url, body in [
                ("GET", "/v1/circles/current", None),
                ("GET", "/v1/circles/current/members", None),
                ("PUT", "/v1/me/circle-participation", {"enabled": False, "expected_revision": 2}),
            ]:
                error = self.assert_error(self.request(method, url, body, user["token"]),
                                          503, "storage_unavailable")
                self.assertNotIn(str(self.database), json.dumps(error))
        finally:
            self.database.rmdir()
            moved.rename(self.database)
        self.assertTrue(self.circle(user)["participating"])
        self.assertEqual(self.circle(user)["consent_revision"], 2)

    def test_pending_upload_over_midnight_cannot_move_into_new_day_channel(self):
        self.now = datetime(2026, 11, 14, 15, 59, 59, tzinfo=timezone.utc)
        user = self.member("跨日排队", 999)
        sampled = threading.Event()
        def clock():
            now = self.now
            sampled.set()
            return now
        self.server.application.clock = clock
        with sqlite3.connect(self.database) as blocker, ThreadPoolExecutor(max_workers=1) as pool:
            blocker.execute("BEGIN IMMEDIATE")
            pending = pool.submit(self.sync, user, 1000, 2, "2026-11-14")
            try:
                self.assertTrue(sampled.wait(timeout=2))
                self.now += timedelta(seconds=1)
            finally:
                blocker.commit()
            self.assert_error(pending.result(timeout=3), 409, "day_changed")
        fresh = self.circle(user)
        self.assertEqual(fresh["circle"]["id"], "2026-11-15:0-999")
        self.assertEqual(fresh["entry"]["steps"], 0)
        self.assertFalse(self.today(user)["progress"]["synced"])

    def test_revoked_viewer_cannot_continue_old_circle_page(self):
        user, other = self.member("A", 500), self.member("B", 100)
        page = self.circle(user, "/members", limit=1)
        self.participate(user, False, 2)
        self.assert_error(self.request("GET", "/v1/circles/current/members?" + urlencode({
            "limit": 1, "cursor": page["next_cursor"],
        }), token=user["token"]), 409, "circle_changed")
        self.assertEqual(self.circle(user, "/members")["items"], [])
        self.assertEqual(self.circle(other)["total"], 1)


if __name__ == "__main__":
    unittest.main()
