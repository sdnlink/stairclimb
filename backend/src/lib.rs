pub mod auth;
pub mod chat;
pub mod domain;
pub mod http;
pub mod mail;
pub mod pool;
pub mod storage;
pub mod tls;

use serde_json::{json, Value};

#[derive(Debug, Clone)]
pub struct ApiError {
    pub status: u16,
    pub code: &'static str,
    pub message: &'static str,
}
pub type Result<T> = std::result::Result<T, ApiError>;
impl ApiError {
    pub fn new(status: u16, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
        }
    }
    pub fn payload(&self) -> Value {
        json!({"error":{"code":self.code,"message":self.message}})
    }
}
impl From<postgres::Error> for ApiError {
    fn from(_: postgres::Error) -> Self {
        Self::new(503, "storage_unavailable", "服务暂不可用，请稍后重试")
    }
}
