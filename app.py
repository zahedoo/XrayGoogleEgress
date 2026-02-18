#!/usr/bin/env python3
from __future__ import annotations

import cgi
import copy
import io
import json
import logging
import os
import re
import subprocess
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

APP_NAME = "google-egress-check"
STATE_DIR = Path("/var/lib/google-egress-check")
UPLOAD_DIR = STATE_DIR / "uploads"
LATEST_STATUS_FILE = STATE_DIR / "latest_status.json"
HELPER_TEST = "/usr/local/sbin/google-egress-xray-test"

MAX_UPLOAD_BYTES = 1_000_000
MAX_BODY_BYTES = 1_100_000

STATUS_LOCK = threading.Lock()
UPLOAD_LOCK = threading.Lock()

LOGGER = logging.getLogger(APP_NAME)

SENSITIVE_FIELD_RE = re.compile(
    r'("?(?:id|uuid|password|pass|privatekey|private_key|shortid|short_id|token|secret)"?\s*:\s*")([^"]+)(")',
    flags=re.IGNORECASE,
)
UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
LONG_TOKEN_RE = re.compile(r"\b[A-Za-z0-9+=_-]{24,}\b")

LATEST_STATUS: dict[str, Any] = {
    "status": "idle",
    "message": "Upload config.json to run Google egress validation",
    "checked_at": "",
}

HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Xray Google Egress Validator</title>
  <style>
    :root {
      --bg-a: #071426;
      --bg-b: #1b3e66;
      --panel: #f8fbff;
      --ink: #13243a;
      --muted: #4f637a;
      --ok: #0f766e;
      --bad: #b91c1c;
      --warn: #b45309;
      --accent: #0284c7;
      --shadow: 0 24px 55px rgba(4, 18, 37, 0.24);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--ink);
      background:
        radial-gradient(circle at 10% 18%, rgba(56,189,248,.2), transparent 35%),
        radial-gradient(circle at 85% 0%, rgba(34,197,94,.18), transparent 38%),
        linear-gradient(155deg, var(--bg-a), var(--bg-b));
      font-family: "IBM Plex Sans", "Source Sans 3", "Noto Sans", sans-serif;
    }
    .wrap {
      max-width: 1150px;
      margin: 24px auto;
      padding: 18px;
    }
    .hero {
      color: #e6f3ff;
      margin-bottom: 16px;
      animation: rise .4s ease;
    }
    .hero h1 {
      margin: 0;
      font-size: clamp(1.6rem, 3vw, 2.3rem);
      font-weight: 750;
      letter-spacing: .01em;
    }
    .hero p {
      margin: 9px 0 0;
      color: #b8d4ee;
      font-size: .95rem;
    }
    .panel {
      background: var(--panel);
      border-radius: 18px;
      overflow: hidden;
      box-shadow: var(--shadow);
      animation: rise .55s ease;
    }
    .head {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      justify-content: space-between;
      padding: 16px 20px;
      border-bottom: 1px solid #dde7f2;
      background: linear-gradient(95deg, rgba(2,132,199,.13), rgba(34,197,94,.1));
    }
    .chip {
      padding: 8px 14px;
      border-radius: 999px;
      font-weight: 700;
      font-size: .88rem;
      border: 1px solid transparent;
    }
    .chip.idle { color: #0c4a6e; background: #dbeafe; border-color: #93c5fd; }
    .chip.success { color: #065f46; background: #d1fae5; border-color: #6ee7b7; }
    .chip.invalid { color: #991b1b; background: #fee2e2; border-color: #fca5a5; }
    .grid {
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 14px;
      padding: 18px;
    }
    .card {
      border: 1px solid #e2e8f0;
      border-radius: 13px;
      background: #fff;
      padding: 13px;
      min-height: 110px;
    }
    .card h3 {
      margin: 0 0 8px;
      color: var(--muted);
      font-size: .84rem;
      text-transform: uppercase;
      letter-spacing: .05em;
      font-weight: 700;
    }
    .v {
      font-size: 1.15rem;
      font-weight: 730;
      line-height: 1.35;
      word-break: break-word;
    }
    .kicker {
      margin-top: 8px;
      color: var(--muted);
      font-size: .82rem;
    }
    .big { grid-column: span 6; }
    .small { grid-column: span 3; }
    .wide { grid-column: span 12; }
    .upload {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 10px;
      align-items: center;
    }
    input[type="file"] {
      border: 1px solid #cbd5e1;
      border-radius: 10px;
      padding: 10px;
      background: #f8fafc;
      width: 100%;
      font-family: inherit;
    }
    button {
      border: 0;
      border-radius: 10px;
      padding: 11px 15px;
      font-weight: 720;
      font-family: inherit;
      cursor: pointer;
      color: #fff;
      background: linear-gradient(135deg, #0284c7, #0ea5e9);
      transition: transform .15s ease, filter .15s ease;
    }
    button:hover { transform: translateY(-1px); filter: brightness(1.03); }
    .note {
      margin-top: 8px;
      color: var(--muted);
      font-size: .8rem;
    }
    .mono { font-family: "JetBrains Mono", "Fira Code", "Consolas", monospace; }
    .badline {
      border: 1px solid #fecaca;
      background: #fef2f2;
      color: #991b1b;
      border-radius: 10px;
      padding: 10px 12px;
      font-weight: 700;
      margin-top: 10px;
      display: none;
    }
    pre {
      margin: 10px 0 0;
      padding: 12px;
      border-radius: 10px;
      background: #0f172a;
      color: #e2e8f0;
      max-height: 280px;
      overflow: auto;
      font-size: .82rem;
      line-height: 1.45;
      white-space: pre-wrap;
      word-wrap: break-word;
    }
    .json {
      background: #0b1f37;
    }
    .logs {
      background: #2a1014;
    }
    @media (max-width: 920px) {
      .big, .small, .wide { grid-column: span 12; }
      .upload { grid-template-columns: 1fr; }
    }
    @keyframes rise {
      from { opacity: 0; transform: translateY(7px); }
      to { opacity: 1; transform: translateY(0); }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <section class="hero">
      <h1>Google Egress Accuracy Validator</h1>
      <p>Upload custom Xray config.json. Service tests it safely, extracts Google-seen IP via Google DoH through proxy, then restores original config.</p>
    </section>

    <section class="panel">
      <div class="head">
        <div id="statusChip" class="chip idle">Status: idle</div>
        <div>API: <span class="mono">/api/status</span> | Health: <span class="mono">/healthz</span></div>
      </div>

      <div class="grid">
        <article class="card wide">
          <h3>Upload Xray Config</h3>
          <form id="uploadForm" class="upload">
            <input id="configFile" type="file" name="config" accept=".json,application/json" required>
            <button id="submitBtn" type="submit">Submit</button>
          </form>
          <div class="note">Max file size: 1MB. Previous active Xray config is always restored after each test.</div>
          <div id="invalidLine" class="badline">This config is not working / cannot connect</div>
        </article>

        <article class="card big">
          <h3>Google-Seen IP (Authoritative)</h3>
          <div class="v mono" id="googleIp">-</div>
          <div class="kicker">From dns.google o-o.myaddr.l.google.com through Xray proxy</div>
        </article>
        <article class="card big">
          <h3>Generic Public IP</h3>
          <div class="v mono" id="genericIp">-</div>
          <div class="kicker">From api.ipify.org through same proxy path</div>
        </article>

        <article class="card small"><h3>Google Outbound Tag</h3><div class="v mono" id="tag">-</div></article>
        <article class="card small"><h3>Routing Split</h3><div class="v" id="split">-</div></article>
        <article class="card small"><h3>DNS Leak</h3><div class="v" id="dns">-</div></article>
        <article class="card small"><h3>IPv6 Leak</h3><div class="v" id="ipv6">-</div></article>

        <article class="card wide">
          <h3>Country / ISP / ASN</h3>
          <div class="v" id="geo">-</div>
          <div class="kicker" id="checkedAt">-</div>
        </article>

        <article class="card big">
          <h3>Latest JSON</h3>
          <pre id="jsonOut" class="json mono">{}</pre>
        </article>
        <article class="card big">
          <h3>Xray Journal Tail (Invalid Config)</h3>
          <pre id="journalOut" class="logs mono"></pre>
        </article>
      </div>
    </section>
  </div>

  <script>
    const byId = (id) => document.getElementById(id);

    function yesNo(v) { return v ? "Yes" : "No"; }

    function setChip(status) {
      const chip = byId("statusChip");
      chip.className = "chip " + (status === "success" ? "success" : (status === "invalid_config" ? "invalid" : "idle"));
      chip.textContent = "Status: " + status;
    }

    function render(data) {
      byId("jsonOut").textContent = JSON.stringify(data, null, 2);
      byId("googleIp").textContent = data.google_seen_ip || "-";
      byId("genericIp").textContent = data.generic_ip || "-";
      byId("tag").textContent = data.google_outbound_tag || "-";
      byId("split").textContent = data.routing_split === undefined ? "-" : yesNo(!!data.routing_split);
      byId("dns").textContent = data.dns_leak === undefined ? "-" : yesNo(!!data.dns_leak);
      byId("ipv6").textContent = data.ipv6_leak === undefined ? "-" : yesNo(!!data.ipv6_leak);
      const geo = [data.country || "-", data.isp || "-", data.asn || "-"].join(" / ");
      byId("geo").textContent = geo;
      byId("checkedAt").textContent = data.checked_at || "-";
      setChip(data.status || "idle");

      if (data.status === "invalid_config") {
        byId("invalidLine").style.display = "block";
        byId("invalidLine").textContent = "This config is not working / cannot connect" + (data.error ? ": " + data.error : "");
        byId("journalOut").textContent = data.xray_journal_tail || "";
      } else {
        byId("invalidLine").style.display = "none";
        byId("journalOut").textContent = "";
      }
    }

    async function loadStatus() {
      try {
        const res = await fetch("/api/status", { cache: "no-store" });
        const data = await res.json();
        render(data);
      } catch {
        render({ status: "invalid_config", error: "Unable to load status" });
      }
    }

    byId("uploadForm").addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const fileInput = byId("configFile");
      if (!fileInput.files || fileInput.files.length === 0) {
        return;
      }
      const file = fileInput.files[0];
      if (file.size > 1000000) {
        render({ status: "invalid_config", error: "File exceeds 1MB limit", xray_journal_tail: "" });
        return;
      }

      const btn = byId("submitBtn");
      btn.disabled = true;
      btn.textContent = "Testing...";
      try {
        const form = new FormData();
        form.append("config", file);
        const res = await fetch("/upload", { method: "POST", body: form });
        const data = await res.json();
        render(data);
      } catch {
        render({ status: "invalid_config", error: "Upload failed", xray_journal_tail: "" });
      } finally {
        btn.disabled = false;
        btn.textContent = "Submit";
      }
    });

    loadStatus();
  </script>
</body>
</html>
"""


class UploadError(RuntimeError):
    pass


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_cmd(args: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        shell=False,
    )


def mask_text(value: str) -> str:
    text = value
    text = SENSITIVE_FIELD_RE.sub(r"\1***MASKED***\3", text)
    text = UUID_RE.sub("***UUID***", text)

    def _replace_token(match: re.Match[str]) -> str:
        token = match.group(0)
        if "." in token and "/" not in token:
            return token
        return "***TOKEN***"

    text = LONG_TOKEN_RE.sub(_replace_token, text)
    return text


def sanitize_value(value: Any) -> Any:
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for k, v in value.items():
            out[str(k)] = sanitize_value(v)
        return out
    if isinstance(value, list):
        return [sanitize_value(x) for x in value]
    if isinstance(value, str):
        return mask_text(value)
    return value


def safe_filename(value: str) -> str:
    keep = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)
    return keep[:80] or "config.json"


def ensure_state_dirs() -> None:
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)


def load_latest_status() -> dict[str, Any]:
    if not LATEST_STATUS_FILE.exists():
        return copy.deepcopy(LATEST_STATUS)
    try:
        data = json.loads(LATEST_STATUS_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return copy.deepcopy(LATEST_STATUS)
        return sanitize_value(data)
    except (OSError, json.JSONDecodeError):
        return copy.deepcopy(LATEST_STATUS)


def save_latest_status(data: dict[str, Any]) -> None:
    payload = sanitize_value(data)
    payload.setdefault("checked_at", utc_now_iso())
    with STATUS_LOCK:
        global LATEST_STATUS
        LATEST_STATUS = payload
        LATEST_STATUS_FILE.write_text(
            json.dumps(payload, ensure_ascii=True, separators=(",", ":")),
            encoding="utf-8",
        )


def parse_uploaded_file(handler: BaseHTTPRequestHandler) -> tuple[bytes, str]:
    content_length_raw = handler.headers.get("Content-Length", "0").strip()
    if not content_length_raw.isdigit():
        raise UploadError("Invalid Content-Length")
    content_length = int(content_length_raw)
    if content_length <= 0:
        raise UploadError("Empty request body")
    if content_length > MAX_BODY_BYTES:
        raise UploadError("Payload too large (max 1MB)")

    content_type = handler.headers.get("Content-Type", "")
    ctype, _ = cgi.parse_header(content_type)
    if ctype != "multipart/form-data":
        raise UploadError("Content-Type must be multipart/form-data")

    body = handler.rfile.read(content_length)
    if len(body) != content_length:
        raise UploadError("Incomplete upload body")

    env = {
        "REQUEST_METHOD": "POST",
        "CONTENT_TYPE": content_type,
        "CONTENT_LENGTH": str(content_length),
    }
    form = cgi.FieldStorage(
        fp=io.BytesIO(body),
        headers=handler.headers,
        environ=env,
        keep_blank_values=False,
    )

    field = None
    if "config" in form:
        field = form["config"]
    elif "file" in form:
        field = form["file"]
    if field is None:
        raise UploadError("Missing file field 'config'")
    if isinstance(field, list):
        field = field[0]
    if not getattr(field, "file", None):
        raise UploadError("Missing file content")

    file_name = safe_filename(getattr(field, "filename", "") or "config.json")
    file_data = field.file.read(MAX_UPLOAD_BYTES + 1)
    if isinstance(file_data, str):
        file_data = file_data.encode("utf-8")
    if not file_data:
        raise UploadError("Uploaded file is empty")
    if len(file_data) > MAX_UPLOAD_BYTES:
        raise UploadError("config.json exceeds 1MB limit")
    return file_data, file_name


def validate_json_config(raw_data: bytes) -> bytes:
    try:
        text = raw_data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise UploadError(f"config.json must be UTF-8: {exc}") from exc
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise UploadError(f"Invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise UploadError("Xray config root must be a JSON object")

    normalized = json.dumps(payload, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    if len(normalized) > MAX_UPLOAD_BYTES:
        raise UploadError("Normalized config exceeds 1MB limit")
    return normalized


def write_upload_file(raw_data: bytes) -> Path:
    ensure_state_dirs()
    name = f"upload_{int(datetime.now(timezone.utc).timestamp())}_{os.getpid()}_{threading.get_ident()}.json"
    path = UPLOAD_DIR / name
    with path.open("wb") as f:
        f.write(raw_data)
    os.chmod(path, 0o640)
    return path


def run_config_test(upload_path: Path) -> dict[str, Any]:
    try:
        proc = run_cmd(["sudo", "-n", HELPER_TEST, str(upload_path)], timeout=300)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {
            "status": "invalid_config",
            "error": mask_text(f"Test helper failed: {exc}"),
            "xray_journal_tail": "",
            "checked_at": utc_now_iso(),
        }

    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()
    parsed: dict[str, Any]

    if stdout:
        try:
            loaded = json.loads(stdout)
            parsed = loaded if isinstance(loaded, dict) else {}
        except json.JSONDecodeError:
            parsed = {}
    else:
        parsed = {}

    if not parsed:
        stderr_masked = mask_text(stderr)[:6000]
        first_line = stderr_masked.splitlines()[0] if stderr_masked else ""
        parsed = {
            "status": "invalid_config",
            "error": first_line or "Invalid response from test helper",
            "xray_journal_tail": stderr_masked,
        }

    parsed = sanitize_value(parsed)
    parsed.setdefault("checked_at", utc_now_iso())

    if proc.returncode != 0 and parsed.get("status") != "invalid_config":
        parsed = {
            "status": "invalid_config",
            "error": "Xray test failed",
            "xray_journal_tail": mask_text(stderr)[:6000],
            "checked_at": utc_now_iso(),
        }

    if parsed.get("status") == "invalid_config":
        parsed.setdefault("error", "This config is not working / cannot connect")
        parsed.setdefault("xray_journal_tail", "")

    return parsed


class Handler(BaseHTTPRequestHandler):
    server_version = "GoogleEgressUpload/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        LOGGER.info("%s - %s", self.address_string(), mask_text(fmt % args))

    def _send_json(self, code: int, obj: dict[str, Any]) -> None:
        payload = sanitize_value(obj)
        body = json.dumps(payload, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, code: int, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path in {"/", "/index.html"}:
            self._send_html(HTTPStatus.OK, HTML_PAGE)
            return
        if path == "/api/status":
            with STATUS_LOCK:
                payload = copy.deepcopy(LATEST_STATUS)
            self._send_json(HTTPStatus.OK, payload)
            return
        if path == "/healthz":
            self._send_json(HTTPStatus.OK, {"status": "ok"})
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"status": "not_found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path != "/upload":
            self._send_json(HTTPStatus.NOT_FOUND, {"status": "not_found"})
            return

        if not UPLOAD_LOCK.acquire(blocking=False):
            self._send_json(
                HTTPStatus.CONFLICT,
                {"status": "busy", "error": "Another upload is currently being processed"},
            )
            return

        upload_path: Path | None = None
        result: dict[str, Any]
        try:
            raw_data, file_name = parse_uploaded_file(self)
            config_data = validate_json_config(raw_data)
            upload_path = write_upload_file(config_data)
            result = run_config_test(upload_path)
            result["uploaded_filename"] = file_name
        except UploadError as exc:
            result = {
                "status": "invalid_config",
                "error": mask_text(str(exc)),
                "xray_journal_tail": "",
                "checked_at": utc_now_iso(),
            }
        except Exception as exc:
            LOGGER.exception("Unhandled upload exception")
            result = {
                "status": "invalid_config",
                "error": mask_text(f"Unhandled error: {exc}"),
                "xray_journal_tail": "",
                "checked_at": utc_now_iso(),
            }
        finally:
            UPLOAD_LOCK.release()
            if upload_path and upload_path.exists():
                try:
                    upload_path.unlink()
                except OSError:
                    LOGGER.warning("Failed to remove temporary upload: %s", upload_path)

        save_latest_status(result)
        self._send_json(HTTPStatus.OK, result)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ensure_state_dirs()
    latest = load_latest_status()
    with STATUS_LOCK:
        global LATEST_STATUS
        LATEST_STATUS = latest
    server = ThreadingHTTPServer(("0.0.0.0", 80), Handler)
    server.daemon_threads = True
    LOGGER.info("Listening on port 80")
    server.serve_forever()


if __name__ == "__main__":
    main()
