-- Version 1, PostgreSQL. Integer boolean fields preserve the reviewed export format.
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    nickname TEXT NOT NULL,
    sharing_enabled SMALLINT NOT NULL DEFAULT 0 CHECK (sharing_enabled IN (0,1)),
    consent_revision BIGINT NOT NULL DEFAULT 0 CHECK (consent_revision >= 0),
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value BIGINT NOT NULL CHECK (value >= 0)
);
INSERT INTO metadata (key,value) VALUES ('leaderboard_revision',0) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS daily_steps (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL CHECK (date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    steps BIGINT NOT NULL CHECK (steps BETWEEN 0 AND 1000000),
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id,date)
);
CREATE TABLE IF NOT EXISTS circle_participation (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    enabled SMALLINT NOT NULL DEFAULT 0 CHECK (enabled IN (0,1))
);
CREATE TABLE IF NOT EXISTS schema_migrations (
    version BIGINT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO schema_migrations(version) VALUES (1) ON CONFLICT DO NOTHING;
