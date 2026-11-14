"""Run with python3 -m backend.server. Loopback-only by default, behind HTTPS remotely."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import socket
import sqlite3
import sys
from urllib.parse import urlsplit

from .domain import APIError, MAX_BODY_BYTES, day_context, exact_fields, utc_now
from .storage import Store


def reject_constant(_):
    raise ValueError("Non-standard JSON constant")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate JSON field")
        value[key] = item
    return value


class Application:
    def __init__(self, database, clock=utc_now):
        self.store = Store(database)
        # Injectable only in-process for tests, never through HTTP or CLI.
        self.clock = clock

    def dispatch(self, method, path, authorization, body):
        now = self.clock()
        context = day_context(now)
        if method == "GET" and path == "/health":
            return 200, {"status": "ok", **context}
        if method == "POST" and path == "/v1/users":
            exact_fields(body, ["nickname"])
            return 201, {**self.store.register(body["nickname"], now), **context}
        if method == "GET" and path == "/v1/me":
            return 200, {"user": self.store.profile(authorization), **context}
        if method == "PATCH" and path == "/v1/me":
            exact_fields(body, ["nickname"])
            return 200, {"user": self.store.rename(authorization, body["nickname"]), **context}
        if method == "PUT" and path == "/v1/me/sharing":
            exact_fields(body, ["enabled", "expected_revision"])
            user = self.store.sharing(authorization, body["enabled"], body["expected_revision"])
            return 200, {"user": user, **context}
        if path in ("/health", "/v1/users", "/v1/me", "/v1/me/sharing"):
            raise APIError(405, "method_not_allowed", "此接口不支持该方法")
        raise APIError(404, "not_found", "接口不存在")


class HTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, application):
        self.application = application
        super().__init__(address, Handler)

    def handle_error(self, request, client_address):
        # Do not let socketserver print exception locals, headers or request data.
        print("HTTP request failed", file=sys.stderr)


class Handler(BaseHTTPRequestHandler):
    server_version = "Stairclimb/1"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_args):
        # URLs, Authorization and health payloads must never appear in access logs.
        pass

    def send_error(self, code, message=None, explain=None):
        self.reply(code, {"error": {"code": "http_error", "message": "HTTP 请求无效"}})

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(data)

    def read_json(self):
        if self.headers.get("Transfer-Encoding") is not None:
            raise APIError(400, "invalid_body", "不支持分块请求体")
        lengths = self.headers.get_all("Content-Length", [])
        if not lengths:
            raise APIError(411, "length_required", "需要 Content-Length")
        if len(lengths) != 1 or not re.fullmatch(r"[0-9]+", lengths[0]):
            raise APIError(400, "invalid_body", "Content-Length 无效")
        # Bound before int conversion as well as before reading bytes.
        if len(lengths[0]) > 8 or int(lengths[0]) > MAX_BODY_BYTES:
            raise APIError(413, "body_too_large", f"请求体不得超过 {MAX_BODY_BYTES} 字节")
        length = int(lengths[0])
        if self.headers.get_content_type() != "application/json":
            raise APIError(415, "json_required", "请使用 application/json")
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise APIError(400, "invalid_json", "请求体不完整")
        try:
            body = json.loads(raw.decode("utf-8"), parse_constant=reject_constant,
                              object_pairs_hook=unique_object)
        except (ValueError, RecursionError):
            raise APIError(400, "invalid_json", "请求体必须是合法的 JSON 对象") from None
        if not isinstance(body, dict):
            raise APIError(400, "invalid_json", "请求体必须是 JSON 对象")
        return body

    def handle_request(self):
        try:
            if len(self.path) > 2048:
                raise APIError(414, "uri_too_long", "请求路径过长")
            target = urlsplit(self.path)
            if target.scheme or target.netloc or target.fragment or target.query:
                raise APIError(400, "invalid_query", "此接口不接受查询参数")
            body = self.read_json() if self.command in ("POST", "PUT", "PATCH") else {}
            auth_headers = self.headers.get_all("Authorization", [])
            authorization = auth_headers[0] if len(auth_headers) == 1 else None
            status, payload = self.server.application.dispatch(
                self.command, target.path, authorization, body
            )
            self.reply(status, payload)
        except APIError as error:
            self.reply(error.status, {"error": {"code": error.code, "message": error.message},
                                      **day_context(self.server.application.clock())})
        except (socket.timeout, TimeoutError):
            self.reply(408, {"error": {"code": "request_timeout", "message": "请求超时"}})
        except sqlite3.Error:
            self.reply(503, {"error": {"code": "storage_unavailable", "message": "服务暂不可用，请稍后重试"}})
        except (ValueError, OverflowError):
            self.reply(400, {"error": {"code": "invalid_request", "message": "请求无效"}})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            self.reply(500, {"error": {"code": "internal_error", "message": "服务暂不可用"}})

    do_GET = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request
    do_HEAD = handle_request
    do_OPTIONS = handle_request


def make_server(database, host="127.0.0.1", port=8787, clock=utc_now):
    return HTTPServer((host, port), Application(database, clock))


def main():
    parser = argparse.ArgumentParser(description="爬楼梯本地后端；远程连接请使用 HTTPS 反向代理")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--database", type=Path, default=Path(".runtime/stairclimb.sqlite3"))
    args = parser.parse_args()
    server = make_server(args.database, args.host, args.port)
    print(f"Stairclimb listening on {args.host}:{server.server_port}; timezone=Asia/Shanghai", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
