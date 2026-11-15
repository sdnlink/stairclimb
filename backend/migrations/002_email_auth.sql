-- Additive migration: existing users, consent revisions and history are preserved.
CREATE TABLE IF NOT EXISTS email_accounts (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    verified BOOLEAN NOT NULL DEFAULT FALSE,
    legacy_binding BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE IF NOT EXISTS email_credentials (
    digest TEXT PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$'),
    user_id TEXT NOT NULL REFERENCES email_accounts(user_id) ON DELETE CASCADE,
    purpose TEXT NOT NULL CHECK (purpose IN ('verify','reset')),
    expires_at BIGINT NOT NULL,
    UNIQUE (user_id,purpose)
);
CREATE TABLE IF NOT EXISTS sessions (
    access_hash TEXT PRIMARY KEY CHECK (access_hash ~ '^[0-9a-f]{64}$'),
    refresh_hash TEXT NOT NULL UNIQUE CHECK (refresh_hash ~ '^[0-9a-f]{64}$'),
    user_id TEXT NOT NULL REFERENCES email_accounts(user_id) ON DELETE CASCADE,
    access_expires_at BIGINT NOT NULL,
    refresh_expires_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user_id ON sessions(user_id);
-- Only keyed digests, never email, source IP, password or credential plaintext.
CREATE TABLE IF NOT EXISTS auth_limits (
    key TEXT PRIMARY KEY,
    window_start BIGINT NOT NULL,
    hits INTEGER NOT NULL
);
INSERT INTO schema_migrations(version) VALUES (2) ON CONFLICT DO NOTHING;
