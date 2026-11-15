//! Synchronous bounded pool. A lease exclusively owns its Client and returns it on drop.
use crate::{ApiError, Result};
use postgres::{Client, Config, NoTls};
use std::ops::{Deref, DerefMut};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy)]
pub struct PoolConfig {
    pub max_connections: usize,
    pub acquire_timeout: Duration,
}
impl Default for PoolConfig {
    fn default() -> Self {
        Self {
            max_connections: 8,
            acquire_timeout: Duration::from_millis(1500),
        }
    }
}
impl PoolConfig {
    pub fn from_env() -> Result<Self> {
        let defaults = Self::default();
        fn number(key: &str, default: usize) -> Result<usize> {
            match std::env::var(key) {
                Ok(s) => s.parse().map_err(|_| configuration()),
                Err(std::env::VarError::NotPresent) => Ok(default),
                Err(_) => Err(configuration()),
            }
        }
        let result = Self {
            max_connections: number("STAIRCLIMB_DB_POOL_MAX", defaults.max_connections)?,
            acquire_timeout: Duration::from_millis(
                number("STAIRCLIMB_DB_POOL_TIMEOUT_MS", 1500)? as u64
            ),
        };
        result.validate()?;
        Ok(result)
    }
    fn validate(self) -> Result<()> {
        if !(1..=64).contains(&self.max_connections)
            || !(Duration::from_millis(10)..=Duration::from_secs(30))
                .contains(&self.acquire_timeout)
        {
            return Err(configuration());
        }
        Ok(())
    }
}
fn configuration() -> ApiError {
    ApiError::new(503, "invalid_pool_config", "数据库连接池配置无效")
}
fn exhausted() -> ApiError {
    ApiError::new(503, "database_busy", "数据库连接繁忙，请稍后重试")
}
struct State {
    idle: Vec<Client>,
    total: usize, // Includes connection creation reservations and checked-out clients.
    failures: u64,
}
struct Inner {
    database: Config,
    settings: PoolConfig,
    state: Mutex<State>,
    available: Condvar,
}
#[derive(Clone)]
pub struct Pool(Arc<Inner>);
pub struct Lease {
    client: Option<Client>,
    pool: Pool,
}
impl Pool {
    pub fn new(url: &str, settings: PoolConfig) -> Result<Self> {
        settings.validate()?;
        let database: Config = url.parse().map_err(|_| configuration())?;
        Ok(Self(Arc::new(Inner {
            database,
            settings,
            state: Mutex::new(State {
                idle: Vec::new(),
                total: 0,
                failures: 0,
            }),
            available: Condvar::new(),
        })))
    }
    pub fn get(&self) -> Result<Lease> {
        let deadline = Instant::now() + self.0.settings.acquire_timeout;
        let mut state = self.0.state.lock().unwrap();
        let failures = state.failures;
        let mut creating = false;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(exhausted());
            }
            while let Some(client) = state.idle.pop() {
                if client.is_closed() {
                    state.total -= 1;
                } else {
                    return Ok(Lease {
                        client: Some(client),
                        pool: self.clone(),
                    });
                }
            }
            if state.failures != failures {
                return Err(ApiError::new(
                    503,
                    "storage_unavailable",
                    "服务暂不可用，请稍后重试",
                ));
            }
            if !creating && state.total < self.0.settings.max_connections {
                state.total += 1;
                creating = true;
                let pool = self.clone();
                // A bounded reservation also covers DNS/authentication. The caller waits
                // on the deadline, never directly inside a potentially stalled handshake.
                // Late success becomes idle; failed creation releases its reservation.
                let worker = std::thread::Builder::new()
                    .name("postgres-connect".into())
                    .spawn(move || {
                        let mut config = pool.0.database.clone();
                        config.connect_timeout(pool.0.settings.acquire_timeout);
                        let result = config.connect(NoTls);
                        let mut state = pool.0.state.lock().unwrap();
                        match result {
                            Ok(client) => state.idle.push(client),
                            Err(_) => {
                                state.total -= 1;
                                state.failures = state.failures.wrapping_add(1);
                            }
                        }
                        pool.0.available.notify_all();
                    });
                if worker.is_err() {
                    state.total -= 1;
                    self.0.available.notify_all();
                    return Err(exhausted());
                }
            }
            let (next, _) = self.0.available.wait_timeout(state, remaining).unwrap();
            state = next;
        }
    }
}
impl Deref for Lease {
    type Target = Client;
    fn deref(&self) -> &Client {
        self.client.as_ref().unwrap()
    }
}
impl DerefMut for Lease {
    fn deref_mut(&mut self) -> &mut Client {
        self.client.as_mut().unwrap()
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        let client = self.client.take().unwrap();
        let mut state = self.pool.0.state.lock().unwrap();
        if client.is_closed() {
            state.total -= 1;
        } else {
            state.idle.push(client);
        }
        self.pool.0.available.notify_one();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    #[test]
    fn stalled_database_handshake_cannot_exceed_acquisition_deadline_or_create_more_slots() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!(
            "postgresql://fixture@127.0.0.1:{}/fixture",
            listener.local_addr().unwrap().port()
        );
        let pool = Pool::new(
            &url,
            PoolConfig {
                max_connections: 1,
                acquire_timeout: Duration::from_millis(60),
            },
        )
        .unwrap();
        let start = Instant::now();
        assert_eq!(pool.get().err().unwrap().code, "database_busy");
        assert!(start.elapsed() < Duration::from_millis(500));
        let (socket, _) = listener.accept().unwrap();
        assert_eq!(pool.get().err().unwrap().code, "database_busy");
        assert!(
            listener.accept().is_err(),
            "stalled creation must retain its single bounded slot"
        );
        drop(socket);
        drop(listener);
        let deadline = Instant::now() + Duration::from_secs(1);
        while pool.0.state.lock().unwrap().total != 0 {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[test]
    fn invalid_pool_limits_fail_without_opening_connections() {
        for (max, ms) in [(0, 10), (65, 10), (1, 0), (1, 30001)] {
            assert_eq!(
                Pool::new(
                    "postgresql://fixture@127.0.0.1/fixture",
                    PoolConfig {
                        max_connections: max,
                        acquire_timeout: Duration::from_millis(ms)
                    }
                )
                .err()
                .unwrap()
                .code,
                "invalid_pool_config"
            );
        }
    }
}
