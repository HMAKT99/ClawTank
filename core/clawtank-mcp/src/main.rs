//! `clawtank-mcp`: an MCP server over stdio for ClawTank's Agent API (docs/agent-api.md).
//!
//! Environment: `CLAWTANK_AGENT_TOKEN` (required, from ClawTank → Settings → Agents) and
//! `CLAWTANK_AGENT_URL` (default `http://127.0.0.1:3390`). Logs go to stderr; stdout carries
//! only JSON-RPC messages, one per line.

mod api;
mod mcp;

use std::io::{BufRead, Write};

use serde_json::{Value, json};

fn main() {
    let token = std::env::var("CLAWTANK_AGENT_TOKEN").unwrap_or_default();
    if token.is_empty() {
        eprintln!(
            "clawtank-mcp: set CLAWTANK_AGENT_TOKEN (create one in ClawTank → Settings → Agents)"
        );
    }
    let url =
        std::env::var("CLAWTANK_AGENT_URL").unwrap_or_else(|_| "http://127.0.0.1:3390".into());
    let api = match api::HttpApi::new(&url, token) {
        Ok(api) => api,
        Err(message) => {
            eprintln!("clawtank-mcp: {message}");
            std::process::exit(2);
        }
    };
    let server = mcp::Server::new(api);
    let stdout = std::io::stdout();
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(message) => server.handle(&message),
            Err(_) => Some(json!({ "jsonrpc": "2.0", "id": null,
                                   "error": { "code": -32700, "message": "parse error" } })),
        };
        if let Some(reply) = reply {
            let mut out = stdout.lock();
            if writeln!(out, "{reply}").and_then(|()| out.flush()).is_err() {
                break;
            }
        }
    }
}
