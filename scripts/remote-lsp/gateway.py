#!/usr/bin/env python3
"""Loopback-only HTTP gateway for a resource-constrained Eclipse JDT LS."""

from __future__ import annotations

import glob
import json
import os
import queue
import re
import shutil
import subprocess
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


HOST = "127.0.0.1"
PORT = int(os.environ.get("LEETCODE_LSP_PORT", "9092"))
JDT_HOME = Path(os.environ.get("JDT_LS_HOME", "/opt/leetcode-lsp/jdtls"))
STATE_HOME = Path(os.environ.get("LEETCODE_LSP_STATE", "/var/lib/leetcode-lsp"))
PROJECT_HOME = STATE_HOME / "project"
WORKSPACE_HOME = STATE_HOME / "workspace"
CONFIG_HOME = STATE_HOME / "config_linux"
SOURCE_FILE = PROJECT_HOME / "src" / "main" / "java" / "Solution.java"
MAX_BODY_BYTES = 512 * 1024
REQUEST_TIMEOUT_SECONDS = 25
IDLE_SECONDS = 8 * 60


def frame_message(payload: dict) -> bytes:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


def strip_snippet_placeholders(value: str) -> str:
    value = re.sub(r"\$\{\d+:([^}]*)\}", r"\1", value)
    return re.sub(r"\$\d+", "", value)


class JdtClient:
    def __init__(self) -> None:
        self.process: subprocess.Popen[bytes] | None = None
        self.reader: threading.Thread | None = None
        self.stderr_reader: threading.Thread | None = None
        self.pending: dict[int, queue.Queue] = {}
        self.pending_lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.request_lock = threading.Lock()
        self.sequence = 0
        self.version = 0
        self.opened = False
        self.last_used = 0.0
        self.last_error = ""

    def healthy(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def _launcher(self) -> str:
        matches = glob.glob(str(JDT_HOME / "plugins" / "org.eclipse.equinox.launcher_*.jar"))
        if not matches:
            raise RuntimeError("JDT LS launcher was not found")
        return sorted(matches)[-1]

    def start(self) -> None:
        if self.healthy():
            return
        self.stop()
        SOURCE_FILE.parent.mkdir(parents=True, exist_ok=True)
        WORKSPACE_HOME.mkdir(parents=True, exist_ok=True)
        if not CONFIG_HOME.exists():
            shutil.copytree(JDT_HOME / "config_linux", CONFIG_HOME)
        if not SOURCE_FILE.exists():
            SOURCE_FILE.write_text("class Solution {\n}\n", encoding="utf-8")
        launcher = self._launcher()
        command = [
            "/usr/bin/java",
            "-Xms64m",
            "-Xmx384m",
            "-XX:+UseG1GC",
            "-XX:+UseStringDeduplication",
            "-Declipse.application=org.eclipse.jdt.ls.core.id1",
            "-Dosgi.bundles.defaultStartLevel=4",
            "-Declipse.product=org.eclipse.jdt.ls.core.product",
            "-Dlog.level=WARNING",
            "--add-modules=ALL-SYSTEM",
            "--add-opens", "java.base/java.util=ALL-UNNAMED",
            "--add-opens", "java.base/java.lang=ALL-UNNAMED",
            "-jar", launcher,
            "-configuration", str(CONFIG_HOME),
            "-data", str(WORKSPACE_HOME),
        ]
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.opened = False
        self.version = 0
        self.last_error = ""
        self.reader = threading.Thread(target=self._read_loop, name="jdt-ls-reader", daemon=True)
        self.stderr_reader = threading.Thread(target=self._stderr_loop, name="jdt-ls-stderr", daemon=True)
        self.reader.start()
        self.stderr_reader.start()
        root_uri = PROJECT_HOME.as_uri()
        self.request("initialize", {
            "processId": os.getpid(),
            "rootUri": root_uri,
            "workspaceFolders": [{"uri": root_uri, "name": "leetcode"}],
            "capabilities": {
                "workspace": {"configuration": True, "workspaceFolders": True},
                "textDocument": {
                    "completion": {
                        "completionItem": {
                            "snippetSupport": True,
                            "documentationFormat": ["plaintext", "markdown"],
                        }
                    }
                },
            },
            "initializationOptions": {
                "settings": {
                    "java": {
                        "autobuild": {"enabled": False},
                        "completion": {"enabled": True, "guessMethodArguments": True},
                        "signatureHelp": {"enabled": True},
                    }
                }
            },
        }, timeout=45)
        self.notify("initialized", {})
        self.last_used = time.monotonic()

    def stop(self) -> None:
        process = self.process
        self.process = None
        self.opened = False
        if process is None:
            return
        try:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass
        with self.pending_lock:
            pending = list(self.pending.values())
            self.pending.clear()
        for waiter in pending:
            waiter.put(RuntimeError("JDT LS stopped"))

    def _stderr_loop(self) -> None:
        process = self.process
        if process is None or process.stderr is None:
            return
        for raw in iter(process.stderr.readline, b""):
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                self.last_error = line[-500:]

    def _read_loop(self) -> None:
        process = self.process
        stream = process.stdout if process else None
        if stream is None:
            return
        try:
            while self.process is process and process.poll() is None:
                headers: dict[str, str] = {}
                while True:
                    line = stream.readline()
                    if not line:
                        raise EOFError("JDT LS closed stdout")
                    if line in (b"\r\n", b"\n"):
                        break
                    key, _, value = line.decode("ascii", errors="ignore").partition(":")
                    headers[key.lower().strip()] = value.strip()
                length = int(headers.get("content-length", "0"))
                if length <= 0 or length > 8 * 1024 * 1024:
                    raise RuntimeError("invalid JDT LS message length")
                body = stream.read(length)
                if len(body) != length:
                    raise EOFError("truncated JDT LS message")
                self._handle_message(json.loads(body.decode("utf-8")))
        except Exception as error:
            self.last_error = str(error)[-500:]
        finally:
            if self.process is process:
                self.stop()

    def _handle_message(self, message: dict) -> None:
        message_id = message.get("id")
        if message_id is not None and ("result" in message or "error" in message):
            with self.pending_lock:
                waiter = self.pending.pop(int(message_id), None)
            if waiter:
                waiter.put(message)
            return
        method = message.get("method")
        if message_id is None or not method:
            return
        params = message.get("params") or {}
        if method == "workspace/configuration":
            result = [{} for _ in params.get("items", [])]
        elif method == "workspace/workspaceFolders":
            root_uri = PROJECT_HOME.as_uri()
            result = [{"uri": root_uri, "name": "leetcode"}]
        elif method == "client/registerCapability":
            result = None
        elif method == "window/workDoneProgress/create":
            result = None
        elif method == "workspace/applyEdit":
            result = {"applied": False}
        else:
            result = None
        self._send({"jsonrpc": "2.0", "id": message_id, "result": result})

    def _send(self, payload: dict) -> None:
        process = self.process
        if process is None or process.stdin is None or process.poll() is not None:
            raise RuntimeError("JDT LS is not running")
        data = frame_message(payload)
        with self.write_lock:
            process.stdin.write(data)
            process.stdin.flush()

    def request(self, method: str, params: dict, timeout: int = REQUEST_TIMEOUT_SECONDS):
        self.sequence += 1
        message_id = self.sequence
        waiter: queue.Queue = queue.Queue(maxsize=1)
        with self.pending_lock:
            self.pending[message_id] = waiter
        try:
            self._send({"jsonrpc": "2.0", "id": message_id, "method": method, "params": params})
            response = waiter.get(timeout=timeout)
        except queue.Empty as error:
            with self.pending_lock:
                self.pending.pop(message_id, None)
            raise TimeoutError(f"JDT LS request timed out: {method}") from error
        if isinstance(response, Exception):
            raise response
        if response.get("error"):
            detail = response["error"].get("message") or str(response["error"])
            raise RuntimeError(f"JDT LS error: {detail}")
        return response.get("result")

    def notify(self, method: str, params: dict) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def complete(self, code: str, line: int, character: int) -> list[dict]:
        with self.request_lock:
            self.start()
            self.last_used = time.monotonic()
            SOURCE_FILE.write_text(code, encoding="utf-8")
            uri = SOURCE_FILE.as_uri()
            self.version += 1
            if not self.opened:
                self.notify("textDocument/didOpen", {
                    "textDocument": {"uri": uri, "languageId": "java", "version": self.version, "text": code}
                })
                self.opened = True
            else:
                self.notify("textDocument/didChange", {
                    "textDocument": {"uri": uri, "version": self.version},
                    "contentChanges": [{"text": code}],
                })
            result = self.request("textDocument/completion", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": character},
                "context": {"triggerKind": 1},
            })
            items = result.get("items", []) if isinstance(result, dict) else (result or [])
            normalized = []
            for item in items[:160]:
                text_edit = item.get("textEdit") or {}
                if isinstance(text_edit, dict) and "newText" in text_edit:
                    insert_text = text_edit.get("newText")
                else:
                    insert_text = item.get("insertText") or item.get("label")
                normalized.append({
                    "label": str(item.get("label") or "")[:180],
                    "insertText": strip_snippet_placeholders(str(insert_text or ""))[:500],
                    "detail": str(item.get("detail") or "")[:240],
                    "kind": item.get("kind"),
                    "sortText": str(item.get("sortText") or "")[:80],
                })
            return [item for item in normalized if item["label"] and item["insertText"]]


CLIENT = JdtClient()


def idle_reaper() -> None:
    while True:
        time.sleep(30)
        if CLIENT.healthy() and time.monotonic() - CLIENT.last_used > IDLE_SECONDS:
            CLIENT.stop()


class Handler(BaseHTTPRequestHandler):
    server_version = "LeetCodeLSP/1"

    def log_message(self, format_string: str, *args) -> None:
        print(f"{self.address_string()} {format_string % args}", flush=True)

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if urlparse(self.path).path != "/health":
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        self._json(HTTPStatus.OK, {
            "ok": True,
            "engine": "eclipse-jdt-ls",
            "running": CLIENT.healthy(),
            "idleSeconds": max(0, int(time.monotonic() - CLIENT.last_used)) if CLIENT.last_used else None,
            "lastError": CLIENT.last_error,
        })

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/complete":
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY_BYTES:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "invalid request size"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            if payload.get("language") not in (None, "java"):
                self._json(HTTPStatus.OK, {"items": [], "engine": "local-fallback"})
                return
            code = str(payload.get("code") or "")
            line = int(payload.get("line", 0))
            character = int(payload.get("character", 0))
            lines = code.splitlines() or [""]
            if not code or len(code.encode("utf-8")) > MAX_BODY_BYTES or not 0 <= line < len(lines):
                raise ValueError("invalid document or cursor")
            character = max(0, min(character, len(lines[line])))
            items = CLIENT.complete(code, line, character)
            self._json(HTTPStatus.OK, {"items": items, "engine": "eclipse-jdt-ls"})
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)[:300]})
        except Exception as error:
            CLIENT.last_error = str(error)[-500:]
            self._json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "language service unavailable", "detail": str(error)[:500]})


def main() -> None:
    PROJECT_HOME.mkdir(parents=True, exist_ok=True)
    SOURCE_FILE.parent.mkdir(parents=True, exist_ok=True)
    pom = PROJECT_HOME / "pom.xml"
    if not pom.exists():
        pom.write_text("""<project xmlns=\"http://maven.apache.org/POM/4.0.0\"><modelVersion>4.0.0</modelVersion><groupId>local</groupId><artifactId>leetcode</artifactId><version>1</version><properties><maven.compiler.release>21</maven.compiler.release></properties></project>\n""", encoding="utf-8")
    threading.Thread(target=idle_reaper, name="jdt-ls-idle-reaper", daemon=True).start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    print(f"LeetCode LSP gateway listening on http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        CLIENT.stop()


if __name__ == "__main__":
    main()
