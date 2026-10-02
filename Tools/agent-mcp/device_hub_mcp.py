#!/usr/bin/env python3
"""MCP server (stdio) that drives a device shown in Device Hub on an iPad, over its agent HTTP API.

Register with Claude Code (the iPad accepts only loopback and Tailscale peers, so use its
tailnet name or 100.x address, and the token configured as DEVICE_HUB_AGENT_TOKEN in the app):
    claude mcp add device-hub -e DEVICE_HUB_URL=http://ipad-pro:8765 \
        -e DEVICE_HUB_AGENT_TOKEN=... -- python3 /path/to/device_hub_mcp.py

Screenshots come back scaled to SHOT_HEIGHT pixels tall; tap and drag take coordinates in that
image, so an agent can use what it sees as is. No third-party packages: macOS's `sips` scales.
"""
import base64, json, os, subprocess, sys, tempfile, urllib.request

URL = os.environ.get("DEVICE_HUB_URL", "http://ipad-pro:8765").rstrip("/")
TOKEN = os.environ.get("DEVICE_HUB_AGENT_TOKEN", "")
SHOT_HEIGHT = int(os.environ.get("DEVICE_HUB_SHOT_HEIGHT", "1000"))
scale = None  # device pixels per screenshot pixel, from the latest screenshot


def http(method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(e.read().decode(errors="replace"))


def screenshot():
    global scale
    png = http("GET", "/screenshot")
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, "s.png"), os.path.join(d, "t.png")
        open(src, "wb").write(png)
        subprocess.run(["sips", "--resampleHeight", str(SHOT_HEIGHT), src, "--out", dst], capture_output=True, check=True)
        small = open(dst, "rb").read()
    size = json.loads(http("GET", "/screen"))
    scale = size["height"] / SHOT_HEIGHT
    w = round(size["width"] / scale)
    return [{"type": "image", "data": base64.b64encode(small).decode(), "mimeType": "image/png"},
            {"type": "text", "text": f"Screenshot is {w}x{SHOT_HEIGHT}; tap/drag take coordinates in it."}]


def device(v):
    if scale is None:
        raise RuntimeError("take a screenshot first: coordinates are in the screenshot")
    return round(v * scale)


def run(name, a):
    if name == "screenshot":
        return screenshot()
    if name == "tap":
        http("POST", "/tap", {"x": device(a["x"]), "y": device(a["y"])})
    elif name == "drag":
        http("POST", "/drag", {"x1": device(a["x1"]), "y1": device(a["y1"]), "x2": device(a["x2"]),
                               "y2": device(a["y2"]), "duration": a.get("duration", 0.3)})
    elif name == "type_text":
        http("POST", "/type", {"text": a["text"]}, timeout=120)
    elif name == "press_button":
        http("POST", "/button", {"name": a["name"]})
    else:
        raise RuntimeError(f"unknown tool {name}")
    return [{"type": "text", "text": "done; take a screenshot to see the result"}]


def num(desc):
    return {"type": "number", "description": desc}


TOOLS = [
    {"name": "screenshot", "description": "Screenshot of the device. Take one before tapping: coordinates are in it.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "tap", "description": "Tap at a point of the latest screenshot.",
     "inputSchema": {"type": "object", "properties": {"x": num("x in the screenshot"), "y": num("y in the screenshot")},
                     "required": ["x", "y"]}},
    {"name": "drag", "description": "One-finger drag between two points of the latest screenshot (scroll: drag up to see more below).",
     "inputSchema": {"type": "object", "properties": {"x1": num("start x"), "y1": num("start y"), "x2": num("end x"),
                                                      "y2": num("end y"), "duration": num("seconds, default 0.3")},
                     "required": ["x1", "y1", "x2", "y2"]}},
    {"name": "type_text", "description": "Type text into the focused field, one key at a time (ASCII; \\n is Return).",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "press_button", "description": "Press a hardware button.",
     "inputSchema": {"type": "object", "properties": {"name": {"type": "string", "enum": ["home", "lock", "mute", "siri", "volumeUp", "volumeDown"]}},
                     "required": ["name"]}},
]


def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    msg.update({"error": error} if error else {"result": result})
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    method, id_ = req.get("method"), req.get("id")
    if id_ is None:
        continue  # notifications
    if method == "initialize":
        reply(id_, {"protocolVersion": req.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}}, "serverInfo": {"name": "device-hub", "version": "0.1"}})
    elif method == "tools/list":
        reply(id_, {"tools": TOOLS})
    elif method == "tools/call":
        p = req.get("params", {})
        try:
            reply(id_, {"content": run(p.get("name"), p.get("arguments") or {})})
        except Exception as e:
            reply(id_, {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True})
    else:
        reply(id_, error={"code": -32601, "message": f"no method {method}"})
