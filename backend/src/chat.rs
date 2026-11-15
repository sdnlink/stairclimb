//! Authenticated, current-circle text channels. No email, location or health samples in messages.
use crate::domain::{day_context, exact_fields, merge, CIRCLE_BAND_STEPS};
use crate::storage::{authenticate, begin, lock_user, Application, User};
use crate::{ApiError, Result};
use postgres::{GenericClient, Row};
use serde_json::{json, Value};
use std::collections::HashMap;
use uuid::Uuid;

const MESSAGES: &str = "/v1/circles/current/messages";
const BLOCKS: &str = "/v1/circles/current/blocks";
const REPORTS: &str = "/v1/circles/current/reports";

fn invalid() -> ApiError {
    ApiError::new(
        422,
        "invalid_chat",
        "消息须为1至1000字，频道和分页参数须有效",
    )
}
fn missing() -> ApiError {
    ApiError::new(404, "message_unavailable", "消息不可用或不属于当前频道")
}
fn positive(value: &Value) -> Result<i64> {
    value.as_i64().filter(|n| *n > 0).ok_or_else(invalid)
}
fn channel(db: &mut impl GenericClient, user: &User, date: &str) -> Result<String> {
    let row = db.query_one("SELECT u.sharing_enabled,COALESCE(p.enabled,0)::smallint AS enabled,COALESCE(s.steps,0) AS steps FROM users u LEFT JOIN circle_participation p ON p.user_id=u.id LEFT JOIN daily_steps s ON s.user_id=u.id AND s.date=$2 WHERE u.id=$1", &[&user.id,&date])?;
    if row.get::<_, i16>(0) != 1 || row.get::<_, i16>(1) != 1 {
        return Err(ApiError::new(
            403,
            "circle_required",
            "请先主动同意共享并参加今日圈子",
        ));
    }
    let lower = row.get::<_, i64>(2) / CIRCLE_BAND_STEPS * CIRCLE_BAND_STEPS;
    Ok(format!(
        "{}:{}-{}",
        date,
        lower,
        lower + CIRCLE_BAND_STEPS - 1
    ))
}
fn message(row: &Row, me: &str) -> Value {
    json!({"id":row.get::<_,i64>("id"),"circle_id":row.get::<_,String>("circle_id"),
        "author_id":row.get::<_,String>("author_id"),"nickname":row.get::<_,String>("nickname"),
        "text":row.get::<_,String>("text"),"reply_to":row.get::<_,Option<i64>>("reply_to"),
        "created_at":row.get::<_,i64>("created_at"),"deleted":row.get::<_,bool>("deleted"),
        "change_id":row.get::<_,i64>("change_id"),"is_me":row.get::<_,String>("author_id")==me})
}
// Apply bidirectional blocks and withdrawal to every read, reply and report lookup.
const VISIBLE: &str = "u.sharing_enabled=1 AND EXISTS(SELECT 1 FROM circle_participation p WHERE p.user_id=u.id AND p.enabled=1) AND NOT EXISTS(SELECT 1 FROM circle_blocks b WHERE (b.blocker_id=$2 AND b.blocked_id=m.author_id) OR (b.blocked_id=$2 AND b.blocker_id=m.author_id))";

impl Application {
    pub(crate) fn chat_dispatch(
        &self,
        method: &str,
        path: &str,
        authorization: Option<&str>,
        body: &Value,
        params: &HashMap<String, String>,
    ) -> Result<(u16, Value)> {
        if !self.chat_test_mode {
            return Err(ApiError::new(503, "chat_disabled", "交流功能暂未开放"));
        }
        if !matches!(
            (method, path),
            ("GET", MESSAGES)
                | ("POST", MESSAGES)
                | ("DELETE", MESSAGES)
                | ("GET", BLOCKS)
                | ("PUT", BLOCKS)
                | ("POST", REPORTS)
        ) {
            return Err(ApiError::new(
                405,
                "method_not_allowed",
                "此接口不支持该方法",
            ));
        }
        let requested = if method == "GET" {
            params.get("circle_id").map(String::as_str)
        } else {
            body["circle_id"].as_str()
        }
        .ok_or_else(invalid)?;
        let mut db = self.connect()?;
        // READ COMMITTED after user lock: logout, consent and step changes cannot race a send.
        let mut tx = begin(&mut db, true)?;
        let candidate = authenticate(&mut tx, authorization, self.clock.now()?.timestamp(), false)?;
        lock_user(&mut tx, &candidate.id)?;
        let user = authenticate(&mut tx, authorization, self.clock.now()?.timestamp(), false)?;
        let context = day_context(self.clock.now()?);
        let date = context["date"].as_str().unwrap();
        let current = channel(&mut tx, &user, date)?;
        if requested != current {
            return Err(ApiError::new(
                409,
                "circle_changed",
                "今日频道已变化，请刷新后重新发送",
            ));
        }
        // Serialize this channel's writes and polling watermark; another channel stays independent.
        tx.query_one(
            "SELECT pg_advisory_xact_lock(hashtextextended($1,7104))",
            &[&current],
        )?;
        if day_context(self.clock.now()?)["date"] != context["date"] {
            return Err(ApiError::new(
                409,
                "circle_changed",
                "日期已变化，请刷新今日频道",
            ));
        }
        let now = self.clock.now()?.timestamp();
        let mut status = 200;
        let payload = if path == MESSAGES && method == "GET" {
            let parse = |name: &str| -> Result<Option<i64>> {
                params
                    .get(name)
                    .map(|s| s.parse::<i64>().ok().filter(|n| *n > 0).ok_or_else(invalid))
                    .transpose()
            };
            let before = parse("before")?;
            let after = parse("after")?;
            if before.is_some() && after.is_some() {
                return Err(invalid());
            }
            let limit = params
                .get("limit")
                .map(|s| s.parse::<i64>().map_err(|_| invalid()))
                .transpose()?
                .unwrap_or(20);
            if !(1..=50).contains(&limit) {
                return Err(invalid());
            }
            let sql = format!("SELECT m.*,u.nickname FROM circle_messages m JOIN users u ON u.id=m.author_id WHERE m.circle_id=$1 AND {} AND ($3::bigint IS NULL OR m.id<$3) AND ($4::bigint IS NULL OR m.change_id>$4) ORDER BY {} LIMIT $5",VISIBLE,if after.is_some(){"m.change_id ASC"}else{"m.id DESC"});
            let mut rows = tx.query(&sql, &[&current, &user.id, &before, &after, &(limit + 1)])?;
            let more = rows.len() > limit as usize;
            rows.truncate(limit as usize);
            let next_before = if after.is_none() && more {
                rows.last().map(|r| r.get::<_, i64>("id"))
            } else {
                None
            };
            let watermark: i64 = if after.is_some() && more {
                rows.last().unwrap().get("change_id")
            } else {
                tx.query_one(
                    "SELECT COALESCE(MAX(change_id),0) FROM circle_messages WHERE circle_id=$1",
                    &[&current],
                )?
                .get(0)
            };
            if after.is_none() {
                rows.reverse();
            }
            json!({"messages":rows.iter().map(|r|message(r,&user.id)).collect::<Vec<_>>(),"next_before":next_before,"watermark":watermark,"has_more":after.is_some() && more})
        } else if path == MESSAGES && method == "POST" {
            exact_fields(body, &["circle_id", "text", "reply_to", "client_id"])?;
            let text = body["text"].as_str().ok_or_else(invalid)?.trim();
            if text.is_empty()
                || text.chars().count() > 1000
                || text
                    .chars()
                    .any(|c| c.is_control() && c != '\n' && c != '\t')
            {
                return Err(invalid());
            }
            let client_id = body["client_id"]
                .as_str()
                .and_then(|s| Uuid::parse_str(s).ok())
                .ok_or_else(invalid)?
                .to_string();
            let reply = if body["reply_to"].is_null() {
                None
            } else {
                Some(positive(&body["reply_to"])?)
            };
            let existing = tx.query_opt("SELECT m.*,u.nickname FROM circle_messages m JOIN users u ON u.id=m.author_id WHERE m.author_id=$1 AND m.client_id=$2::text::uuid",&[&user.id,&client_id])?;
            let row = if let Some(row) = existing {
                if row.get::<_, String>("circle_id") != current
                    || row.get::<_, String>("text") != text
                    || row.get::<_, Option<i64>>("reply_to") != reply
                    || row.get::<_, bool>("deleted")
                {
                    return Err(ApiError::new(
                        409,
                        "message_conflict",
                        "消息已处理，请刷新确认",
                    ));
                }
                row
            } else {
                if let Some(reply) = reply {
                    let sql = format!("SELECT m.id FROM circle_messages m JOIN users u ON u.id=m.author_id WHERE m.circle_id=$1 AND {} AND m.id=$3 AND NOT m.deleted",VISIBLE);
                    if tx.query_opt(&sql, &[&current, &user.id, &reply])?.is_none() {
                        return Err(missing());
                    }
                }
                let recent: i64 = tx
                    .query_one(
                        "SELECT COUNT(*) FROM circle_messages WHERE author_id=$1 AND created_at>$2",
                        &[&user.id, &(now - 10)],
                    )?
                    .get(0);
                if recent >= 5 {
                    return Err(ApiError::new(
                        429,
                        "chat_rate_limited",
                        "发送过快，请稍后再发",
                    ));
                }
                let id:i64 = tx.query_one("INSERT INTO circle_messages(circle_id,author_id,client_id,text,reply_to,created_at) VALUES($1,$2,$3::text::uuid,$4,$5,$6) RETURNING id",&[&current,&user.id,&client_id,&text,&reply,&now])?.get(0);
                status = 201;
                tx.query_one("SELECT m.*,u.nickname FROM circle_messages m JOIN users u ON u.id=m.author_id WHERE m.id=$1",&[&id])?
            };
            json!({"chat_message":message(&row,&user.id)})
        } else if path == MESSAGES {
            exact_fields(body, &["circle_id", "message_id"])?;
            let id = positive(&body["message_id"])?;
            let row = tx.query_opt("UPDATE circle_messages m SET text='',deleted=true,change_id=nextval('circle_chat_changes') FROM users u WHERE m.id=$1 AND m.circle_id=$2 AND m.author_id=$3 AND u.id=m.author_id RETURNING m.*,u.nickname",&[&id,&current,&user.id])?.ok_or_else(missing)?;
            json!({"chat_message":message(&row,&user.id)})
        } else if path == BLOCKS && method == "GET" {
            let rows = tx.query("SELECT u.id AS user_id,u.nickname FROM circle_blocks b JOIN users u ON u.id=b.blocked_id WHERE b.blocker_id=$1 ORDER BY u.id",&[&user.id])?;
            json!({"blocked_users":rows.iter().map(|r| json!({"user_id":r.get::<_,String>("user_id"),"nickname":r.get::<_,String>("nickname")})).collect::<Vec<_>>()})
        } else if path == BLOCKS {
            exact_fields(body, &["circle_id", "user_id", "enabled"])?;
            let target = body["user_id"]
                .as_str()
                .filter(|s| *s != user.id)
                .ok_or_else(invalid)?;
            let enabled = body["enabled"].as_bool().ok_or_else(invalid)?;
            if enabled {
                if tx.query_opt("SELECT id FROM circle_messages WHERE circle_id=$1 AND author_id=$2 LIMIT 1",&[&current,&target])?.is_none() { return Err(missing()); }
                tx.execute("INSERT INTO circle_blocks(blocker_id,blocked_id) VALUES($1,$2) ON CONFLICT DO NOTHING",&[&user.id,&target])?;
            } else {
                tx.execute(
                    "DELETE FROM circle_blocks WHERE blocker_id=$1 AND blocked_id=$2",
                    &[&user.id, &target],
                )?;
            }
            json!({"completed":true})
        } else {
            exact_fields(body, &["circle_id", "message_id", "reason"])?;
            let id = positive(&body["message_id"])?;
            let reason = body["reason"]
                .as_str()
                .filter(|s| matches!(*s, "spam" | "abuse" | "other"))
                .ok_or_else(invalid)?;
            let sql = format!("SELECT m.id FROM circle_messages m JOIN users u ON u.id=m.author_id WHERE m.circle_id=$1 AND {} AND m.id=$3 AND m.author_id<>$2 AND NOT m.deleted",VISIBLE);
            if tx.query_opt(&sql, &[&current, &user.id, &id])?.is_none() {
                return Err(missing());
            }
            tx.execute("INSERT INTO circle_reports(reporter_id,message_id,reason,created_at) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING",&[&user.id,&id,&reason,&now])?;
            json!({"completed":true})
        };
        if day_context(self.clock.now()?)["date"] != context["date"] {
            return Err(ApiError::new(
                409,
                "circle_changed",
                "日期已变化，请刷新今日频道",
            ));
        }
        tx.commit()?;
        Ok((
            status,
            merge(merge(payload, json!({"circle_id":current})), context),
        ))
    }
}
