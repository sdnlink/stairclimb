-- Additive read indexes. Public snapshots keep their existing revision/offset contract.
CREATE INDEX IF NOT EXISTS daily_steps_date_steps_user ON daily_steps(date, steps DESC, user_id);
CREATE INDEX IF NOT EXISTS users_shared_id ON users(id) WHERE sharing_enabled=1;
CREATE INDEX IF NOT EXISTS circle_enabled_user ON circle_participation(user_id) WHERE enabled=1;
CREATE INDEX IF NOT EXISTS auth_limits_window ON auth_limits(window_start);
INSERT INTO schema_migrations(version) VALUES (3) ON CONFLICT DO NOTHING;
