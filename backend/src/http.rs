//! Bounded HTTP/1 request parser: explicit JSON errors also cover malformed framing.
use crate::domain::{day_context, merge, Clock, MAX_BODY_BYTES};
use crate::storage::Application;
use crate::{ApiError, Result};
use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{json, Map, Number, Value};
use std::collections::HashMap;
use std::fmt;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct UniqueVisitor;
        impl<'de> Visitor<'de> for UniqueVisitor {
            type Value = Unique;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                write!(f, "JSON value without duplicate fields")
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> std::result::Result<Unique, E> {
                Number::from_f64(v)
                    .map(|n| Unique(Value::Number(n)))
                    .ok_or_else(|| E::custom("non-finite number"))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_string<E: de::Error>(self, v: String) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_none<E: de::Error>(self) -> std::result::Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_unit<E: de::Error>(self) -> std::result::Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(Unique(value)) = seq.next_element()? {
                    values.push(value);
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut map: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = Map::new();
                while let Some((key, Unique(value))) = map.next_entry::<String, Unique>()? {
                    if values.insert(key, value).is_some() {
                        return Err(de::Error::custom("duplicate field"));
                    }
                }
                Ok(Unique(Value::Object(values)))
            }
        }
        d.deserialize_any(UniqueVisitor)
    }
}
fn parse_json(raw: &[u8]) -> Result<Value> {
    match serde_json::from_slice::<Unique>(raw) {
        Ok(Unique(v)) if v.is_object() => Ok(v),
        Err(_e)
            if raw.windows(8).any(|s| s == b"nickname")
                && crate::domain::matches(
                    r"\\u[dD][89aAbBcCdDeEfF][0-9a-fA-F]{2}",
                    &String::from_utf8_lossy(raw),
                ) =>
        {
            Err(ApiError::new(422, "invalid_nickname", "昵称包含无效字符"))
        }
        _ => Err(ApiError::new(
            400,
            "invalid_json",
            "请求体必须是合法的JSON对象",
        )),
    }
}
fn io_error(error: std::io::Error) -> ApiError {
    if matches!(
        error.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    ) {
        ApiError::new(408, "request_timeout", "请求超时")
    } else {
        ApiError::new(400, "invalid_body", "请求体不完整")
    }
}
fn query(path: &str, raw: &str) -> Result<HashMap<String, String>> {
    let allowed: &[&str] = match path {
        "/v1/leaderboard" => &["limit", "cursor"],
        "/v1/leaderboard/me" | "/v1/circles/current" | "/v1/circles/current/me" => {
            &["limit", "snapshot"]
        }
        "/v1/circles/current/messages" => &["circle_id", "limit", "before", "after"],
        "/v1/circles/current/blocks" => &["circle_id"],
        "/v1/circles/current/members" => &["limit", "cursor", "snapshot"],
        _ => &[],
    };
    let invalid = ApiError::new(400, "invalid_query", "查询参数不符合接口定义");
    if !raw.is_empty() && (raw.split('&').count() > 10 || raw.split('&').any(|s| !s.contains('=')))
    {
        return Err(invalid);
    }
    let mut params = HashMap::new();
    for (key, value) in url::form_urlencoded::parse(raw.as_bytes()) {
        if !allowed.contains(&key.as_ref())
            || params
                .insert(key.into_owned(), value.into_owned())
                .is_some()
        {
            return Err(invalid);
        }
    }
    Ok(params)
}
struct Request {
    method: String,
    path: String,
    params: HashMap<String, String>,
    authorization: Option<String>,
    body: Value,
}
fn read_request(stream: &mut impl Read) -> Result<Request> {
    let mut header = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        let n = stream.read(&mut byte).map_err(io_error)?;
        if n == 0 {
            return Err(ApiError::new(400, "http_error", "HTTP请求无效"));
        }
        header.push(byte[0]);
        if header.ends_with(b"\r\n\r\n") {
            break;
        }
        if header.len() > 16384 {
            return Err(ApiError::new(431, "http_error", "HTTP头部过大"));
        }
    }
    let text = std::str::from_utf8(&header)
        .map_err(|_| ApiError::new(400, "http_error", "HTTP请求无效"))?;
    let mut lines = text.split("\r\n");
    let line = lines.next().unwrap();
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("").to_owned();
    let target = parts.next().unwrap_or("");
    let version = parts.next().unwrap_or("");
    if parts.next().is_some() || !matches!(version, "HTTP/1.0" | "HTTP/1.1") || method.is_empty() {
        return Err(ApiError::new(400, "http_error", "HTTP请求无效"));
    }
    if target.len() > 2048 {
        return Err(ApiError::new(414, "uri_too_long", "请求路径过长"));
    }
    if !target.starts_with('/') || target.starts_with("//") || target.contains('#') {
        return Err(ApiError::new(400, "invalid_query", "请求路径无效"));
    }
    let (path, raw_query) = target.split_once('?').unwrap_or((target, ""));
    let mut headers: HashMap<String, Vec<String>> = HashMap::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let (name, value) =
            line.split_once(':')
                .ok_or(ApiError::new(400, "http_error", "HTTP请求头无效"))?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err(ApiError::new(400, "http_error", "HTTP请求头无效"));
        }
        headers
            .entry(name.to_ascii_lowercase())
            .or_default()
            .push(value.trim().to_owned());
    }
    let body = if matches!(method.as_str(), "POST" | "PUT" | "PATCH" | "DELETE") {
        if headers.contains_key("transfer-encoding") {
            return Err(ApiError::new(400, "invalid_body", "不支持分块请求体"));
        }
        let lengths = headers.get("content-length").ok_or(ApiError::new(
            411,
            "length_required",
            "需要Content-Length",
        ))?;
        if lengths.len() != 1
            || lengths[0].is_empty()
            || !lengths[0].bytes().all(|b| b.is_ascii_digit())
        {
            return Err(ApiError::new(400, "invalid_body", "Content-Length无效"));
        }
        if lengths[0].len() > 8 {
            return Err(ApiError::new(
                413,
                "body_too_large",
                "请求体超过接口字节上限",
            ));
        }
        let length = lengths[0]
            .parse::<usize>()
            .map_err(|_| ApiError::new(400, "invalid_body", "Content-Length无效"))?;
        let body_limit = if method == "POST" && path == "/v1/circles/current/messages" {
            16_384
        } else {
            MAX_BODY_BYTES
        };
        if length > body_limit {
            return Err(ApiError::new(
                413,
                "body_too_large",
                "请求体超过接口字节上限",
            ));
        }
        if headers
            .get("content-type")
            .and_then(|v| v.first())
            .map(|s| {
                s.split(';')
                    .next()
                    .unwrap()
                    .trim()
                    .eq_ignore_ascii_case("application/json")
            })
            != Some(true)
        {
            return Err(ApiError::new(
                415,
                "json_required",
                "请使用application/json",
            ));
        }
        let mut raw = vec![0u8; length];
        stream.read_exact(&mut raw).map_err(io_error)?;
        parse_json(&raw)?
    } else {
        json!({})
    };
    let authorization = headers
        .get("authorization")
        .filter(|v| v.len() == 1)
        .map(|v| v[0].clone());
    Ok(Request {
        method,
        path: path.to_owned(),
        params: query(path, raw_query)?,
        authorization,
        body,
    })
}
fn reply(stream: &mut impl Write, status: u16, payload: Value, head: bool) {
    let data = serde_json::to_vec(&payload).unwrap();
    let title = match status {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        429 => "Too Many Requests",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        411 => "Length Required",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Entity",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        _ => "Error",
    };
    let _=write!(stream,"HTTP/1.1 {status} {title}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",data.len());
    if !head {
        let _ = stream.write_all(&data);
    }
    let _ = stream.flush();
}
fn serve(stream: TcpStream, app: Arc<Application>, tls: Option<Arc<rustls::ServerConfig>>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let source = stream
        .peer_addr()
        .map(|p| p.ip().to_string())
        .unwrap_or_else(|_| "unknown".to_owned());
    let Ok(mut stream) = crate::tls::Wire::new(stream, tls) else {
        return;
    };
    let mut head = false;
    let result = read_request(&mut stream).and_then(|r| {
        head = r.method == "HEAD";
        app.dispatch_from(
            &r.method,
            &r.path,
            r.authorization.as_deref(),
            &r.body,
            &r.params,
            &source,
        )
    });
    match result {
        Ok((status, payload)) => reply(&mut stream, status, payload, head),
        Err(error) => {
            let payload = if error.status == 503 {
                error.payload()
            } else {
                app.clock
                    .now()
                    .map(|now| merge(error.payload(), day_context(now)))
                    .unwrap_or(error.payload())
            };
            reply(&mut stream, error.status, payload, head);
            stream.finish();
            close_after_rejection(stream.socket());
        }
    }
    stream.finish();
}
fn close_after_rejection(stream: &mut TcpStream) {
    // A rejected length/type can leave bytes unread. Closing immediately may
    // reset TCP and discard our JSON response. Send FIN, then consume only a
    // bounded amount of arriving data; never trust the rejected length.
    let _ = stream.shutdown(Shutdown::Write);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(30)));
    let deadline = std::time::Instant::now() + Duration::from_millis(60);
    let mut remaining = 65536;
    let mut bytes = [0; 4096];
    while remaining > 0 && std::time::Instant::now() < deadline {
        let limit = remaining.min(bytes.len());
        match stream.read(&mut bytes[..limit]) {
            Ok(0) | Err(_) => break,
            Ok(count) => remaining -= count,
        }
    }
}
pub fn run(test_mode: bool) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let mut host = std::env::var("STAIRCLIMB_HOST").unwrap_or_else(|_| "127.0.0.1".to_owned());
    let mut port = std::env::var("STAIRCLIMB_PORT").unwrap_or_else(|_| "8787".to_owned());
    #[allow(unused_mut)]
    let mut clock = Clock::Real;
    let mut email_only = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let value = args.next().ok_or("missing argument value")?;
        match arg.as_str() {
            "--email-only" if test_mode && value == "true" => email_only = true,
            "--host" => host = value,
            "--port" => port = value,
            "--clock-file" if test_mode => {
                #[cfg(feature = "test-support")]
                {
                    clock = Clock::File(value.into());
                }
                #[cfg(not(feature = "test-support"))]
                {
                    let _ = value;
                    return Err("test support unavailable".into());
                }
            }
            _ => return Err("unsupported argument".into()),
        }
    }
    // The production binary never reads a test clock from environment or HTTP.
    if !test_mode && std::env::var_os("STAIRCLIMB_TEST_CLOCK").is_some() {
        return Err("test clock unavailable in production".into());
    }
    let tls = crate::tls::configured()?;
    // Only TLS may listen outside loopback; internal plaintext remains test/local only.
    if tls.is_none()
        && !host
            .parse::<std::net::IpAddr>()
            .map(|ip| ip.is_loopback())
            .unwrap_or(false)
    {
        return Err("HTTP listener must be a literal loopback address".into());
    }
    let database_url = std::env::var("DATABASE_URL")?;
    let mut app = Application::with_pool(
        database_url,
        clock,
        crate::pool::PoolConfig::from_env().map_err(|_| "invalid database pool configuration")?,
    )
    .map_err(|_| "database unavailable")?;
    // Only the test binary can use anonymous regression fixtures. Production never opts in.
    app.legacy_test_mode = test_mode && !email_only;
    // The production executable always passes test_mode=false. Chat remains closed.
    app.chat_test_mode = test_mode
        && cfg!(feature = "test-support")
        && std::env::var("STAIRCLIMB_TEST_CHAT").as_deref() == Ok("1");
    let app = Arc::new(app);
    let listener = TcpListener::bind((host.as_str(), port.parse::<u16>()?))?;
    println!("Stairclimb Rust listening on {}:{}; timezone=Asia/Shanghai; database=PostgreSQL; migration=4; transport={}",host,listener.local_addr()?.port(), if tls.is_some() { "HTTPS" } else { "internal-HTTP" });
    std::io::stdout().flush()?;
    let active = Arc::new(AtomicUsize::new(0));
    for socket in listener.incoming() {
        let mut stream = socket?;
        if active.fetch_add(1, Ordering::SeqCst) >= 64 {
            active.fetch_sub(1, Ordering::SeqCst);
            if tls.is_some() {
                let _ = stream.shutdown(Shutdown::Both);
                continue;
            }
            reply(
                &mut stream,
                503,
                ApiError::new(503, "service_busy", "服务繁忙，请稍后重试").payload(),
                false,
            );
            continue;
        }
        let app = app.clone();
        let active = active.clone();
        let tls = tls.clone();
        std::thread::spawn(move || {
            serve(stream, app, tls);
            active.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejected_body_json_survives_tcp_close() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for _ in 0..24 {
                let (mut stream, _) = listener.accept().unwrap();
                let error = match read_request(&mut stream) {
                    Err(error) => error,
                    Ok(_) => panic!("Oversized body was accepted"),
                };
                assert_eq!(error.code, "body_too_large");
                reply(&mut stream, error.status, error.payload(), false);
                close_after_rejection(&mut stream);
            }
        });
        for _ in 0..24 {
            let mut client = TcpStream::connect(address).unwrap();
            client
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            write!(client, "POST /v1/users HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 4097\r\n\r\n{}", "x".repeat(4097)).unwrap();
            let mut response = String::new();
            client.read_to_string(&mut response).unwrap();
            let (header, body) = response.split_once("\r\n\r\n").unwrap();
            assert!(header.starts_with("HTTP/1.1 413 "));
            assert_eq!(
                serde_json::from_str::<Value>(body).unwrap()["error"]["code"],
                "body_too_large"
            );
        }
        server.join().unwrap();
    }
    #[test]
    fn duplicate_and_nonstandard_json_rejected() {
        for raw in [
            r#"{"nickname":"A","nickname":"B"}"#,
            r#"{"nickname":NaN}"#,
            r#"[]"#,
            r#"{"x":{"a":1,"a":2}}"#,
        ] {
            assert_eq!(parse_json(raw.as_bytes()).unwrap_err().code, "invalid_json");
        }
    }
    #[test]
    fn surrogate_nickname_keeps_legacy_validation_contract() {
        assert_eq!(
            parse_json(br#"{"nickname":"a\ud800b"}"#).unwrap_err().code,
            "invalid_nickname"
        );
        assert_eq!(
            parse_json(br#"{"nickname":"\ud83e\ude9c"}"#).unwrap()["nickname"],
            "🪜"
        );
    }
    #[test]
    fn query_identity_and_duplicates_rejected() {
        assert!(query("/v1/me", "user_id=x").is_err());
        assert!(query("/v1/leaderboard", "limit=1&limit=2").is_err());
        assert!(query("/v1/leaderboard", "limit").is_err());
        assert_eq!(query("/v1/leaderboard", "limit=1").unwrap()["limit"], "1");
    }
}
