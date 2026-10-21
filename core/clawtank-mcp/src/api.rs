//! Minimal HTTP/1.1 client for ClawTank's Agent API. Loopback only: the token is never sent
//! anywhere else.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    pub fn json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).unwrap_or(serde_json::Value::Null)
    }
}

/// Transport to the Agent API (a trait so the MCP layer is testable without a server).
pub trait Api {
    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&serde_json::Value>,
    ) -> Result<Response, String>;
}

pub struct HttpApi {
    addr: SocketAddr,
    token: String,
}

impl HttpApi {
    /// `url` must be `http://127.0.0.1:<port>` or `http://localhost:<port>`.
    pub fn new(url: &str, token: String) -> Result<Self, String> {
        let rest = url
            .trim_end_matches('/')
            .strip_prefix("http://")
            .ok_or("CLAWTANK_AGENT_URL must start with http://")?;
        let (host, port) = rest.rsplit_once(':').unwrap_or((rest, "3390"));
        if host != "127.0.0.1" && host != "localhost" {
            return Err(
                "CLAWTANK_AGENT_URL must point at 127.0.0.1 (the Agent API is local only)".into(),
            );
        }
        let port: u16 = port.parse().map_err(|_| "bad port in CLAWTANK_AGENT_URL")?;
        Ok(Self {
            addr: SocketAddr::from(([127, 0, 0, 1], port)),
            token,
        })
    }
}

impl Api for HttpApi {
    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&serde_json::Value>,
    ) -> Result<Response, String> {
        let mut stream =
            TcpStream::connect_timeout(&self.addr, Duration::from_secs(3)).map_err(|e| {
                if e.kind() == std::io::ErrorKind::ConnectionRefused {
                    "ClawTank's Agent API is off. Turn it on in ClawTank → Settings → Agents."
                        .to_owned()
                } else {
                    format!("can't reach ClawTank at {}: {e}", self.addr)
                }
            })?;
        stream.set_read_timeout(Some(Duration::from_secs(60))).ok();
        let payload = body.map(|b| b.to_string()).unwrap_or_default();
        let request = format!(
            "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAuthorization: Bearer {}\r\n\
             Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
            self.addr.port(),
            self.token,
            payload.len()
        );
        stream
            .write_all(request.as_bytes())
            .map_err(|e| format!("send failed: {e}"))?;
        let mut raw = Vec::new();
        stream
            .read_to_end(&mut raw)
            .map_err(|e| format!("read failed: {e}"))?;
        parse_response(&raw)
    }
}

pub fn parse_response(raw: &[u8]) -> Result<Response, String> {
    let end = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("malformed response from ClawTank")?;
    let head = std::str::from_utf8(&raw[..end]).map_err(|_| "malformed response header")?;
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .and_then(|l| l.split(' ').nth(1))
        .and_then(|s| s.parse().ok())
        .ok_or("malformed status line")?;
    let headers = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(n, v)| (n.trim().to_owned(), v.trim().to_owned()))
        .collect::<Vec<_>>();
    let mut body = raw[end + 4..].to_vec();
    if let Some(len) = headers
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse::<usize>().ok())
    {
        body.truncate(len);
    }
    Ok(Response {
        status,
        headers,
        body,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_loopback_urls() {
        assert!(HttpApi::new("http://127.0.0.1:3390", "t".into()).is_ok());
        assert!(HttpApi::new("http://localhost:4000/", "t".into()).is_ok());
        assert!(HttpApi::new("http://10.0.0.2:3390", "t".into()).is_err());
        assert!(HttpApi::new("https://127.0.0.1:3390", "t".into()).is_err());
        assert!(HttpApi::new("http://127.0.0.1.evil.com:3390", "t".into()).is_err());
    }

    #[test]
    fn parses_response() {
        let raw = b"HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}junk";
        let response = parse_response(raw).unwrap();
        assert_eq!(response.status, 409);
        assert_eq!(response.header("content-type"), Some("application/json"));
        assert_eq!(response.body, b"{}");
    }
}
