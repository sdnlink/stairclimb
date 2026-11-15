//! Native TLS: no plaintext fallback when certificate configuration is present.
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::Arc;

pub fn configured() -> Result<Option<Arc<ServerConfig>>, Box<dyn std::error::Error>> {
    let certificate = std::env::var_os("STAIRCLIMB_TLS_CERT");
    let key = std::env::var_os("STAIRCLIMB_TLS_KEY");
    match (certificate, key) {
        (None, None) => Ok(None),
        (Some(certificate), Some(key)) => {
            let cert_bytes = std::fs::read(certificate)?;
            let key_bytes = std::fs::read(key)?;
            if cert_bytes.len() > 65536 || key_bytes.len() > 16384 {
                return Err("TLS file exceeds limit".into());
            }
            let certificates =
                rustls_pemfile::certs(&mut cert_bytes.as_slice()).collect::<Result<Vec<_>, _>>()?;
            let key =
                rustls_pemfile::private_key(&mut key_bytes.as_slice())?.ok_or("TLS key missing")?;
            let mut config = ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_protocol_versions(&[&rustls::version::TLS13, &rustls::version::TLS12])?
            .with_no_client_auth()
            .with_single_cert(certificates, key)?;
            config.alpn_protocols = vec![b"http/1.1".to_vec()];
            Ok(Some(Arc::new(config)))
        }
        _ => Err("TLS certificate and key must both be configured".into()),
    }
}

pub enum Wire {
    Plain(TcpStream),
    Secure(Box<StreamOwned<ServerConnection, TcpStream>>),
}
impl Wire {
    pub fn new(mut socket: TcpStream, config: Option<Arc<ServerConfig>>) -> io::Result<Self> {
        if let Some(config) = config {
            let mut connection = ServerConnection::new(config).map_err(io::Error::other)?;
            // Reject plaintext/invalid handshakes without emitting a plaintext HTTP response.
            while connection.is_handshaking() {
                connection.complete_io(&mut socket)?;
            }
            Ok(Self::Secure(Box::new(StreamOwned::new(connection, socket))))
        } else {
            Ok(Self::Plain(socket))
        }
    }
    pub fn socket(&mut self) -> &mut TcpStream {
        match self {
            Self::Plain(socket) => socket,
            Self::Secure(stream) => &mut stream.sock,
        }
    }
    pub fn finish(&mut self) {
        if let Self::Secure(stream) = self {
            stream.conn.send_close_notify();
            let _ = stream.flush();
        }
    }
}
impl Read for Wire {
    fn read(&mut self, data: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Plain(stream) => stream.read(data),
            Self::Secure(stream) => stream.read(data),
        }
    }
}
impl Write for Wire {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        match self {
            Self::Plain(stream) => stream.write(data),
            Self::Secure(stream) => stream.write(data),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Plain(stream) => stream.flush(),
            Self::Secure(stream) => stream.flush(),
        }
    }
}
