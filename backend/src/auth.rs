//! Email ownership, adaptive password hashes, one-use proofs and revocable sessions.
use crate::{domain::*, mail, storage::Application, ApiError, Result};
use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use postgres::GenericClient;
use rand::RngCore;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    OnceLock,
};
use uuid::Uuid;

pub const ACCESS_SECONDS: i64 = 900;
pub const REFRESH_SECONDS: i64 = 30 * 86400;
pub const PROOF_SECONDS: i64 = 900;

pub(crate) fn digest(input: &str) -> String {
    format!("{:x}", Sha256::digest(input.as_bytes()))
}
pub(crate) fn secret() -> String {
    let mut bytes = [0; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}
fn invalid_proof() -> ApiError {
    ApiError::new(
        400,
        "invalid_credential",
        "凭据无效、已使用或已过期，请重新申请",
    )
}
fn unauthorized() -> ApiError {
    ApiError::new(
        401,
        "authentication_failed",
        "邮箱、密码或账号状态不符合登录条件",
    )
}
pub(crate) fn bearer(header: Option<&str>) -> Result<&str> {
    header
        .and_then(|s| s.strip_prefix("Bearer "))
        .filter(|s| s.len() == 43 && is_url_safe_b64(s))
        .ok_or_else(|| ApiError::new(401, "unauthorized", "身份凭证无效，请重新登录"))
}
fn proof(body: &Value, field: &str) -> Result<String> {
    body[field]
        .as_str()
        .filter(|s| s.len() == 43 && is_url_safe_b64(s))
        .map(str::to_owned)
        .ok_or_else(invalid_proof)
}
pub fn email(value: &Value) -> Result<String> {
    let invalid = || ApiError::new(422, "invalid_email", "请输入有效邮箱（最多254个ASCII字符）");
    let input = value
        .as_str()
        .ok_or_else(invalid)?
        .trim()
        .to_ascii_lowercase();
    let (local, domain) = input.rsplit_once('@').ok_or_else(invalid)?;
    if input.len() > 254
        || local.is_empty()
        || local.len() > 64
        || local.starts_with('.')
        || local.ends_with('.')
        || local.contains("..")
        || !local.bytes().all(|b| {
            matches!(
                b,
                b'a'..=b'z'
                    | b'0'..=b'9'
                    | b'.'
                    | b'!'
                    | b'#'
                    | b'$'
                    | b'%'
                    | b'&'
                    | b'\''
                    | b'*'
                    | b'+'
                    | b'/'
                    | b'='
                    | b'?'
                    | b'^'
                    | b'_'
                    | b'`'
                    | b'{'
                    | b'|'
                    | b'}'
                    | b'~'
                    | b'-'
            )
        })
        || !domain.contains('.')
        || domain.split('.').any(|s| {
            s.is_empty()
                || s.len() > 63
                || s.starts_with('-')
                || s.ends_with('-')
                || !s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
        })
    {
        return Err(invalid());
    }
    Ok(input)
}
fn password(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|s| (12..=128).contains(&s.chars().count()) && !s.chars().any(char::is_control))
        .ok_or_else(|| {
            ApiError::new(
                422,
                "invalid_password",
                "密码须为12至128个字符，不含控制字符",
            )
        })
}
fn hash_password(value: &str) -> Result<String> {
    let salt = SaltString::generate(&mut rand::rngs::OsRng);
    Argon2::default()
        .hash_password(value.as_bytes(), &salt)
        .map(|s| s.to_string())
        .map_err(|_| ApiError::new(503, "authentication_unavailable", "认证服务暂不可用"))
}
fn verify_password(value: &str, hash: &str) -> bool {
    PasswordHash::new(hash)
        .map(|h| {
            Argon2::default()
                .verify_password(value.as_bytes(), &h)
                .is_ok()
        })
        .unwrap_or(false)
}
fn dummy_hash() -> &'static str {
    static HASH: OnceLock<String> = OnceLock::new();
    // Same cost as real login, computed once per process; never an account credential.
    HASH.get_or_init(|| {
        hash_password("inexistent-account-password").expect("Argon2 parameters valid")
    })
}
fn accepted() -> Value {
    json!({"message":"若请求适用于账号，一次性邮件已提交给邮件服务器；请检查收件箱。此响应不表示邮箱已验证。"})
}
// Registration serializes one email only, then users in sorted order. All other
// authentication writers lock their user before touching proofs/sessions.
fn lock_email(tx: &mut impl GenericClient, email: &str) -> Result<()> {
    tx.query_one(
        "SELECT pg_advisory_xact_lock(hashtextextended($1,0))",
        &[&digest(email)],
    )?;
    Ok(())
}
fn lock_auth_user(tx: &mut impl GenericClient, id: &str, missing: fn() -> ApiError) -> Result<()> {
    crate::storage::lock_user(tx, id).map_err(|error| {
        // Only an absent user is a credential failure. Preserve database errors
        // so a lock timeout does not tell clients to discard valid credentials.
        if error.status == 401 && error.code == "unauthorized" {
            missing()
        } else {
            error
        }
    })
}
fn lock_proof_user(
    tx: &mut impl GenericClient,
    token: &str,
    purpose: &str,
    independent: bool,
) -> Result<()> {
    let row = tx.query_opt("SELECT c.user_id,a.email FROM email_credentials c JOIN email_accounts a ON a.user_id=c.user_id WHERE c.digest=$1 AND c.purpose=$2", &[&digest(token), &purpose])?.ok_or_else(invalid_proof)?;
    if independent {
        lock_email(tx, &row.get::<_, String>("email"))?;
    }
    lock_auth_user(tx, &row.get::<_, String>("user_id"), invalid_proof)
}
fn revoke_all(tx: &mut impl GenericClient, id: &str) -> Result<()> {
    tx.execute("DELETE FROM sessions WHERE user_id=$1", &[&id])?;
    Ok(())
}
fn issue_session(tx: &mut impl GenericClient, id: &str, now: i64) -> Result<Value> {
    let access = secret();
    let refresh = secret();
    tx.execute("INSERT INTO sessions(access_hash,refresh_hash,user_id,access_expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,$5)",
        &[&digest(&access), &digest(&refresh), &id, &(now+ACCESS_SECONDS), &(now+REFRESH_SECONDS)])?;
    let user = crate::storage::refresh_user(tx, id)?;
    Ok(
        json!({"user":user.public(),"token":access,"refresh_token":refresh,"expires_in":ACCESS_SECONDS}),
    )
}

impl Application {
    /// Separate committed counters: failed credentials/SMTP transactions cannot undo limits.
    fn auth_limit(&self, action: &str, source: &str, subject: &str) -> Result<()> {
        static SWEEP_TICK: AtomicU64 = AtomicU64::new(0);
        let now = self.clock.now()?.timestamp();
        let mut db = self.connect()?;
        let mut tx = db.transaction()?;
        tx.batch_execute("SET LOCAL statement_timeout='5000ms'; SET LOCAL lock_timeout='4000ms'")?;
        if SWEEP_TICK.fetch_add(1, Ordering::Relaxed) % 64 == 0 {
            tx.execute(
                "DELETE FROM auth_limits WHERE key IN (SELECT key FROM auth_limits WHERE window_start < $1 LIMIT 200)",
                &[&(now - 86400)],
            )?;
        }
        let mut keys = vec![
            (digest(&format!("{action}:source:{source}")), 30),
            (digest(&format!("{action}:subject:{subject}")), 5),
        ];
        keys.sort();
        let mut allowed = true;
        for (key, limit) in keys {
            let count: i32 = tx.query_one("INSERT INTO auth_limits(key,window_start,hits) VALUES($1,$2,1) ON CONFLICT(key) DO UPDATE SET window_start=CASE WHEN auth_limits.window_start <= $2-300 THEN $2 ELSE auth_limits.window_start END,hits=CASE WHEN auth_limits.window_start <= $2-300 THEN 1 ELSE LEAST(auth_limits.hits+1,1000000) END RETURNING hits", &[&key, &now])?.get(0);
            allowed &= count <= limit;
        }
        tx.commit()?;
        if !allowed {
            return Err(ApiError::new(
                429,
                "rate_limited",
                "请求过于频繁，请在5分钟后重试",
            ));
        }
        Ok(())
    }

    pub(crate) fn auth_dispatch(
        &self,
        method: &str,
        path: &str,
        authorization: Option<&str>,
        body: &Value,
        source: &str,
    ) -> Result<(u16, Value)> {
        let action = path.strip_prefix("/v1/auth/").unwrap_or("");
        if action == "account" && method == "GET" {
            let mut db = self.connect()?;
            let mut tx = crate::storage::begin(&mut db, false)?;
            let user = crate::storage::authenticate(
                &mut tx,
                authorization,
                self.clock.now()?.timestamp(),
                false,
            )?;
            let account = tx.query_one(
                "SELECT email FROM email_accounts WHERE user_id=$1 AND verified",
                &[&user.id],
            )?;
            return Ok((
                200,
                merge(
                    json!({"email":account.get::<_,String>(0),"verified":true}),
                    day_context(self.clock.now()?),
                ),
            ));
        }
        if method != "POST" {
            return Err(ApiError::new(
                405,
                "method_not_allowed",
                "此接口不支持该方法",
            ));
        }
        let context = day_context(self.clock.now()?);
        match action {
            "register" | "bind" | "resend" | "forgot-password" => {
                let fields: &[&str] = match action {
                    "register" => &["email", "password", "nickname"],
                    "bind" => &["email", "password"],
                    _ => &["email"],
                };
                exact_fields(body, fields)?;
                let email = email(&body["email"])?;
                self.auth_limit(action, source, &email)?;
                let name = if action == "register" {
                    Some(nickname(&body["nickname"])?)
                } else {
                    None
                };
                // Hash on duplicates too. Never overwrite an existing pending account's password.
                let hash = if action == "register" || action == "bind" {
                    Some(hash_password(password(&body["password"])?)?)
                } else {
                    None
                };
                let mut db = self.connect()?;
                let mut tx = crate::storage::begin(&mut db, true)?;
                lock_email(&mut tx, &email)?;
                let existing = tx.query_opt(
                    "SELECT user_id,verified FROM email_accounts WHERE email=$1",
                    &[&email],
                )?;
                let binding = if action == "bind" {
                    let hash = digest(bearer(authorization)?);
                    Some(tx.query_opt("SELECT u.id FROM users u LEFT JOIN email_accounts a ON a.user_id=u.id WHERE u.token_hash=$1 AND (a.user_id IS NULL OR (a.legacy_binding AND NOT a.verified))", &[&hash])?
                        .ok_or_else(|| ApiError::new(401,"unauthorized","绑定需要原设备有效身份凭证"))?.get::<_,String>(0))
                } else {
                    None
                };
                let mut ids: Vec<String> = existing
                    .as_ref()
                    .map(|r| r.get("user_id"))
                    .into_iter()
                    .chain(binding.clone())
                    .collect();
                ids.sort();
                ids.dedup();
                for id in ids {
                    crate::storage::lock_user(&mut tx, &id)?;
                }
                // Re-read after waiting for deletion, verify, or another binding.
                let existing = tx.query_opt(
                    "SELECT user_id,verified FROM email_accounts WHERE email=$1",
                    &[&email],
                )?;
                if let Some(id) = &binding {
                    if tx.query_opt("SELECT u.id FROM users u LEFT JOIN email_accounts a ON a.user_id=u.id WHERE u.id=$1 AND (a.user_id IS NULL OR (a.legacy_binding AND NOT a.verified))", &[id])?.is_none() {
                        return Err(ApiError::new(401,"unauthorized","绑定需要原设备有效身份凭证"));
                    }
                }
                let mut target = None;
                if existing.is_none() && (action == "register" || action == "bind") {
                    let id = binding
                        .clone()
                        .unwrap_or_else(|| Uuid::new_v4().simple().to_string());
                    if binding.is_none() {
                        tx.execute("INSERT INTO users(id,token_hash,nickname,created_at) VALUES($1,$2,$3,$4)",
                            &[&id,&digest(&secret()),&name.as_ref().unwrap(),&timestamp(self.clock.now()?)])?;
                    }
                    // One email identity per old user: never replace or merge a pending binding.
                    if tx
                        .query_opt(
                            "SELECT user_id FROM email_accounts WHERE user_id=$1",
                            &[&id],
                        )?
                        .is_none()
                    {
                        tx.execute("INSERT INTO email_accounts(user_id,email,password_hash,legacy_binding) VALUES($1,$2,$3,$4)",
                            &[&id,&email,&hash.as_ref().unwrap(),&binding.is_some()])?;
                        target = Some(id);
                    }
                } else if let Some(row) = existing {
                    let verified: bool = row.get("verified");
                    if (action == "resend" && !verified) || (action == "forgot-password") {
                        target = Some(row.get::<_, String>("user_id"));
                    }
                }
                let purpose = if action == "forgot-password" {
                    "reset"
                } else {
                    "verify"
                };
                let token = secret();
                if let Some(id) = target {
                    tx.execute("INSERT INTO email_credentials(digest,user_id,purpose,expires_at) VALUES($1,$2,$3,$4) ON CONFLICT(user_id,purpose) DO UPDATE SET digest=excluded.digest,expires_at=excluded.expires_at",
                        &[&digest(&token),&id,&purpose,&(self.clock.now()?.timestamp()+PROOF_SECONDS)])?;
                }
                // Always submit one message, including duplicate/unknown addresses. SMTP failure
                // has the same status for all valid requests, and rolls back all account changes.
                mail::send(&email, purpose, &token)?;
                tx.commit()?;
                Ok((202, merge(accepted(), context)))
            }
            "register-independent" => {
                exact_fields(body, &["token", "password", "nickname"])?;
                self.auth_limit(action, source, body["token"].as_str().unwrap_or("invalid"))?;
                let token = proof(body, "token")?;
                let name = nickname(&body["nickname"])?;
                let hash = hash_password(password(&body["password"])?)?;
                let mut db = self.connect()?;
                let mut tx = crate::storage::begin(&mut db, true)?;
                lock_proof_user(&mut tx, &token, "reset", true)?;
                let row = tx.query_opt(
                    "SELECT c.user_id,c.expires_at,a.email,a.verified,a.legacy_binding FROM email_credentials c JOIN email_accounts a ON a.user_id=c.user_id WHERE c.digest=$1 AND c.purpose='reset'",
                    &[&digest(&token)],
                )?.ok_or_else(invalid_proof)?;
                if row.get::<_, i64>("expires_at") <= self.clock.now()?.timestamp()
                    || row.get::<_, bool>("verified")
                    || !row.get::<_, bool>("legacy_binding")
                {
                    return Err(invalid_proof());
                }
                let previous_id: String = row.get("user_id");
                let email: String = row.get("email");
                // Mailbox ownership permits cancelling an UNVERIFIED association, never
                // taking over the old device identity. Keep users/history/consent untouched.
                // Cascades consume every old mail proof, so a delayed binding cannot revive it.
                tx.execute(
                    "DELETE FROM email_accounts WHERE user_id=$1",
                    &[&previous_id],
                )?;
                let id = Uuid::new_v4().simple().to_string();
                tx.execute(
                    "INSERT INTO users(id,token_hash,nickname,created_at) VALUES($1,$2,$3,$4)",
                    &[
                        &id,
                        &digest(&secret()),
                        &name,
                        &timestamp(self.clock.now()?),
                    ],
                )?;
                tx.execute(
                    "INSERT INTO email_accounts(user_id,email,password_hash,verified) VALUES($1,$2,$3,TRUE)",
                    &[&id, &email, &hash],
                )?;
                tx.commit()?;
                Ok((
                    200,
                    merge(json!({"completed":true}), day_context(self.clock.now()?)),
                ))
            }
            "verify" | "reset-password" => {
                exact_fields(body, &["token", "password"])?;
                // Source limit also applies to malformed/random proofs.
                self.auth_limit(action, source, body["token"].as_str().unwrap_or("invalid"))?;
                let token = proof(body, "token")?;
                let pass = password(&body["password"])?;
                let new_hash = if action == "reset-password" {
                    Some(hash_password(pass)?)
                } else {
                    None
                };
                let purpose = if action == "verify" {
                    "verify"
                } else {
                    "reset"
                };
                let mut db = self.connect()?;
                let mut tx = crate::storage::begin(&mut db, true)?;
                lock_proof_user(&mut tx, &token, purpose, false)?;
                let row = tx.query_opt("SELECT c.user_id,c.expires_at,a.password_hash,a.legacy_binding,a.verified FROM email_credentials c JOIN email_accounts a ON a.user_id=c.user_id WHERE c.digest=$1 AND c.purpose=$2", &[&digest(&token),&purpose])?.ok_or_else(invalid_proof)?;
                if row.get::<_, i64>("expires_at") <= self.clock.now()?.timestamp() {
                    return Err(invalid_proof());
                }
                let id: String = row.get("user_id");
                if action == "verify" {
                    if row.get::<_, bool>("verified")
                        || !verify_password(pass, &row.get::<_, String>("password_hash"))
                    {
                        return Err(invalid_proof());
                    }
                    if row.get::<_, bool>("legacy_binding") {
                        let old = digest(bearer(authorization)?);
                        if tx
                            .query_opt(
                                "SELECT id FROM users WHERE id=$1 AND token_hash=$2",
                                &[&id, &old],
                            )?
                            .is_none()
                        {
                            return Err(ApiError::new(
                                401,
                                "unauthorized",
                                "绑定需要原设备有效身份凭证",
                            ));
                        }
                    }
                    tx.execute(
                        "UPDATE email_accounts SET verified=TRUE WHERE user_id=$1",
                        &[&id],
                    )?;
                } else {
                    if row.get::<_, bool>("legacy_binding") && !row.get::<_, bool>("verified") {
                        let old = digest(bearer(authorization)?);
                        if tx
                            .query_opt(
                                "SELECT id FROM users WHERE id=$1 AND token_hash=$2",
                                &[&id, &old],
                            )?
                            .is_none()
                        {
                            return Err(ApiError::new(
                                401,
                                "unauthorized",
                                "绑定需要原设备有效身份凭证",
                            ));
                        }
                    }
                    tx.execute(
                        "UPDATE email_accounts SET password_hash=$1,verified=TRUE WHERE user_id=$2",
                        &[&new_hash.as_ref().unwrap(), &id],
                    )?;
                    revoke_all(&mut tx, &id)?;
                }
                tx.execute("DELETE FROM email_credentials WHERE user_id=$1", &[&id])?;
                tx.commit()?;
                Ok((
                    200,
                    merge(json!({"completed":true}), day_context(self.clock.now()?)),
                ))
            }
            "login" => {
                exact_fields(body, &["email", "password"])?;
                let email = email(&body["email"])?;
                self.auth_limit(action, source, &email)?;
                let pass = password(&body["password"])?;
                let mut db = self.connect()?;
                let row = db.query_opt(
                    "SELECT user_id,password_hash,verified FROM email_accounts WHERE email=$1",
                    &[&email],
                )?;
                let hash = row.as_ref().map(|r| r.get::<_, String>("password_hash"));
                // Initialize dummy before either branch so first unknown login has no extra cost.
                let dummy = dummy_hash();
                let valid = verify_password(pass, hash.as_deref().unwrap_or(dummy));
                if !valid
                    || !row
                        .as_ref()
                        .map(|r| r.get::<_, bool>("verified"))
                        .unwrap_or(false)
                {
                    return Err(unauthorized());
                }
                let id: String = row.unwrap().get("user_id");
                let mut tx = crate::storage::begin(&mut db, true)?;
                lock_auth_user(&mut tx, &id, unauthorized)?;
                // Password may have changed while Argon2 was running; recheck under write lock.
                if tx.query_opt("SELECT user_id FROM email_accounts WHERE user_id=$1 AND password_hash=$2 AND verified", &[&id,&hash.unwrap()])?.is_none() { return Err(unauthorized()); }
                tx.execute(
                    "DELETE FROM sessions WHERE refresh_expires_at <= $1 AND user_id=$2",
                    &[&self.clock.now()?.timestamp(), &id],
                )?;
                let session = issue_session(&mut tx, &id, self.clock.now()?.timestamp())?;
                tx.commit()?;
                Ok((200, merge(session, day_context(self.clock.now()?))))
            }
            "refresh" => {
                exact_fields(body, &["refresh_token"])?;
                self.auth_limit(
                    action,
                    source,
                    body["refresh_token"].as_str().unwrap_or("invalid"),
                )?;
                let token = proof(body, "refresh_token")?;
                let mut db = self.connect()?;
                let mut tx = crate::storage::begin(&mut db, true)?;
                let candidate = tx
                    .query_opt(
                        "SELECT user_id FROM sessions WHERE refresh_hash=$1",
                        &[&digest(&token)],
                    )?
                    .ok_or_else(unauthorized)?;
                lock_auth_user(&mut tx, &candidate.get::<_, String>(0), unauthorized)?;
                let now = self.clock.now()?.timestamp();
                let row = tx.query_opt("DELETE FROM sessions WHERE refresh_hash=$1 AND refresh_expires_at>$2 RETURNING user_id", &[&digest(&token),&now])?.ok_or_else(unauthorized)?;
                let id: String = row.get(0);
                let session = issue_session(&mut tx, &id, now)?;
                tx.commit()?;
                Ok((200, merge(session, day_context(self.clock.now()?))))
            }
            "logout" | "logout-all" => {
                exact_fields(body, &[])?;
                let token = bearer(authorization)?;
                self.auth_limit(action, source, token)?;
                let mut db = self.connect()?;
                let mut tx = crate::storage::begin(&mut db, true)?;
                let candidate = tx
                    .query_opt(
                        "SELECT user_id FROM sessions WHERE access_hash=$1",
                        &[&digest(token)],
                    )?
                    .ok_or_else(unauthorized)?;
                lock_auth_user(&mut tx, &candidate.get::<_, String>(0), unauthorized)?;
                // Expired access may still terminate its own unexpired refresh session.
                let row = tx.query_opt("SELECT user_id FROM sessions WHERE access_hash=$1 AND refresh_expires_at>$2", &[&digest(token),&self.clock.now()?.timestamp()])?.ok_or_else(unauthorized)?;
                if action == "logout-all" {
                    revoke_all(&mut tx, &row.get::<_, String>(0))?;
                } else {
                    tx.execute(
                        "DELETE FROM sessions WHERE access_hash=$1",
                        &[&digest(token)],
                    )?;
                }
                tx.commit()?;
                Ok((200, merge(json!({"completed":true}), context)))
            }
            _ => Err(ApiError::new(404, "not_found", "接口不存在")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn email_policy_and_password_bounds() {
        assert_eq!(
            email(&json!(" A.Name+tag@EXAMPLE.test ")).unwrap(),
            "a.name+tag@example.test"
        );
        for s in [
            "x",
            "@example.test",
            "x..y@example.test",
            "a@-x.test",
            "a@b",
            "a\r\n@x.test",
            "中文@x.test",
        ] {
            assert!(email(&json!(s)).is_err());
        }
        assert!(password(&json!("short")).is_err());
        assert!(password(&json!("a".repeat(129))).is_err());
    }
    #[test]
    fn salted_argon2id_and_high_entropy_proofs() {
        let a = hash_password("a private passphrase").unwrap();
        let b = hash_password("a private passphrase").unwrap();
        assert_ne!(a, b);
        assert!(a.starts_with("$argon2id$v=19$m=19456,t=2,p=1$"));
        assert!(verify_password("a private passphrase", &a));
        assert!(!verify_password("wrong passphrase", &a));
        let a = secret();
        let b = secret();
        assert_eq!(a.len(), 43);
        assert_ne!(a, b);
        assert_ne!(digest(&a), a);
    }
}
