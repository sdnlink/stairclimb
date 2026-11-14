"""SQLite owns identity and consent; raw bearer credentials are never persisted."""

from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import secrets
import sqlite3
import uuid

from .domain import APIError, nickname, revision


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
    def transaction(self):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
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
                self.invalidate_leaderboard(db)
        return self.public_user(result)
