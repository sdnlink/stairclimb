"""Transactional identity, consent, daily snapshots and consistent leaderboard reads."""

from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import secrets
import sqlite3
import uuid

from .domain import (APIError, circle_cursor, circle_for_steps, current_date, day_context,
                     nickname, page_cursor, progress, read_circle_cursor, read_cursor, revision)


class Store:
    def __init__(self, path):
        self.path = Path(path).resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode = WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY,
                    token_hash TEXT NOT NULL UNIQUE,
                    nickname TEXT NOT NULL,
                    sharing_enabled INTEGER NOT NULL DEFAULT 0 CHECK(sharing_enabled IN (0, 1)),
                    consent_revision INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value INTEGER NOT NULL
                );
                INSERT OR IGNORE INTO metadata(key, value) VALUES ('leaderboard_revision', 0);
                CREATE TABLE IF NOT EXISTS daily_steps (
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    date TEXT NOT NULL,
                    steps INTEGER NOT NULL CHECK(steps BETWEEN 0 AND 1000000),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(user_id, date)
                );
                CREATE TABLE IF NOT EXISTS circle_participation (
                    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                    enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0, 1))
                );
            """)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
        try:
            yield db
        finally:
            db.close()

    @contextmanager
    def transaction(self, write=True):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            try:
                yield db
                db.execute("COMMIT")
            except BaseException:
                db.execute("ROLLBACK")
                raise

    @staticmethod
    def public_user(row):
        return {
            "id": row["id"],
            "nickname": row["nickname"],
            "sharing_enabled": bool(row["sharing_enabled"]),
            "consent_revision": row["consent_revision"],
        }

    @staticmethod
    def authenticate(db, authorization):
        if not isinstance(authorization, str) or not re.fullmatch(
            r"Bearer [A-Za-z0-9_-]{43}", authorization
        ):
            raise APIError(401, "unauthorized", "身份凭证无效，请检查本机身份")
        digest = hashlib.sha256(authorization[7:].encode("ascii")).hexdigest()
        row = db.execute("SELECT * FROM users WHERE token_hash = ?", (digest,)).fetchone()
        if row is None:
            raise APIError(401, "unauthorized", "身份凭证无效，请检查本机身份")
        return row

    @staticmethod
    def invalidate_leaderboard(db):
        db.execute("UPDATE metadata SET value = value + 1 WHERE key = 'leaderboard_revision'")

    def register(self, name, now):
        name = nickname(name)
        token = secrets.token_urlsafe(32)
        user_id = uuid.uuid4().hex
        digest = hashlib.sha256(token.encode("ascii")).hexdigest()
        with self.transaction() as db:
            db.execute(
                "INSERT INTO users(id, token_hash, nickname, created_at) VALUES (?, ?, ?, ?)",
                (user_id, digest, name, now.isoformat()),
            )
            row = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        return {"user": self.public_user(row), "token": token}

    def profile(self, authorization):
        with self.connect() as db:
            return self.public_user(self.authenticate(db, authorization))

    def rename(self, authorization, name):
        name = nickname(name)
        with self.transaction() as db:
            row = self.authenticate(db, authorization)
            if row["nickname"] != name:
                db.execute("UPDATE users SET nickname = ? WHERE id = ?", (name, row["id"]))
                self.invalidate_leaderboard(db)
            result = dict(row)
            result["nickname"] = name
        return self.public_user(result)

    @staticmethod
    def check_consent(row, expected_revision, require_sharing=False):
        if row["consent_revision"] != expected_revision:
            raise APIError(409, "consent_changed", "共享状态已变化，请重新读取本人资料")
        if require_sharing and not row["sharing_enabled"]:
            raise APIError(403, "sharing_required", "请先主动同意共享后再同步")

    def sync_steps(self, authorization, date, steps, expected_revision, clock):
        result = progress(steps)
        revision(expected_revision)
        with self.transaction() as db:
            row = self.authenticate(db, authorization)
            self.check_consent(row, expected_revision, require_sharing=True)
            # Sample after acquiring the write lock: a request queued over midnight
            # must not accept yesterday's health query as today's steps.
            now = clock()
            context = day_context(now)
            current_date(date, context)
            previous = db.execute("SELECT * FROM daily_steps WHERE user_id = ? AND date = ?",
                                  (row["id"], date)).fetchone()
            if previous is None or previous["steps"] != steps:
                updated_at = now.isoformat()
                db.execute("""
                    INSERT INTO daily_steps(user_id, date, steps, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(user_id, date) DO UPDATE SET
                        steps = excluded.steps, updated_at = excluded.updated_at
                """, (row["id"], date, steps, updated_at))
                self.invalidate_leaderboard(db)
            else:
                updated_at = previous["updated_at"]
        return {"progress": {**result, "synced": True, "updated_at": updated_at},
                "consent_revision": row["consent_revision"], **context}

    def today_steps(self, authorization, clock):
        with self.transaction(write=False) as db:
            row = self.authenticate(db, authorization)
            context = day_context(clock())
            saved = db.execute("SELECT * FROM daily_steps WHERE user_id = ? AND date = ?",
                               (row["id"], context["date"])).fetchone()
        return {"progress": {**progress(saved["steps"] if saved else 0),
                             "synced": saved is not None,
                             "updated_at": saved["updated_at"] if saved else None},
                "consent_revision": row["consent_revision"], **context}

    def delete_steps(self, authorization, expected_revision):
        revision(expected_revision)
        with self.transaction() as db:
            row = self.authenticate(db, authorization)
            self.check_consent(row, expected_revision)
            deleted = db.execute("DELETE FROM daily_steps WHERE user_id = ?", (row["id"],)).rowcount
            # A deletion is a persistent barrier against uploads already in flight.
            # The amended privacy rule closes both uploads and circle auto-joining.
            db.execute("UPDATE users SET sharing_enabled = 0, consent_revision = consent_revision + 1 WHERE id = ?",
                       (row["id"],))
            db.execute("DELETE FROM circle_participation WHERE user_id = ?", (row["id"],))
            self.invalidate_leaderboard(db)
            user = db.execute("SELECT * FROM users WHERE id = ?", (row["id"],)).fetchone()
        return {"deleted_days": deleted, "user": self.public_user(user)}

    def delete_account(self, authorization, expected_revision):
        revision(expected_revision)
        with self.transaction() as db:
            row = self.authenticate(db, authorization)
            self.check_consent(row, expected_revision)
            db.execute("DELETE FROM users WHERE id = ?", (row["id"],))
            self.invalidate_leaderboard(db)
        return {"deleted": True}

    # Both rank and position are computed over all currently sharing users before
    # filtering or pagination. Zero includes accounts with no record for this day.
    RANKED_SQL = """
        WITH visible AS (
            SELECT u.id AS user_id, u.nickname, COALESCE(s.steps, 0) AS steps
            FROM users u LEFT JOIN daily_steps s ON s.user_id = u.id AND s.date = ?
            WHERE u.sharing_enabled = 1
        ), ranked AS (
            SELECT *, RANK() OVER (ORDER BY steps DESC) AS rank,
                ROW_NUMBER() OVER (ORDER BY steps DESC, user_id ASC) AS position
            FROM visible
        ) SELECT * FROM ranked
    """

    @staticmethod
    def leaderboard_entry(row, viewer_id):
        return {"user_id": row["user_id"], "nickname": row["nickname"],
                **progress(row["steps"]), "rank": row["rank"], "position": row["position"],
                "is_me": row["user_id"] == viewer_id}

    def leaderboard(self, authorization, limit, cursor, clock, locate=False, snapshot=None):
        # Auth, version, count and window results share one SQLite read snapshot.
        with self.transaction(write=False) as db:
            viewer = self.authenticate(db, authorization)
            context = day_context(clock())
            version = db.execute("SELECT value FROM metadata WHERE key = 'leaderboard_revision'").fetchone()[0]
            current_snapshot = f'{context["date"]}.{version}'
            if snapshot is not None and snapshot != current_snapshot:
                raise APIError(409, "leaderboard_changed", "日期或排行榜已变化，请从首页刷新")
            total = db.execute("SELECT COUNT(*) FROM users WHERE sharing_enabled = 1").fetchone()[0]
            common = {"snapshot": current_snapshot, "total": total, "limit": limit, **context}
            if locate:
                row = db.execute(self.RANKED_SQL + " WHERE user_id = ?",
                                 (context["date"], viewer["id"])).fetchone()
                offset = ((row["position"] - 1) // limit) * limit if row else None
                return {**common, "entry": self.leaderboard_entry(row, viewer["id"]) if row else None,
                        "page_cursor": page_cursor(current_snapshot, offset, limit) if row else None}
            offset = read_cursor(cursor, current_snapshot, limit) if cursor is not None else 0
            if offset and offset >= total:
                raise APIError(422, "invalid_cursor", "分页位置无效，请从首页刷新")
            rows = db.execute(self.RANKED_SQL + " ORDER BY position LIMIT ? OFFSET ?",
                              (context["date"], limit, offset)).fetchall()
            next_offset = offset + len(rows)
            return {**common, "items": [self.leaderboard_entry(row, viewer["id"]) for row in rows],
                    "next_cursor": page_cursor(current_snapshot, next_offset, limit)
                    if next_offset < total else None}

    def sharing(self, authorization, enabled, expected_revision):
        if type(enabled) is not bool:
            raise APIError(422, "invalid_sharing", "共享开关必须为布尔值")
        revision(expected_revision)
        with self.transaction() as db:
            row = self.authenticate(db, authorization)
            if row["consent_revision"] != expected_revision:
                raise APIError(409, "consent_changed", "共享状态已变化，请重新读取本人资料")
            result = dict(row)
            # Every successful close invalidates earlier queued enables, even if
            # the account is already closed and the enable has not arrived yet.
            if not enabled or bool(row["sharing_enabled"]) != enabled:
                result["sharing_enabled"] = enabled
                result["consent_revision"] += 1
                db.execute(
                    "UPDATE users SET sharing_enabled = ?, consent_revision = ? WHERE id = ?",
                    (int(enabled), result["consent_revision"], row["id"]),
                )
                if not enabled:
                    db.execute("DELETE FROM circle_participation WHERE user_id = ?", (row["id"],))
                self.invalidate_leaderboard(db)
        return self.public_user(result)

    def circle_participation(self, authorization, enabled=None, expected_revision=None, update=False):
        if update:
            if type(enabled) is not bool:
                raise APIError(422, "invalid_participation", "圈子参与开关必须为布尔值")
            revision(expected_revision)
        with self.transaction(write=update) as db:
            user = self.authenticate(db, authorization)
            stored = db.execute("SELECT enabled FROM circle_participation WHERE user_id = ?",
                                (user["id"],)).fetchone()
            participating = bool(stored and stored["enabled"] and user["sharing_enabled"])
            if update:
                self.check_consent(user, expected_revision, require_sharing=enabled)
                # Every disable is a barrier, including disabling before a delayed
                # grant arrives. Repeated current-version enables are idempotent.
                if not enabled or enabled != participating:
                    db.execute("""INSERT INTO circle_participation(user_id, enabled) VALUES (?, ?)
                               ON CONFLICT(user_id) DO UPDATE SET enabled = excluded.enabled""",
                               (user["id"], int(enabled)))
                    db.execute("""UPDATE users SET sharing_enabled = ?, consent_revision = consent_revision + 1
                               WHERE id = ?""", (int(enabled), user["id"]))
                    self.invalidate_leaderboard(db)
                    user = db.execute("SELECT * FROM users WHERE id = ?", (user["id"],)).fetchone()
                participating = enabled
        return {"participating": participating, "user": self.public_user(user)}

    CIRCLE_SQL = """
        WITH visible AS (
            SELECT u.id AS user_id, u.nickname, COALESCE(s.steps, 0) AS steps
            FROM users u JOIN circle_participation p ON p.user_id = u.id AND p.enabled = 1
            LEFT JOIN daily_steps s ON s.user_id = u.id AND s.date = ?
            WHERE u.sharing_enabled = 1
        ), members AS (
            SELECT *, ROW_NUMBER() OVER (ORDER BY steps DESC, user_id ASC) AS position
            FROM visible WHERE steps BETWEEN ? AND ?
        ) SELECT * FROM members
    """

    @staticmethod
    def circle_entry(row, viewer_id):
        return {"user_id": row["user_id"], "nickname": row["nickname"],
                **progress(row["steps"]), "position": row["position"],
                "is_me": row["user_id"] == viewer_id}

    def current_circle(self, authorization, limit, cursor, clock, mode="summary", snapshot=None):
        with self.transaction(write=False) as db:
            viewer = self.authenticate(db, authorization)
            context = day_context(clock())
            version = db.execute("SELECT value FROM metadata WHERE key = 'leaderboard_revision'").fetchone()[0]
            current_snapshot = f'{context["date"]}.{version}'
            if snapshot is not None and snapshot != current_snapshot:
                raise APIError(409, "circle_changed", "日期或圈友已变化，请刷新今日圈子")
            opted = db.execute("SELECT enabled FROM circle_participation WHERE user_id = ?",
                               (viewer["id"],)).fetchone()
            common = {"snapshot": current_snapshot, "limit": limit,
                      "consent_revision": viewer["consent_revision"], **context}
            if not (viewer["sharing_enabled"] and opted and opted["enabled"]):
                if cursor is not None:
                    raise APIError(409, "circle_changed", "当前未参加圈子，请清除旧成员列表")
                return {**common, "participating": False, "circle": None, "total": 0,
                        "entry": None, "page_cursor": None, "items": [], "next_cursor": None}
            saved = db.execute("SELECT steps FROM daily_steps WHERE user_id = ? AND date = ?",
                               (viewer["id"], context["date"])).fetchone()
            circle = circle_for_steps(context["date"], saved["steps"] if saved else 0)
            args = (context["date"], circle["min_steps"], circle["max_steps"])
            total = db.execute("SELECT COUNT(*) FROM (" + self.CIRCLE_SQL + ")", args).fetchone()[0]
            own = db.execute(self.CIRCLE_SQL + " WHERE user_id = ?", (*args, viewer["id"])).fetchone()
            common.update({"participating": True, "circle": circle, "total": total})
            if mode in ("summary", "locate"):
                offset = ((own["position"] - 1) // limit) * limit
                return {**common, "entry": self.circle_entry(own, viewer["id"]),
                        "page_cursor": circle_cursor(current_snapshot, circle["id"], offset, limit)}
            offset = read_circle_cursor(cursor, current_snapshot, circle["id"], limit) if cursor is not None else 0
            if offset and offset >= total:
                raise APIError(422, "invalid_cursor", "圈子分页位置无效，请刷新")
            rows = db.execute(self.CIRCLE_SQL + " ORDER BY position LIMIT ? OFFSET ?",
                              (*args, limit, offset)).fetchall()
            next_offset = offset + len(rows)
            return {**common, "items": [self.circle_entry(row, viewer["id"]) for row in rows],
                    "next_cursor": circle_cursor(current_snapshot, circle["id"], next_offset, limit)
                    if next_offset < total else None}
