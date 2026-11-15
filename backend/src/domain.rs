use crate::{ApiError, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, Duration, NaiveDate, SecondsFormat, Utc};
use chrono_tz::Asia::Shanghai;
use regex::Regex;
use serde_json::{json, Value};
use unicode_general_category::{get_general_category, GeneralCategory};

pub const STEPS_PER_FLOOR: i64 = 100;
pub const MAX_STEPS: i64 = 1_000_000;
pub const CIRCLE_BAND_STEPS: i64 = 1000;
pub const MAX_BODY_BYTES: usize = 4096;

#[derive(Clone)]
pub enum Clock {
    Real,
    #[cfg(test)]
    Fixed(std::sync::Arc<std::sync::Mutex<DateTime<Utc>>>),
    #[cfg(feature = "test-support")]
    File(std::path::PathBuf),
}
impl Clock {
    pub fn now(&self) -> Result<DateTime<Utc>> {
        match self {
            Self::Real => Ok(Utc::now()),
            #[cfg(test)]
            Self::Fixed(value) => Ok(*value.lock().unwrap()),
            #[cfg(feature = "test-support")]
            Self::File(path) => std::fs::read_to_string(path)
                .ok()
                .and_then(|s| DateTime::parse_from_rfc3339(s.trim()).ok())
                .map(|d| d.with_timezone(&Utc))
                .ok_or(ApiError::new(503, "clock_unavailable", "测试时钟不可用")),
        }
    }
}
pub fn day_context(now: DateTime<Utc>) -> Value {
    let day = now.with_timezone(&Shanghai).date_naive();
    json!({"date":day.to_string(),"timezone":"Asia/Shanghai",
        "day_start":format!("{}T00:00:00+08:00",day),
        "day_end":format!("{}T00:00:00+08:00",day+Duration::days(1)),
        "steps_per_floor":STEPS_PER_FLOOR,"max_steps":MAX_STEPS,"circle_band_steps":CIRCLE_BAND_STEPS})
}
pub fn timestamp(now: DateTime<Utc>) -> String {
    now.to_rfc3339_opts(SecondsFormat::AutoSi, false)
}
pub fn merge(mut value: Value, other: Value) -> Value {
    value
        .as_object_mut()
        .unwrap()
        .extend(other.as_object().unwrap().clone());
    value
}
pub fn matches(pattern: &str, text: &str) -> bool {
    Regex::new(pattern).unwrap().is_match(text)
}
pub fn progress(steps: i64) -> Result<Value> {
    if !(0..=MAX_STEPS).contains(&steps) {
        return Err(ApiError::new(
            422,
            "invalid_steps",
            "步数必须是0至1000000的整数",
        ));
    }
    Ok(
        json!({"steps":steps,"floor":steps/STEPS_PER_FLOOR,"remaining_steps":STEPS_PER_FLOOR-steps%STEPS_PER_FLOOR}),
    )
}
pub fn steps(value: &Value) -> Result<i64> {
    value
        .as_i64()
        .filter(|n| (0..=MAX_STEPS).contains(n))
        .ok_or(ApiError::new(
            422,
            "invalid_steps",
            "步数必须是0至1000000的整数",
        ))
}
pub fn revision(value: &Value) -> Result<i64> {
    value.as_i64().filter(|n| *n >= 0).ok_or(ApiError::new(
        422,
        "invalid_revision",
        "共享版本必须是非负整数",
    ))
}
pub fn nickname(value: &Value) -> Result<String> {
    let invalid = ApiError::new(
        422,
        "invalid_nickname",
        "昵称须为1至24个可见字符，可含普通空格",
    );
    let s = value.as_str().ok_or(invalid.clone())?.trim();
    if !(1..=24).contains(&s.chars().count())
        || s.chars().any(|c| {
            matches!(
                get_general_category(c),
                GeneralCategory::Control
                    | GeneralCategory::Format
                    | GeneralCategory::PrivateUse
                    | GeneralCategory::Surrogate
                    | GeneralCategory::Unassigned
                    | GeneralCategory::LineSeparator
                    | GeneralCategory::ParagraphSeparator
            ) || (get_general_category(c) == GeneralCategory::SpaceSeparator && c != ' ')
        })
    {
        return Err(invalid);
    }
    Ok(s.to_owned())
}
pub fn exact_fields(value: &Value, fields: &[&str]) -> Result<()> {
    let map =
        value
            .as_object()
            .ok_or(ApiError::new(400, "invalid_json", "请求体必须是JSON对象"))?;
    if map.len() != fields.len() || fields.iter().any(|k| !map.contains_key(*k)) {
        return Err(ApiError::new(
            422,
            "invalid_fields",
            "请求字段不符合接口定义",
        ));
    }
    Ok(())
}
pub fn current_date(value: &Value, context: &Value) -> Result<String> {
    let s = value
        .as_str()
        .filter(|s| matches(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", s))
        .ok_or(ApiError::new(422, "invalid_date", "日期须为YYYY-MM-DD"))?;
    if NaiveDate::parse_from_str(s, "%Y-%m-%d").is_err() || s.starts_with("0000") {
        return Err(ApiError::new(422, "invalid_date", "日期无效"));
    }
    if context["date"] != s {
        return Err(ApiError::new(
            409,
            "day_changed",
            "仅可同步上海当日步数，请重新读取当日健康数据",
        ));
    }
    Ok(s.to_string())
}
pub fn page_size(value: Option<&String>) -> Result<i64> {
    match value {
        None => Ok(20),
        Some(s) if matches(r"^[0-9]{1,3}$", s) => s
            .parse::<i64>()
            .ok()
            .filter(|n| (1..=100).contains(n))
            .ok_or(ApiError::new(422, "invalid_limit", "每页数量须为1至100")),
        _ => Err(ApiError::new(422, "invalid_limit", "每页数量须为1至100")),
    }
}
pub fn circle(date: &str, steps: i64) -> Value {
    let lower = steps / CIRCLE_BAND_STEPS * CIRCLE_BAND_STEPS;
    json!({"id":format!("{}:{}-{}",date,lower,lower+CIRCLE_BAND_STEPS-1),"date":date,"min_steps":lower,"max_steps":lower+CIRCLE_BAND_STEPS-1,"band_steps":CIRCLE_BAND_STEPS})
}
pub fn cursor(snapshot: &str, channel: Option<&str>, offset: i64, limit: i64) -> String {
    let v = match channel {
        Some(c) => json!([snapshot, c, offset, limit]),
        None => json!([snapshot, offset, limit]),
    };
    URL_SAFE_NO_PAD.encode(serde_json::to_vec(&v).unwrap())
}
pub fn read_cursor(value: &str, snapshot: &str, channel: Option<&str>, limit: i64) -> Result<i64> {
    let invalid = ApiError::new(
        422,
        "invalid_cursor",
        "分页游标无效或每页数量已改变，请刷新",
    );
    if !matches(r"^[A-Za-z0-9_-]+$", value)
        || value.len() > if channel.is_some() { 384 } else { 256 }
    {
        return Err(invalid);
    }
    let raw = URL_SAFE_NO_PAD.decode(value).map_err(|_| invalid.clone())?;
    let decoded: Value = serde_json::from_slice(&raw).map_err(|_| invalid.clone())?;
    let array = decoded.as_array().ok_or(invalid.clone())?;
    let idx = if channel.is_some() { 2 } else { 1 };
    if array.len() != idx + 2 {
        return Err(invalid);
    }
    let saved = array[0]
        .as_str()
        .filter(|s| matches(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$", s))
        .ok_or(invalid.clone())?;
    let offset = array[idx]
        .as_i64()
        .filter(|n| *n >= 0)
        .ok_or(invalid.clone())?;
    let saved_limit = array[idx + 1]
        .as_i64()
        .filter(|n| *n == limit)
        .ok_or(invalid.clone())?;
    let saved_channel = if channel.is_some() {
        Some(
            array[1]
                .as_str()
                .filter(|s| matches(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}:[0-9]+-[0-9]+$", s))
                .ok_or(invalid.clone())?,
        )
    } else {
        None
    };
    if cursor(saved, saved_channel, offset, saved_limit) != value {
        return Err(invalid);
    }
    if saved != snapshot || saved_channel != channel {
        return Err(ApiError::new(
            409,
            if channel.is_some() {
                "circle_changed"
            } else {
                "leaderboard_changed"
            },
            "日期或成员已变化，请刷新",
        ));
    }
    Ok(offset)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn conversion_boundaries() {
        for (s, f, r) in [
            (0, 0, 100),
            (99, 0, 1),
            (100, 1, 100),
            (101, 1, 99),
            (MAX_STEPS, 10000, 100),
        ] {
            let p = progress(s).unwrap();
            assert_eq!(p["floor"], f);
            assert_eq!(p["remaining_steps"], r);
        }
        assert!(progress(-1).is_err());
        assert!(steps(&json!(true)).is_err());
        assert!(steps(&json!(1.0)).is_err());
    }
    #[test]
    fn midnight_year_and_device_zone() {
        let a = DateTime::parse_from_rfc3339("2026-12-31T15:59:59Z")
            .unwrap()
            .with_timezone(&Utc);
        let b = a + Duration::seconds(1);
        assert_eq!(day_context(a)["date"], "2026-12-31");
        assert_eq!(day_context(b)["date"], "2027-01-01");
        assert_eq!(day_context(a)["day_end"], day_context(b)["day_start"]);
        let c = DateTime::parse_from_rfc3339("2026-12-31T08:00:00-08:00")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(day_context(c), day_context(b));
    }
    #[test]
    fn bands_and_cursor_validation() {
        assert_eq!(circle("2026-11-14", 999)["min_steps"], 0);
        assert_eq!(circle("2026-11-14", 1000)["min_steps"], 1000);
        let c = cursor("2026-11-14.1", None, 20, 20);
        assert_eq!(read_cursor(&c, "2026-11-14.1", None, 20).unwrap(), 20);
        assert_eq!(
            read_cursor(&c, "2026-11-15.1", None, 20).unwrap_err().code,
            "leaderboard_changed"
        );
        assert!(read_cursor(&c, "2026-11-14.1", None, 10).is_err());
    }
    #[test]
    fn nickname_unicode_rules() {
        assert_eq!(nickname(&json!(" 爬楼 🪜 ")).unwrap(), "爬楼 🪜");
        for n in ["a\nb", "a\u{200b}b", "a\u{a0}b", ""] {
            assert!(nickname(&json!(n)).is_err());
        }
    }
}
