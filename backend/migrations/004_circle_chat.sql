CREATE SEQUENCE IF NOT EXISTS circle_chat_changes;
CREATE TABLE IF NOT EXISTS circle_messages (
    id BIGSERIAL PRIMARY KEY,
    circle_id TEXT NOT NULL,
    author_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id UUID NOT NULL,
    text TEXT NOT NULL CHECK (char_length(text) <= 1000),
    reply_to BIGINT REFERENCES circle_messages(id) ON DELETE SET NULL,
    created_at BIGINT NOT NULL,
    deleted BOOLEAN NOT NULL DEFAULT false,
    change_id BIGINT NOT NULL DEFAULT nextval('circle_chat_changes'),
    UNIQUE(author_id,client_id)
);
CREATE INDEX IF NOT EXISTS circle_messages_page ON circle_messages(circle_id,id DESC);
CREATE INDEX IF NOT EXISTS circle_messages_changes ON circle_messages(circle_id,change_id);
CREATE INDEX IF NOT EXISTS circle_messages_rate ON circle_messages(author_id,created_at);
CREATE TABLE IF NOT EXISTS circle_blocks (
    blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY(blocker_id,blocked_id),
    CHECK(blocker_id<>blocked_id)
);
CREATE TABLE IF NOT EXISTS circle_reports (
    reporter_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message_id BIGINT NOT NULL REFERENCES circle_messages(id) ON DELETE CASCADE,
    reason TEXT NOT NULL CHECK(reason IN ('spam','abuse','other')),
    created_at BIGINT NOT NULL,
    PRIMARY KEY(reporter_id,message_id)
);
INSERT INTO schema_migrations(version) VALUES (4) ON CONFLICT DO NOTHING;
