//! PostgreSQL transactions own identity, consent, snapshots and consistent public reads.
use crate::domain::*;
use crate::{ApiError, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use postgres::{Client, GenericClient, IsolationLevel, Row, Transaction};
use rand::RngCore;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use uuid::Uuid;

#[derive(Clone)]
pub struct Application {
    pub database_url: String,
    pool: crate::pool::Pool,
    pub clock: Clock,
    pub(crate) legacy_test_mode: bool,
    pub(crate) chat_test_mode: bool,
}
#[derive(Clone)]
pub(crate) struct User {
    pub(crate) id: String,
    nickname: String,
    sharing: bool,
    revision: i64,
}
impl User {
    fn from_row(r: &Row) -> Self {
        Self {
            id: r.get("id"),
            nickname: r.get("nickname"),
            sharing: r.get::<_, i16>("sharing_enabled") == 1,
            revision: r.get("consent_revision"),
        }
    }
    pub(crate) fn public(&self) -> Value {
        json!({"id":self.id,"nickname":self.nickname,"sharing_enabled":self.sharing,"consent_revision":self.revision})
    }
    fn consent(&self, expected: i64, require_sharing: bool) -> Result<()> {
        if self.revision != expected {
            return Err(ApiError::new(
                409,
                "consent_changed",
                "共享状态已变化，请重新读取本人资料",
            ));
        }
        if require_sharing && !self.sharing {
            return Err(ApiError::new(
                403,
                "sharing_required",
                "请先主动同意共享后再同步",
            ));
        }
        Ok(())
    }
}
pub(crate) fn authenticate(
    db: &mut impl GenericClient,
    authorization: Option<&str>,
    now: i64,
    legacy_ok: bool,
) -> Result<User> {
    let invalid = ApiError::new(401, "unauthorized", "身份凭证无效，请重新登录");
    let token = crate::auth::bearer(authorization)?;
    let digest = crate::auth::digest(token);
    if let Some(row) = db.query_opt("SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id JOIN email_accounts a ON a.user_id=u.id AND a.verified WHERE s.access_hash=$1 AND s.access_expires_at>$2", &[&digest,&now])? {
        return Ok(User::from_row(&row));
    }
    if legacy_ok {
        if let Some(row) = db.query_opt("SELECT u.* FROM users u LEFT JOIN email_accounts a ON a.user_id=u.id WHERE u.token_hash=$1 AND (a.user_id IS NULL OR NOT a.verified)", &[&digest])? {
            return Ok(User::from_row(&row));
        }
    }
    Err(invalid)
}

/// Lock users before their auth/session/consent child rows; the public version is last.
pub(crate) fn lock_user(db: &mut impl GenericClient, id: &str) -> Result<()> {
    db.query_opt("SELECT id FROM users WHERE id=$1 FOR UPDATE", &[&id])?
        .ok_or_else(|| ApiError::new(401, "unauthorized", "身份凭证无效，请重新登录"))?;
    Ok(())
}
fn authenticate_write(
    db: &mut impl GenericClient,
    authorization: Option<&str>,
    clock: &Clock,
    legacy: bool,
) -> Result<User> {
    let candidate = authenticate(db, authorization, clock.now()?.timestamp(), legacy)?;
    lock_user(db, &candidate.id)?;
    // Fresh READ COMMITTED statement after waiting: revoked sessions/consent cannot survive.
    authenticate(db, authorization, clock.now()?.timestamp(), legacy)
}

fn invalidate(db: &mut impl GenericClient) -> Result<()> {
    db.execute(
        "UPDATE metadata SET value=value+1 WHERE key='leaderboard_revision'",
        &[],
    )?;
    Ok(())
}
pub(crate) fn refresh_user(db: &mut impl GenericClient, id: &str) -> Result<User> {
    Ok(User::from_row(
        &db.query_one("SELECT * FROM users WHERE id=$1", &[&id])?,
    ))
}
pub(crate) fn begin(db: &mut Client, write: bool) -> Result<Transaction<'_>> {
    let mut tx = if write {
        db.transaction()?
    } else {
        db.build_transaction()
            .isolation_level(IsolationLevel::RepeatableRead)
            .read_only(true)
            .start()?
    };
    tx.batch_execute("SET LOCAL statement_timeout='5000ms'; SET LOCAL lock_timeout='4000ms'")?;
    Ok(tx)
}
impl Application {
    pub fn new(database_url: String, clock: Clock) -> Result<Self> {
        Self::with_pool(database_url, clock, crate::pool::PoolConfig::default())
    }
    pub fn with_pool(
        database_url: String,
        clock: Clock,
        config: crate::pool::PoolConfig,
    ) -> Result<Self> {
        let app = Self {
            pool: crate::pool::Pool::new(&database_url, config)?,
            database_url,
            clock,
            legacy_test_mode: cfg!(test),
            chat_test_mode: false,
        };
        app.migrate()?;
        Ok(app)
    }
    pub fn connect(&self) -> Result<crate::pool::Lease> {
        self.pool.get()
    }
    pub fn migrate(&self) -> Result<()> {
        let mut db = self.connect()?;
        let mut tx = db.transaction()?;
        tx.query_one("SELECT pg_advisory_xact_lock(72815291)", &[])?;
        tx.batch_execute(include_str!("../migrations/001_initial.sql"))?;
        tx.batch_execute(include_str!("../migrations/002_email_auth.sql"))?;
        tx.batch_execute(include_str!("../migrations/003_data_access.sql"))?;
        tx.batch_execute(include_str!("../migrations/004_circle_chat.sql"))?;
        tx.commit()?;
        Ok(())
    }
    pub fn dispatch(
        &self,
        method: &str,
        path: &str,
        authorization: Option<&str>,
        body: &Value,
        params: &HashMap<String, String>,
    ) -> Result<(u16, Value)> {
        self.dispatch_from(method, path, authorization, body, params, "internal")
    }
    pub fn dispatch_from(
        &self,
        method: &str,
        path: &str,
        authorization: Option<&str>,
        body: &Value,
        params: &HashMap<String, String>,
        source: &str,
    ) -> Result<(u16, Value)> {
        if matches!(
            path,
            "/v1/circles/current/messages"
                | "/v1/circles/current/blocks"
                | "/v1/circles/current/reports"
        ) {
            return self.chat_dispatch(method, path, authorization, body, params);
        }
        if path.starts_with("/v1/auth/") {
            return self.auth_dispatch(method, path, authorization, body, source);
        }
        // Old device credentials remain usable only for binding and private privacy operations.
        let privacy = (method == "GET" && path == "/v1/me")
            || (method == "DELETE" && matches!(path, "/v1/me" | "/v1/me/steps"))
            || (method == "PUT"
                && matches!(path, "/v1/me/sharing" | "/v1/me/circle-participation")
                && body["enabled"] == false);
        let legacy_ok = self.legacy_test_mode || privacy;
        if method == "GET" && path == "/health" {
            let context = day_context(self.clock.now()?);
            return Ok((
                200,
                merge(
                    json!({"status":"ok","chat_enabled":self.chat_test_mode}),
                    context,
                ),
            ));
        }
        if method == "POST" && path == "/v1/users" {
            if !self.legacy_test_mode {
                return Err(ApiError::new(
                    403,
                    "email_registration_required",
                    "请通过邮箱验证注册账号",
                ));
            }
            exact_fields(body, &["nickname"])?;
            let name = nickname(&body["nickname"])?;
            let mut bytes = [0u8; 32];
            rand::rngs::OsRng.fill_bytes(&mut bytes);
            let token = URL_SAFE_NO_PAD.encode(bytes);
            let digest = format!("{:x}", Sha256::digest(token.as_bytes()));
            let id = Uuid::new_v4().simple().to_string();
            let now_ts = self.clock.now()?;
            let context = day_context(now_ts);
            let now = timestamp(now_ts);
            let mut db = self.connect()?;
            let mut tx = begin(&mut db, true)?;
            tx.execute(
                "INSERT INTO users(id,token_hash,nickname,created_at) VALUES($1,$2,$3,$4)",
                &[&id, &digest, &name, &now],
            )?;
            let user = refresh_user(&mut tx, &id)?;
            tx.commit()?;
            return Ok((
                201,
                merge(json!({"user":user.public(),"token":token}), context),
            ));
        }
        if method == "GET" && path == "/v1/me" {
            let mut db = self.connect()?;
            let now = self.clock.now()?;
            let user = authenticate(&mut *db, authorization, now.timestamp(), legacy_ok)?;
            return Ok((
                200,
                merge(json!({"user":user.public()}), day_context(now)),
            ));
        }
        if method == "PATCH" && path == "/v1/me" {
            exact_fields(body, &["nickname"])?;
            let name = nickname(&body["nickname"])?;
            let mut db = self.connect()?;
            let mut tx = begin(&mut db, true)?;
            let user = authenticate_write(&mut tx, authorization, &self.clock, legacy_ok)?;
            if user.nickname != name {
                tx.execute(
                    "UPDATE users SET nickname=$1 WHERE id=$2",
                    &[&name, &user.id],
                )?;
                invalidate(&mut tx)?;
            }
            let user = refresh_user(&mut tx, &user.id)?;
            tx.commit()?;
            return Ok((
                200,
                merge(
                    json!({"user":user.public()}),
                    day_context(self.clock.now()?),
                ),
            ));
        }
        if method == "PUT" && path == "/v1/me/sharing" {
            exact_fields(body, &["enabled", "expected_revision"])?;
            let enabled = body["enabled"].as_bool().ok_or(ApiError::new(
                422,
                "invalid_sharing",
                "共享开关必须为布尔值",
            ))?;
            let expected = revision(&body["expected_revision"])?;
            let mut db = self.connect()?;
            let mut tx = begin(&mut db, true)?;
            let user = authenticate_write(&mut tx, authorization, &self.clock, legacy_ok)?;
            user.consent(expected, false)?;
            if !enabled || user.sharing != enabled {
                tx.execute("UPDATE users SET sharing_enabled=$1,consent_revision=consent_revision+1 WHERE id=$2",&[&(enabled as i16),&user.id])?;
                if !enabled {
                    tx.execute(
                        "DELETE FROM circle_participation WHERE user_id=$1",
                        &[&user.id],
                    )?;
                }
                invalidate(&mut tx)?;
            }
            let user = refresh_user(&mut tx, &user.id)?;
            tx.commit()?;
            return Ok((
                200,
                merge(
                    json!({"user":user.public()}),
                    day_context(self.clock.now()?),
                ),
            ));
        }
        if method == "PUT" && path == "/v1/me/steps" {
            exact_fields(body, &["date", "steps", "expected_revision"])?;
            let count = steps(&body["steps"])?;
            let expected = revision(&body["expected_revision"])?;
            let mut db = self.connect()?;
            let mut tx = begin(&mut db, true)?;
            let user = authenticate_write(&mut tx, authorization, &self.clock, legacy_ok)?;
            user.consent(expected, true)?;
            // Re-sample only after PostgreSQL has granted the write lock.
            let now = self.clock.now()?;
            let context = day_context(now);
            let date = current_date(&body["date"], &context)?;
            let previous = tx.query_opt(
                "SELECT steps,updated_at FROM daily_steps WHERE user_id=$1 AND date=$2",
                &[&user.id, &date],
            )?;
            let updated = if previous.as_ref().map(|r| r.get::<_, i64>("steps")) == Some(count) {
                previous.unwrap().get::<_, String>("updated_at")
            } else {
                let updated = timestamp(now);
                tx.execute("INSERT INTO daily_steps(user_id,date,steps,updated_at) VALUES($1,$2,$3,$4) ON CONFLICT(user_id,date) DO UPDATE SET steps=excluded.steps,updated_at=excluded.updated_at",&[&user.id,&date,&count,&updated])?;
                invalidate(&mut tx)?;
                updated
            };
            current_date(&body["date"], &day_context(self.clock.now()?))?;
            tx.commit()?;
            return Ok((
                200,
                merge(
                    json!({"progress":merge(progress(count)?,json!({"synced":true,"updated_at":updated})),"consent_revision":user.revision}),
                    context,
                ),
            ));
        }
        if method == "GET" && path == "/v1/me/steps" {
            let mut db = self.connect()?;
            let mut tx = begin(&mut db, false)?;
            let user = authenticate(
                &mut tx,
                authorization,
                self.clock.now()?.timestamp(),
                legacy_ok,
            )?;
            let context = day_context(self.clock.now()?);
            let date = context["date"].as_str().unwrap();
            let saved = tx.query_opt(
                "SELECT steps,updated_at FROM daily_steps WHERE user_id=$1 AND date=$2",
                &[&user.id, &date],
            )?;
            let count = saved
                .as_ref()
                .map(|r| r.get::<_, i64>("steps"))
                .unwrap_or(0);
            let updated = saved.as_ref().map(|r| r.get::<_, String>("updated_at"));
            return Ok((
                200,
                merge(
                    json!({"progress":merge(progress(count)?,json!({"synced":saved.is_some(),"updated_at":updated})),"consent_revision":user.revision}),
                    context,
                ),
            ));
        }
        if method == "DELETE" && (path == "/v1/me/steps" || path == "/v1/me") {
            exact_fields(body, &["expected_revision"])?;
            let expected = revision(&body["expected_revision"])?;
            let mut db = self.connect()?;
            let mut tx = begin(&mut db, true)?;
            let user = authenticate_write(&mut tx, authorization, &self.clock, legacy_ok)?;
            user.consent(expected, false)?;
            let result = if path.ends_with("/steps") {
                let deleted =
                    tx.execute("DELETE FROM daily_steps WHERE user_id=$1", &[&user.id])?;
                tx.execute("UPDATE users SET sharing_enabled=0,consent_revision=consent_revision+1 WHERE id=$1",&[&user.id])?;
                tx.execute(
                    "DELETE FROM circle_participation WHERE user_id=$1",
                    &[&user.id],
                )?;
                json!({"deleted_days":deleted,"user":refresh_user(&mut tx,&user.id)?.public()})
            } else {
                tx.execute("DELETE FROM users WHERE id=$1", &[&user.id])?;
                json!({"deleted":true})
            };
            invalidate(&mut tx)?;
            tx.commit()?;
            return Ok((200, merge(result, day_context(self.clock.now()?))));
        }
        if (method == "PUT" || method == "GET") && path == "/v1/me/circle-participation" {
            let update = method == "PUT";
            let (enabled, expected) = if update {
                exact_fields(body, &["enabled", "expected_revision"])?;
                (
                    body["enabled"].as_bool().ok_or(ApiError::new(
                        422,
                        "invalid_participation",
                        "圈子参与开关必须为布尔值",
                    ))?,
                    revision(&body["expected_revision"])?,
                )
            } else {
                (false, 0)
            };
            let mut db = self.connect()?;
            let mut tx = begin(&mut db, update)?;
            let user = if update {
                authenticate_write(&mut tx, authorization, &self.clock, legacy_ok)?
            } else {
                authenticate(
                    &mut tx,
                    authorization,
                    self.clock.now()?.timestamp(),
                    legacy_ok,
                )?
            };
            let stored = tx.query_opt(
                "SELECT enabled FROM circle_participation WHERE user_id=$1",
                &[&user.id],
            )?;
            let mut participating = user.sharing
                && stored
                    .map(|r| r.get::<_, i16>("enabled") == 1)
                    .unwrap_or(false);
            if update {
                user.consent(expected, enabled)?;
                if !enabled || enabled != participating {
                    tx.execute("INSERT INTO circle_participation(user_id,enabled) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET enabled=excluded.enabled",&[&user.id,&(enabled as i16)])?;
                    tx.execute("UPDATE users SET sharing_enabled=$1,consent_revision=consent_revision+1 WHERE id=$2",&[&(enabled as i16),&user.id])?;
                    invalidate(&mut tx)?;
                }
                participating = enabled;
            }
            let user = refresh_user(&mut tx, &user.id)?;
            tx.commit()?;
            return Ok((
                200,
                merge(
                    json!({"participating":participating,"user":user.public()}),
                    day_context(self.clock.now()?),
                ),
            ));
        }
        if method == "GET"
            && matches!(
                path,
                "/v1/leaderboard"
                    | "/v1/leaderboard/me"
                    | "/v1/circles/current"
                    | "/v1/circles/current/members"
                    | "/v1/circles/current/me"
            )
        {
            return Ok((200, self.public_listing(path, authorization, params)?));
        }
        let known = [
            "/health",
            "/v1/users",
            "/v1/me",
            "/v1/me/sharing",
            "/v1/me/steps",
            "/v1/leaderboard",
            "/v1/leaderboard/me",
            "/v1/me/circle-participation",
            "/v1/circles/current",
            "/v1/circles/current/members",
            "/v1/circles/current/me",
        ];
        Err(if known.contains(&path) {
            ApiError::new(405, "method_not_allowed", "此接口不支持该方法")
        } else {
            ApiError::new(404, "not_found", "接口不存在")
        })
    }
    fn public_listing(
        &self,
        path: &str,
        authorization: Option<&str>,
        params: &HashMap<String, String>,
    ) -> Result<Value> {
        let limit = page_size(params.get("limit"))?;
        let is_circle = path.starts_with("/v1/circles/");
        let changed = if is_circle {
            "circle_changed"
        } else {
            "leaderboard_changed"
        };
        if let Some(snapshot) = params.get("snapshot") {
            if !is_snapshot_id(snapshot, Some(19)) {
                return Err(ApiError::new(422, "invalid_snapshot", "版本无效"));
            }
        }
        let mut db = self.connect()?;
        let mut tx = begin(&mut db, false)?;
        let viewer = authenticate(
            &mut tx,
            authorization,
            self.clock.now()?.timestamp(),
            self.legacy_test_mode,
        )?;
        let context = day_context(self.clock.now()?);
        let date = context["date"].as_str().unwrap();
        let version: i64 = tx
            .query_one(
                "SELECT value FROM metadata WHERE key='leaderboard_revision'",
                &[],
            )?
            .get(0);
        let snapshot = format!("{}.{}", date, version);
        if params
            .get("snapshot")
            .map(|s| s != &snapshot)
            .unwrap_or(false)
        {
            return Err(ApiError::new(409, changed, "日期或成员已变化，请刷新"));
        }
        let mut common = merge(json!({"snapshot":snapshot,"limit":limit}), context.clone());
        let channel = if is_circle {
            common["consent_revision"] = json!(viewer.revision);
            let opted = tx
                .query_opt(
                    "SELECT enabled FROM circle_participation WHERE user_id=$1",
                    &[&viewer.id],
                )?
                .map(|r| r.get::<_, i16>(0) == 1)
                .unwrap_or(false);
            if !viewer.sharing || !opted {
                if params.contains_key("cursor") {
                    return Err(ApiError::new(
                        409,
                        "circle_changed",
                        "当前未参加圈子，请清除旧成员列表",
                    ));
                }
                return Ok(merge(
                    common,
                    json!({"participating":false,"circle":null,"total":0,"entry":null,"page_cursor":null,"items":[],"next_cursor":null}),
                ));
            }
            let saved = tx
                .query_opt(
                    "SELECT steps FROM daily_steps WHERE user_id=$1 AND date=$2",
                    &[&viewer.id, &date],
                )?
                .map(|r| r.get::<_, i64>(0))
                .unwrap_or(0);
            let channel = circle(date, saved);
            common["participating"] = json!(true);
            common["circle"] = channel.clone();
            Some(channel)
        } else {
            None
        };
        let lower = channel
            .as_ref()
            .map(|c| c["min_steps"].as_i64().unwrap())
            .unwrap_or(0);
        let upper = channel
            .as_ref()
            .map(|c| c["max_steps"].as_i64().unwrap())
            .unwrap_or(MAX_STEPS);
        let channel_id = channel.as_ref().map(|c| c["id"].as_str().unwrap());
        // COUNT and bounded page/own-row queries share one repeatable-read snapshot.
        // When lower > 0, an INNER JOIN on daily_steps lets PostgreSQL start from
        // daily_steps_date_steps_user instead of scanning all shared users.
        let visible = if lower > 0 {
            "WITH visible AS (SELECT u.id AS user_id,u.nickname,s.steps AS steps FROM daily_steps s JOIN users u ON u.id=s.user_id LEFT JOIN circle_participation p ON p.user_id=u.id WHERE s.date=$1 AND u.sharing_enabled=1 AND (NOT $2::boolean OR p.enabled=1) AND s.steps BETWEEN $3 AND $4)"
        } else {
            "WITH visible AS (SELECT u.id AS user_id,u.nickname,COALESCE(s.steps,0) AS steps FROM users u LEFT JOIN daily_steps s ON s.user_id=u.id AND s.date=$1 LEFT JOIN circle_participation p ON p.user_id=u.id WHERE u.sharing_enabled=1 AND (NOT $2::boolean OR p.enabled=1) AND COALESCE(s.steps,0) BETWEEN $3 AND $4)"
        };
        let ranked = format!("{visible}, ranked AS (SELECT *,RANK() OVER(ORDER BY steps DESC) AS rank,ROW_NUMBER() OVER(ORDER BY steps DESC,user_id ASC) AS position FROM visible)");
        let entry = |r: &Row| -> Value {
            let id: String = r.get("user_id");
            let count: i64 = r.get("steps");
            let mut e = merge(
                json!({"user_id":id,"nickname":r.get::<_,String>("nickname"),"position":r.get::<_,i64>("position"),"is_me":id==viewer.id}),
                progress(count).unwrap(),
            );
            if !is_circle {
                e["rank"] = json!(r.get::<_, i64>("rank"));
            }
            e
        };
        if path.ends_with("/me") || path == "/v1/circles/current" {
            let total: i64 = tx
                .query_one(
                    &format!("{visible} SELECT count(*) FROM visible"),
                    &[&date, &is_circle, &lower, &upper],
                )?
                .get(0);
            common["total"] = json!(total);
            let own = tx.query_opt(
                &format!("{ranked} SELECT * FROM ranked WHERE user_id=$5"),
                &[&date, &is_circle, &lower, &upper, &viewer.id],
            )?;
            let e = own.as_ref().map(entry);
            let c = own.as_ref().map(|r| {
                cursor(
                    &snapshot,
                    channel_id,
                    ((r.get::<_, i64>("position") - 1) / limit) * limit,
                    limit,
                )
            });
            return Ok(merge(common, json!({"entry":e,"page_cursor":c})));
        }
        let offset = if let Some(c) = params.get("cursor") {
            read_cursor(c, &snapshot, channel_id, limit)?
        } else {
            0
        };
        let rows = tx.query(
            &format!("{ranked} SELECT *, COUNT(*) OVER() AS total_count FROM ranked ORDER BY position LIMIT $5 OFFSET $6"),
            &[&date, &is_circle, &lower, &upper, &limit, &offset],
        )?;
        let total: i64 = if let Some(first) = rows.first() {
            first.get("total_count")
        } else {
            tx.query_one(
                &format!("{visible} SELECT count(*) FROM visible"),
                &[&date, &is_circle, &lower, &upper],
            )?
            .get(0)
        };
        if offset > 0 && offset >= total {
            return Err(ApiError::new(422, "invalid_cursor", "分页位置无效，请刷新"));
        }
        common["total"] = json!(total);
        let items: Vec<Value> = rows.iter().map(entry).collect();
        let next = offset + items.len() as i64;
        let next_cursor = if next < total {
            Some(cursor(&snapshot, channel_id, next, limit))
        } else {
            None
        };
        Ok(merge(
            common,
            json!({"items":items,"next_cursor":next_cursor}),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Duration as ChronoDuration, Utc};
    use std::path::PathBuf;
    use std::process::Command;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    static POSTGRES_FIXTURE_START: Mutex<()> = Mutex::new(());

    pub(super) struct Fixture {
        pub(super) app: Application,
        schema: String,
        clock: Arc<Mutex<DateTime<Utc>>>,
    }
    impl Fixture {
        pub(super) fn new() -> Self {
            let _startup = POSTGRES_FIXTURE_START.lock().unwrap();
            let schema = format!("test_{}", Uuid::new_v4().simple());
            let script =
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts/postgres_dev.py");
            let output = Command::new("python3")
                .arg(script)
                .args(["test-url", "--schema", &schema])
                .output()
                .expect("PostgreSQL helper could not run");
            assert!(
                output.status.success(),
                "Real task PostgreSQL fixture is required; start scripts/postgres_dev.py"
            );
            let url = String::from_utf8(output.stdout)
                .expect("fixture output invalid")
                .trim()
                .to_owned()
                + "&application_name="
                + &schema;
            let clock = Arc::new(Mutex::new(
                DateTime::parse_from_rfc3339("2026-11-14T15:59:59Z")
                    .unwrap()
                    .with_timezone(&Utc),
            ));
            let app = Application::new(url, Clock::Fixed(clock.clone()))
                .unwrap_or_else(|_| panic!("PostgreSQL migration failed"));
            Self { app, schema, clock }
        }
        fn call(
            &self,
            method: &str,
            path: &str,
            token: Option<&str>,
            body: Value,
        ) -> Result<Value> {
            let auth = token.map(|t| format!("Bearer {}", t));
            self.app
                .dispatch(method, path, auth.as_deref(), &body, &HashMap::new())
                .map(|(_, v)| v)
        }
        fn register(&self) -> String {
            self.call("POST", "/v1/users", None, json!({"nickname":"Rust测试"}))
                .unwrap()["token"]
                .as_str()
                .unwrap()
                .to_owned()
        }
        fn share(&self, token: &str, enabled: bool, expected: i64) -> Result<Value> {
            self.call(
                "PUT",
                "/v1/me/sharing",
                Some(token),
                json!({"enabled":enabled,"expected_revision":expected}),
            )
        }
        fn sync(&self, token: &str, date: &str, count: i64, expected: i64) -> Result<Value> {
            self.call(
                "PUT",
                "/v1/me/steps",
                Some(token),
                json!({"date":date,"steps":count,"expected_revision":expected}),
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let script =
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts/postgres_dev.py");
            let _ = Command::new("python3")
                .arg(script)
                .args(["drop-test-schema", "--schema", &self.schema])
                .output();
        }
    }
    #[test]
    fn postgres_idempotent_snapshot_restart_and_account_delete() {
        let f = Fixture::new();
        let token = f.register();
        f.share(&token, true, 0).unwrap();
        let original = f.sync(&token, "2026-11-14", 101, 1).unwrap();
        *f.clock.lock().unwrap() += ChronoDuration::seconds(0);
        assert_eq!(original, f.sync(&token, "2026-11-14", 101, 1).unwrap());
        let restarted = Application::new(f.app.database_url.clone(), f.app.clock.clone())
            .unwrap_or_else(|_| panic!("PostgreSQL restart failed"));
        let auth = format!("Bearer {}", token);
        let (_, today) = restarted
            .dispatch(
                "GET",
                "/v1/me/steps",
                Some(&auth),
                &json!({}),
                &HashMap::new(),
            )
            .unwrap();
        assert_eq!(today["progress"]["steps"], 101);
        f.call(
            "DELETE",
            "/v1/me",
            Some(&token),
            json!({"expected_revision":1}),
        )
        .unwrap();
        assert_eq!(
            f.call("GET", "/v1/me", Some(&token), json!({}))
                .unwrap_err()
                .code,
            "unauthorized"
        );
        let mut db = f.app.connect().unwrap();
        assert_eq!(
            db.query_one("SELECT count(*) FROM daily_steps", &[])
                .unwrap()
                .get::<_, i64>(0),
            0
        );
        assert_eq!(
            db.query_one("SELECT MAX(version) FROM schema_migrations", &[])
                .unwrap()
                .get::<_, i64>(0),
            4
        );
    }
    #[test]
    fn postgres_concurrent_close_is_persistent_replay_barrier() {
        let f = Arc::new(Fixture::new());
        let token = f.register();
        let close = f.share(&token, false, 0).unwrap();
        assert_eq!(close["user"]["consent_revision"], 1);
        let jobs: Vec<_> = (0..4)
            .map(|_| {
                let f = f.clone();
                let token = token.clone();
                std::thread::spawn(move || f.share(&token, true, 0).unwrap_err().code)
            })
            .collect();
        for job in jobs {
            assert_eq!(job.join().unwrap(), "consent_changed");
        }
        let restarted = Application::new(f.app.database_url.clone(), f.app.clock.clone())
            .unwrap_or_else(|_| panic!("PostgreSQL restart failed"));
        let auth = format!("Bearer {}", token);
        let (_, profile) = restarted
            .dispatch("GET", "/v1/me", Some(&auth), &json!({}), &HashMap::new())
            .unwrap();
        assert_eq!(profile["user"]["sharing_enabled"], false);
    }
    #[test]
    fn postgres_delete_steps_blocks_upload_and_circle_replay() {
        let f = Fixture::new();
        let token = f.register();
        f.share(&token, true, 0).unwrap();
        f.call(
            "PUT",
            "/v1/me/circle-participation",
            Some(&token),
            json!({"enabled":true,"expected_revision":1}),
        )
        .unwrap();
        f.sync(&token, "2026-11-14", 1000, 2).unwrap();
        let result = f
            .call(
                "DELETE",
                "/v1/me/steps",
                Some(&token),
                json!({"expected_revision":2}),
            )
            .unwrap();
        assert_eq!(result["deleted_days"], 1);
        assert_eq!(
            f.sync(&token, "2026-11-14", 1000, 2).unwrap_err().code,
            "consent_changed"
        );
        assert_eq!(
            f.sync(&token, "2026-11-14", 1000, 3).unwrap_err().code,
            "sharing_required"
        );
        assert_eq!(
            f.call(
                "PUT",
                "/v1/me/circle-participation",
                Some(&token),
                json!({"enabled":true,"expected_revision":2})
            )
            .unwrap_err()
            .code,
            "consent_changed"
        );
        assert_eq!(
            f.call("GET", "/v1/circles/current", Some(&token), json!({}))
                .unwrap()["participating"],
            false
        );
    }
    #[test]
    fn postgres_queued_upload_rechecks_midnight_after_real_row_lock() {
        let f = Arc::new(Fixture::new());
        let token = f.register();
        f.share(&token, true, 0).unwrap();
        f.sync(&token, "2026-11-14", 999, 1).unwrap();
        let mut blocker = f.app.connect().unwrap();
        let mut lock = blocker.transaction().unwrap();
        lock.query_one(
            "SELECT value FROM metadata WHERE key='leaderboard_revision' FOR UPDATE",
            &[],
        )
        .unwrap();
        let request = {
            let f = f.clone();
            let token = token.clone();
            std::thread::spawn(move || f.sync(&token, "2026-11-14", 1000, 1))
        };
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut observer = f.app.connect().unwrap();
        loop {
            let waiting:i64=observer.query_one("SELECT count(*) FROM pg_stat_activity WHERE application_name=$1 AND wait_event_type='Lock'",&[&f.schema]).unwrap().get(0);
            if waiting > 0 {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "Rust upload did not acquire PostgreSQL lock wait"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        *f.clock.lock().unwrap() += ChronoDuration::seconds(1);
        lock.commit().unwrap();
        assert_eq!(request.join().unwrap().unwrap_err().code, "day_changed");
        let mut db = f.app.connect().unwrap();
        let old: i64 = db
            .query_one("SELECT steps FROM daily_steps WHERE date='2026-11-14'", &[])
            .unwrap()
            .get(0);
        assert_eq!(old, 999);
        assert_eq!(
            f.call("GET", "/v1/me/steps", Some(&token), json!({}))
                .unwrap()["progress"]["steps"],
            0
        );
    }
}

#[cfg(test)]
mod pool_tests {
    use super::tests::Fixture;
    use crate::pool::{Pool, PoolConfig};
    use std::time::{Duration, Instant};

    #[test]
    fn postgres_pool_bounds_timeout_reuse_rollback_and_broken_connection() {
        fn ready_lease(pool: &Pool) -> crate::pool::Lease {
            // The 80ms budget below tests exhaustion, not database startup speed.
            // A late connection still occupies its bounded slot and may become
            // available to a later acquisition. Fail if recovery takes too long.
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                match pool.get() {
                    Ok(lease) => return lease,
                    Err(error) if error.code == "database_busy" && Instant::now() < deadline => {}
                    Err(error) => panic!("pool did not become ready: {error:?}"),
                }
            }
        }
        let f = Fixture::new();
        let pool = Pool::new(
            &f.app.database_url,
            PoolConfig {
                max_connections: 2,
                acquire_timeout: Duration::from_millis(80),
            },
        )
        .unwrap();
        let mut first = ready_lease(&pool);
        let second = ready_lease(&pool);
        let first_pid: i32 = first
            .query_one("SELECT pg_backend_pid()", &[])
            .unwrap()
            .get(0);
        let start = Instant::now();
        assert_eq!(pool.get().err().unwrap().code, "database_busy");
        assert!(start.elapsed() >= Duration::from_millis(60));
        assert!(start.elapsed() < Duration::from_secs(1));
        {
            let mut tx = first.transaction().unwrap();
            tx.execute(
                "INSERT INTO metadata(key,value) VALUES('must_rollback',1)",
                &[],
            )
            .unwrap();
            assert!(tx.batch_execute("SELECT 1/0").is_err());
            // RAII drops the failed transaction before returning the lease.
        }
        drop(first);
        let mut reused = ready_lease(&pool);
        assert_eq!(
            reused
                .query_one("SELECT pg_backend_pid()", &[])
                .unwrap()
                .get::<_, i32>(0),
            first_pid
        );
        assert_eq!(
            reused
                .query_one(
                    "SELECT count(*) FROM metadata WHERE key='must_rollback'",
                    &[]
                )
                .unwrap()
                .get::<_, i64>(0),
            0
        );
        let mut observer = f.app.connect().unwrap();
        observer
            .query_one("SELECT pg_terminate_backend($1)", &[&first_pid])
            .unwrap();
        // Synchronous postgres drives its connection when queried. Observe the real
        // termination before drop so the dead client is discarded, not retained.
        assert!(reused.simple_query("SELECT 1").is_err());
        assert!(reused.is_closed());
        drop(reused);
        let mut replacement = ready_lease(&pool);
        assert_ne!(
            replacement
                .query_one("SELECT pg_backend_pid()", &[])
                .unwrap()
                .get::<_, i32>(0),
            first_pid
        );
        drop(second);
    }

    #[test]
    fn postgres_pool_waiter_receives_returned_lease_without_exceeding_limit() {
        let f = Fixture::new();
        let pool = Pool::new(
            &f.app.database_url,
            PoolConfig {
                max_connections: 1,
                acquire_timeout: Duration::from_secs(1),
            },
        )
        .unwrap();
        let mut lease = pool.get().unwrap();
        let pid: i32 = lease
            .query_one("SELECT pg_backend_pid()", &[])
            .unwrap()
            .get(0);
        let other = pool.clone();
        let waiter = std::thread::spawn(move || {
            other
                .get()
                .unwrap()
                .query_one("SELECT pg_backend_pid()", &[])
                .unwrap()
                .get::<_, i32>(0)
        });
        std::thread::sleep(Duration::from_millis(50));
        assert!(!waiter.is_finished());
        drop(lease);
        assert_eq!(waiter.join().unwrap(), pid);
    }
}
