//! MCP server logic (JSON-RPC 2.0): initialize, tools/list, tools/call. Each tool maps to one
//! Agent API request.
//!
//! Coordinates: screenshots are scaled to at most `MAX_WIDTH` pixels wide, and every tool takes
//! and reports coordinates *in screenshot pixels*. The server remembers each display's
//! points-per-pixel from its last screenshot and converts, so agents never deal with Retina
//! scaling.

use std::cell::RefCell;
use std::collections::HashMap;

use base64::Engine as _;
use serde_json::{Value, json};

use crate::api::{Api, Response};

pub const MAX_WIDTH: u32 = 1568;
const PROTOCOL_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

pub struct Server<A: Api> {
    api: A,
    /// Display id → points per screenshot pixel (0 = main display when none given).
    scales: RefCell<HashMap<u32, f64>>,
}

impl<A: Api> Server<A> {
    pub fn new(api: A) -> Self {
        Self {
            api,
            scales: RefCell::default(),
        }
    }

    /// Handles one JSON-RPC message; returns the reply (None for notifications).
    pub fn handle(&self, message: &Value) -> Option<Value> {
        let id = message.get("id").cloned();
        let method = message.get("method").and_then(Value::as_str).unwrap_or("");
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let id = id?; // notifications (no id) get no reply
        let result = match method {
            "initialize" => Ok(initialize(&params)),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": tools() })),
            "tools/call" => self.call_tool(&params),
            _ => Err((-32601, format!("method not found: {method}"))),
        };
        Some(match result {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err((code, message)) => {
                json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
            }
        })
    }

    fn call_tool(&self, params: &Value) -> Result<Value, (i64, String)> {
        let name = params.get("name").and_then(Value::as_str).unwrap_or("");
        let args = params.get("arguments").cloned().unwrap_or(json!({}));
        let outcome = match name {
            "list_displays" => self.get("/v1/displays").map(|r| text(pretty(&r.json()))),
            "screenshot" => self.screenshot(&args),
            "get_state" => self.state(),
            "click" | "move_mouse" | "drag" | "scroll" | "press_key" | "type_text" => {
                self.input(name, &args)
            }
            "open_app" => {
                let app = str_arg(&args, "name")?;
                self.post("/v1/apps/open", &json!({ "name": app }))
                    .map(|r| {
                        text(format!(
                            "Opened {}",
                            r.json()["app"].as_str().unwrap_or(&app)
                        ))
                    })
            }
            "create_virtual_display" => {
                let body = json!({
                    "width": args.get("width").and_then(Value::as_u64).unwrap_or(1920),
                    "height": args.get("height").and_then(Value::as_u64).unwrap_or(1080),
                    "hidpi": args.get("hidpi").and_then(Value::as_bool).unwrap_or(false),
                });
                self.post("/v1/virtual-displays", &body).map(|r| {
                    text(format!(
                        "Created virtual display {} (use it as `display` in other tools)",
                        r.json()["id"]
                    ))
                })
            }
            "remove_virtual_display" => {
                let id = args
                    .get("id")
                    .and_then(Value::as_u64)
                    .ok_or((-32602, "\"id\" is required".to_owned()))?;
                self.request("DELETE", &format!("/v1/virtual-displays/{id}"), None)
                    .map(|_| text(format!("Removed virtual display {id}")))
            }
            _ => return Err((-32602, format!("unknown tool: {name}"))),
        };
        Ok(match outcome {
            Ok(result) => result,
            Err(message) => {
                json!({ "content": [{ "type": "text", "text": message }], "isError": true })
            }
        })
    }

    fn screenshot(&self, args: &Value) -> Result<Value, String> {
        let display = args.get("display").and_then(Value::as_u64);
        let max_width = args
            .get("max_width")
            .and_then(Value::as_u64)
            .map_or(MAX_WIDTH, |w| (w as u32).clamp(64, MAX_WIDTH));
        let jpeg = args.get("format").and_then(Value::as_str) == Some("jpeg");
        let mut path = format!("/v1/screenshot?max_width={max_width}");
        if let Some(display) = display {
            path += &format!("&display={display}");
        }
        if jpeg {
            path += "&format=jpeg";
        }
        let response = self.get(&path)?;
        let shown = response
            .header("x-clawtank-display")
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(0);
        let scale = response
            .header("x-clawtank-points-per-pixel")
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(1.0);
        {
            let mut scales = self.scales.borrow_mut();
            scales.insert(shown, scale);
            if display.is_none() {
                scales.insert(0, scale);
            }
        }
        let (width, height) = (
            response.header("x-clawtank-width").unwrap_or("?"),
            response.header("x-clawtank-height").unwrap_or("?"),
        );
        let mime = response
            .header("content-type")
            .unwrap_or("image/png")
            .to_owned();
        Ok(json!({ "content": [
            { "type": "image", "data": base64::engine::general_purpose::STANDARD.encode(&response.body),
              "mimeType": mime },
            { "type": "text", "text": format!(
                "Display {shown}, {width}×{height} pixels. Coordinates for click, move_mouse, drag and \
                 scroll are in this screenshot's pixels.") }
        ]}))
    }

    fn state(&self) -> Result<Value, String> {
        let mut state = self.get("/v1/state")?.json();
        // Report the cursor in screenshot pixels, like every other coordinate.
        if let Some(cursor) = state.get_mut("cursor") {
            let display = cursor["display"].as_u64().unwrap_or(0) as u32;
            let scale = self.scale(Some(display));
            for axis in ["x", "y"] {
                if let Some(v) = cursor[axis].as_f64() {
                    cursor[axis] = json!((v / scale).round() as i64);
                }
            }
        }
        Ok(text(pretty(&state)))
    }

    fn input(&self, tool: &str, args: &Value) -> Result<Value, String> {
        let display = args
            .get("display")
            .and_then(Value::as_u64)
            .map(|d| d as u32);
        let scale = self.scale(display);
        let point = |key: &str| -> Result<f64, String> {
            args.get(key)
                .and_then(Value::as_f64)
                .map(|v| v * scale)
                .ok_or(format!("\"{key}\" is required"))
        };
        let mut action = match tool {
            "click" => json!({
                "type": "click", "x": point("x")?, "y": point("y")?,
                "button": args.get("button").and_then(Value::as_str).unwrap_or("left"),
                "count": args.get("count").and_then(Value::as_u64).unwrap_or(1),
            }),
            "move_mouse" => json!({ "type": "move", "x": point("x")?, "y": point("y")? }),
            "drag" => json!({
                "type": "drag", "from_x": point("from_x")?, "from_y": point("from_y")?,
                "to_x": point("to_x")?, "to_y": point("to_y")?,
            }),
            "scroll" => {
                let mut scroll = json!({
                    "type": "scroll",
                    "dx": args.get("dx").and_then(Value::as_i64).unwrap_or(0),
                    "dy": args.get("dy").and_then(Value::as_i64).unwrap_or(0),
                });
                if args.get("x").is_some() && args.get("y").is_some() {
                    scroll["x"] = json!(point("x")?);
                    scroll["y"] = json!(point("y")?);
                }
                scroll
            }
            "press_key" => json!({ "type": "key", "key": str_arg(args, "key").map_err(|e| e.1)? }),
            _ => json!({ "type": "type", "text": str_arg(args, "text").map_err(|e| e.1)? }),
        };
        if let Some(display) = display {
            action["display"] = json!(display);
        }
        self.post("/v1/input", &json!({ "actions": [action] }))
            .map(|_| text("Done. Take a screenshot to see the result.".into()))
    }

    fn scale(&self, display: Option<u32>) -> f64 {
        let scales = self.scales.borrow();
        scales.get(&display.unwrap_or(0)).copied().unwrap_or(1.0)
    }

    fn get(&self, path: &str) -> Result<Response, String> {
        self.request("GET", path, None)
    }

    fn post(&self, path: &str, body: &Value) -> Result<Response, String> {
        self.request("POST", path, Some(body))
    }

    fn request(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Response, String> {
        let response = self.api.call(method, path, body)?;
        if response.status == 200 {
            return Ok(response);
        }
        let message = response.json()["error"]
            .as_str()
            .map_or_else(|| format!("HTTP {}", response.status), str::to_owned);
        Err(match response.status {
            401 => format!(
                "{message}. Create a token in ClawTank → Settings → Agents and set CLAWTANK_AGENT_TOKEN."
            ),
            409 => format!("{message}. A person is controlling the Mac; wait and try again."),
            _ => message,
        })
    }
}

fn initialize(params: &Value) -> Value {
    let requested = params.get("protocolVersion").and_then(Value::as_str);
    let version = requested
        .filter(|v| PROTOCOL_VERSIONS.contains(v))
        .unwrap_or(PROTOCOL_VERSIONS[0]);
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": {} },
        "serverInfo": { "name": "clawtank", "version": env!("CARGO_PKG_VERSION") },
        "instructions": "Controls a Mac through ClawTank. Start with `screenshot`; coordinates in all tools \
                         are pixels of the latest screenshot of that display. Prefer `open_app` and \
                         `press_key` shortcuts over clicking where possible. A person using the Mac \
                         always takes priority (actions then fail with a retry hint)."
    })
}

fn text(message: String) -> Value {
    json!({ "content": [{ "type": "text", "text": message }] })
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_default()
}

fn str_arg(args: &Value, key: &str) -> Result<String, (i64, String)> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or((-32602, format!("\"{key}\" is required")))
}

fn tools() -> Value {
    let display = json!({ "type": "integer", "description": "Display id from list_displays (default: main display)" });
    let xy = |what: &str| json!({ "type": "number", "description": format!("{what}, in screenshot pixels") });
    json!([
        { "name": "list_displays", "description": "List this Mac's displays (id, size in points, scale, main, virtual).",
          "inputSchema": { "type": "object", "properties": {} },
          "annotations": { "readOnlyHint": true } },
        { "name": "screenshot", "description": "Capture a display as an image. Coordinates for other tools are pixels of this image.",
          "inputSchema": { "type": "object", "properties": {
              "display": display,
              "max_width": { "type": "integer", "description": format!("Image width limit (default and max {MAX_WIDTH})") },
              "format": { "type": "string", "enum": ["png", "jpeg"] } } },
          "annotations": { "readOnlyHint": true } },
        { "name": "get_state", "description": "Cursor position, frontmost app, its focused window title, and whether the screen is locked.",
          "inputSchema": { "type": "object", "properties": {} },
          "annotations": { "readOnlyHint": true } },
        { "name": "click", "description": "Click at a point.",
          "inputSchema": { "type": "object", "required": ["x", "y"], "properties": {
              "x": xy("X"), "y": xy("Y"), "display": display,
              "button": { "type": "string", "enum": ["left", "right", "middle"] },
              "count": { "type": "integer", "minimum": 1, "maximum": 3, "description": "2 = double-click" } } } },
        { "name": "move_mouse", "description": "Move the pointer (hover).",
          "inputSchema": { "type": "object", "required": ["x", "y"], "properties": {
              "x": xy("X"), "y": xy("Y"), "display": display } } },
        { "name": "drag", "description": "Drag with the left button from one point to another.",
          "inputSchema": { "type": "object", "required": ["from_x", "from_y", "to_x", "to_y"], "properties": {
              "from_x": xy("Start X"), "from_y": xy("Start Y"), "to_x": xy("End X"), "to_y": xy("End Y"),
              "display": display } } },
        { "name": "scroll", "description": "Scroll by lines; dy > 0 scrolls down, dx > 0 scrolls right. Optionally at a point.",
          "inputSchema": { "type": "object", "properties": {
              "dy": { "type": "integer" }, "dx": { "type": "integer" },
              "x": xy("X"), "y": xy("Y"), "display": display } } },
        { "name": "press_key", "description": "Press a key or shortcut, e.g. \"return\", \"cmd+space\", \"cmd+shift+t\", \"f5\".",
          "inputSchema": { "type": "object", "required": ["key"], "properties": {
              "key": { "type": "string" } } } },
        { "name": "type_text", "description": "Type text into the focused field (any language; newlines press Return).",
          "inputSchema": { "type": "object", "required": ["text"], "properties": {
              "text": { "type": "string" } } } },
        { "name": "open_app", "description": "Open or bring to front an installed app by name (\"TextEdit\") or bundle id.",
          "inputSchema": { "type": "object", "required": ["name"], "properties": {
              "name": { "type": "string" } } } },
        { "name": "create_virtual_display", "description": "Create a virtual display (useful on a headless Mac). Returns its id.",
          "inputSchema": { "type": "object", "properties": {
              "width": { "type": "integer", "description": "Pixels (default 1920)" },
              "height": { "type": "integer", "description": "Pixels (default 1080)" },
              "hidpi": { "type": "boolean", "description": "Retina (desktop is half the size in points)" } } } },
        { "name": "remove_virtual_display", "description": "Remove a virtual display created with create_virtual_display.",
          "inputSchema": { "type": "object", "required": ["id"], "properties": {
              "id": { "type": "integer" } } },
          "annotations": { "destructiveHint": true } }
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    type Reply = Box<dyn Fn(&str, &str) -> Response>;

    /// Records calls and replies from a script.
    struct FakeApi {
        calls: RefCell<Vec<(String, String, Option<Value>)>>,
        reply: Reply,
    }

    impl Api for FakeApi {
        fn call(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Response, String> {
            self.calls
                .borrow_mut()
                .push((method.into(), path.into(), body.cloned()));
            Ok((self.reply)(method, path))
        }
    }

    fn ok(body: Value) -> Response {
        Response {
            status: 200,
            headers: vec![],
            body: body.to_string().into_bytes(),
        }
    }

    fn server(reply: impl Fn(&str, &str) -> Response + 'static) -> Server<FakeApi> {
        Server::new(FakeApi {
            calls: RefCell::default(),
            reply: Box::new(reply),
        })
    }

    fn call(server: &Server<FakeApi>, tool: &str, args: Value) -> Value {
        let reply = server
            .handle(&json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                              "params": { "name": tool, "arguments": args } }))
            .unwrap();
        reply["result"].clone()
    }

    #[test]
    fn initialize_and_list_tools() {
        let server = server(|_, _| ok(json!({})));
        let reply = server
            .handle(&json!({ "jsonrpc": "2.0", "id": 7, "method": "initialize",
                              "params": { "protocolVersion": "2025-03-26" } }))
            .unwrap();
        assert_eq!(reply["id"], 7);
        assert_eq!(reply["result"]["protocolVersion"], "2025-03-26");
        assert!(reply["result"]["capabilities"]["tools"].is_object());
        let unknown = server
            .handle(&json!({ "jsonrpc": "2.0", "id": 8, "method": "initialize",
                              "params": { "protocolVersion": "1999-01-01" } }))
            .unwrap();
        assert_eq!(unknown["result"]["protocolVersion"], PROTOCOL_VERSIONS[0]);
        assert!(
            server
                .handle(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }))
                .is_none()
        );
        let tools = server
            .handle(&json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" }))
            .unwrap();
        let names: Vec<_> = tools["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect();
        for expected in [
            "screenshot",
            "click",
            "type_text",
            "open_app",
            "get_state",
            "create_virtual_display",
        ] {
            assert!(names.contains(&expected.to_owned()), "{expected}");
        }
        let missing = server
            .handle(&json!({ "jsonrpc": "2.0", "id": 3, "method": "nope" }))
            .unwrap();
        assert_eq!(missing["error"]["code"], -32601);
    }

    #[test]
    fn screenshot_scale_converts_click_coordinates() {
        let server = server(|_, path| {
            if path.starts_with("/v1/screenshot") {
                Response {
                    status: 200,
                    headers: vec![
                        ("Content-Type".into(), "image/png".into()),
                        ("X-ClawTank-Display".into(), "1".into()),
                        ("X-ClawTank-Width".into(), "1568".into()),
                        ("X-ClawTank-Height".into(), "980".into()),
                        ("X-ClawTank-Points-Per-Pixel".into(), "2.0000".into()),
                    ],
                    body: vec![0x89, b'P', b'N', b'G'],
                }
            } else {
                ok(json!({ "ok": true }))
            }
        });
        let shot = call(&server, "screenshot", json!({}));
        assert_eq!(shot["content"][0]["type"], "image");
        assert_eq!(shot["content"][0]["data"], "iVBORw==");
        assert_eq!(shot["content"][0]["mimeType"], "image/png");
        call(&server, "click", json!({ "x": 100, "y": 50, "count": 2 }));
        let calls = server.api.calls.borrow();
        assert_eq!(calls[0].1, format!("/v1/screenshot?max_width={MAX_WIDTH}"));
        let (method, path, body) = &calls[1];
        assert_eq!((method.as_str(), path.as_str()), ("POST", "/v1/input"));
        let action = &body.as_ref().unwrap()["actions"][0];
        assert_eq!(action["type"], "click");
        assert_eq!(action["x"], 200.0, "screenshot pixels × points-per-pixel");
        assert_eq!(action["y"], 100.0);
        assert_eq!(action["count"], 2);
    }

    #[test]
    fn errors_become_tool_errors() {
        let server = server(|_, _| Response {
            status: 409,
            headers: vec![],
            body: json!({ "error": "a person is using this Mac; retry in 2 s" })
                .to_string()
                .into_bytes(),
        });
        let result = call(&server, "type_text", json!({ "text": "hi" }));
        assert_eq!(result["isError"], true);
        assert!(
            result["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("person")
        );
        let bad = call(&server, "press_key", json!({}));
        assert_eq!(bad["isError"], true, "missing argument");
        assert_eq!(bad["content"][0]["text"], "\"key\" is required");
        assert!(
            server.api.calls.borrow().len() == 1,
            "no request sent for invalid arguments"
        );
    }

    #[test]
    fn open_app_and_virtual_displays() {
        let server = server(|method, path| match (method, path) {
            ("POST", "/v1/apps/open") => ok(json!({ "ok": true, "app": "TextEdit" })),
            ("POST", "/v1/virtual-displays") => ok(json!({ "id": 42 })),
            _ => ok(json!({ "ok": true })),
        });
        let opened = call(&server, "open_app", json!({ "name": "textedit" }));
        assert_eq!(opened["content"][0]["text"], "Opened TextEdit");
        let created = call(
            &server,
            "create_virtual_display",
            json!({ "width": 1280, "height": 800 }),
        );
        assert!(
            created["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("42")
        );
        call(&server, "remove_virtual_display", json!({ "id": 42 }));
        let calls = server.api.calls.borrow();
        assert_eq!(calls[1].2.as_ref().unwrap()["width"], 1280);
        assert_eq!(calls[2].0, "DELETE");
        assert_eq!(calls[2].1, "/v1/virtual-displays/42");
    }
}
