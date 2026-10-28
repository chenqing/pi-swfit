"""Loopback OAuth/MCP fixture for the native URLSession lifecycle integration test.

No external accounts or credentials. The ready file is supplied by the test in a temporary directory.
"""
import base64
import hashlib
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

state = {"tokens": 0, "refreshes": 0, "calls": 0, "reject": False, "codes": {}}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, value=None, headers=None):
        body = json.dumps(value).encode() if value is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path.startswith("/.well-known/oauth-protected-resource"):
            self.reply(200, {"resource": origin + "/mcp", "authorization_servers": [origin]})
        elif url.path == "/.well-known/oauth-authorization-server":
            self.reply(200, {"issuer": origin, "authorization_endpoint": origin + "/authorize",
                            "token_endpoint": origin + "/token", "registration_endpoint": origin + "/register",
                            "response_types_supported": ["code"], "code_challenge_methods_supported": ["S256"],
                            "token_endpoint_auth_methods_supported": ["none"],
                            "authorization_response_iss_parameter_supported": True})
        elif url.path == "/authorize":
            params = parse_qs(url.query)
            if params.get("code_challenge_method") != ["S256"]:
                return self.reply(400, {"error": "PKCE required"})
            code = params["state"][0]
            with lock:
                state["codes"][code] = params["code_challenge"][0]
            self.reply(302, headers={"Location": params["redirect_uri"][0] + "?" + urlencode({
                "code": code, "state": code, "iss": origin})})
        elif url.path == "/stats":
            with lock:
                self.reply(200, {key: state[key] for key in ("tokens", "refreshes", "calls")})
        else:
            self.reply(405)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/register":
            self.reply(201, {"client_id": "local-native-client", "token_endpoint_auth_method": "none"})
        elif self.path == "/token":
            params = parse_qs(body.decode())
            with lock:
                if params.get("grant_type") == ["authorization_code"]:
                    expected = state["codes"].pop(params.get("code", [""])[0], None)
                    actual = base64.urlsafe_b64encode(hashlib.sha256(params.get("code_verifier", [""])[0].encode()).digest()).decode().rstrip("=")
                    if not expected or expected != actual:
                        return self.reply(400, {"error": "invalid_grant"})
                elif params.get("grant_type") == ["refresh_token"] and params.get("refresh_token") == ["refresh-local"]:
                    state["refreshes"] += 1
                else:
                    return self.reply(400, {"error": "invalid_grant"})
                state["tokens"] += 1
                self.reply(200, {"access_token": "token-" + str(state["tokens"]), "refresh_token": "refresh-local",
                                 "token_type": "Bearer", "expires_in": 3600})
        elif self.path == "/reject-next":
            with lock:
                state["reject"] = True
            self.reply(204)
        elif self.path == "/mcp":
            with lock:
                if state["reject"] or self.headers.get("Authorization") != "Bearer token-" + str(state["tokens"]) or not state["tokens"]:
                    state["reject"] = False
                    return self.reply(401, headers={"WWW-Authenticate": 'Bearer resource_metadata="' + origin + '/.well-known/oauth-protected-resource/mcp"'})
            message = json.loads(body)
            if "id" not in message:
                return self.reply(202)
            if message["method"] == "initialize":
                result = {"protocolVersion": "2025-11-25", "serverInfo": {"name": "oauth-lifecycle", "version": "1"}, "capabilities": {"tools": {}}}
            elif message["method"] == "tools/call":
                with lock:
                    state["calls"] += 1
                result = {"content": [{"type": "text", "text": "authenticated"}]}
            else:
                result = {"tools": []}
            self.reply(200, {"jsonrpc": "2.0", "id": message["id"], "result": result})
        else:
            self.reply(404)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
origin = "http://127.0.0.1:" + str(server.server_port)
with open(sys.argv[1], "w") as ready:
    ready.write(origin)
server.serve_forever()
