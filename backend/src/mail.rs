//! SMTP delivery is explicit: authenticated TLS, mandatory STARTTLS, or loopback capture.
use crate::{ApiError, Result};
use lettre::transport::smtp::{
    authentication::Credentials,
    client::{Tls, TlsParameters, TlsVersion},
};
use lettre::{Message, SmtpTransport, Transport};
use std::{net::IpAddr, time::Duration};

fn unavailable() -> ApiError {
    ApiError::new(
        503,
        "mail_unavailable",
        "邮件服务未配置或发送失败，请稍后重试",
    )
}

pub fn send(email: &str, purpose: &str, token: &str) -> Result<()> {
    let host = std::env::var("SMTP_HOST").map_err(|_| unavailable())?;
    let port = std::env::var("SMTP_PORT")
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .filter(|p| *p > 0)
        .ok_or_else(unavailable)?;
    let mode = std::env::var("SMTP_MODE").map_err(|_| unavailable())?;
    let from = std::env::var("SMTP_FROM").map_err(|_| unavailable())?;
    let builder = match mode.as_str() {
        "tls" | "starttls" => {
            let tls = TlsParameters::builder(host.clone())
                .set_min_tls_version(TlsVersion::Tlsv12)
                .build()
                .map_err(|_| unavailable())?;
            let tls = if mode == "tls" {
                Tls::Wrapper(tls)
            } else {
                Tls::Required(tls)
            };
            SmtpTransport::builder_dangerous(&host).tls(tls)
        }
        "local-capture"
            if host
                .parse::<IpAddr>()
                .map(|ip| ip.is_loopback())
                .unwrap_or(false)
                && std::env::var_os("SMTP_USERNAME").is_none()
                && std::env::var_os("SMTP_PASSWORD").is_none() =>
        {
            SmtpTransport::builder_dangerous(&host)
        }
        _ => return Err(unavailable()),
    };
    let mut builder = builder.port(port).timeout(Some(Duration::from_secs(3)));
    if mode != "local-capture" {
        let username = std::env::var("SMTP_USERNAME").map_err(|_| unavailable())?;
        let password = std::env::var("SMTP_PASSWORD").map_err(|_| unavailable())?;
        builder = builder.credentials(Credentials::new(username, password));
    }
    let title = if purpose == "verify" {
        "爬楼梯：邮箱验证"
    } else {
        "爬楼梯：密码重置"
    };
    let message = Message::builder()
        .from(from.parse().map_err(|_| unavailable())?)
        .to(email.parse().map_err(|_| unavailable())?)
        .subject(title)
        .body(format!("请在爬楼梯应用中输入以下一次性凭据。仅当请求适用于账号时有效，15分钟后失效。\n\n{token}\n\n邮箱验证还需输入注册时的密码；旧身份绑定还需原设备凭证。注册和验证不会自动公开运动数据。若非本人操作，请忽略。"))
        .map_err(|_| unavailable())?;
    builder.build().send(&message).map_err(|_| unavailable())?;
    Ok(())
}
