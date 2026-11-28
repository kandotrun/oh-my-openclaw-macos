#!/usr/bin/env python3
"""Synthetic loopback Gateway contract fixture, never a real OpenClaw server.

Only standard library modules are used. The fixture checks client framing and
challenge fields; cryptographic proof verification lives in the Swift tests.
No credentials or request content are logged. With --signin, access_fixture.py
plays Cloudflare Access in front of the Gateway on the same port.
"""
import argparse
import base64
import hashlib
import json
import socketserver
import struct
import threading
import time
import uuid

import access_fixture

# Question mode: the agent waits on one free-text answer in the main thread.
QUESTION = {"id": "question-1", "status": "pending", "sessionKey": "agent:fixture:main", "agentId": "fixture",
            "questions": [{"questionId": "base", "header": "Base branch", "question": "Which branch should I start from?"}]}

# Every connection is the same profile, as shared-token connections are on a real Gateway.
OWNER = {"id": "fixture-owner", "identity": {"type": "profile", "id": "fixture-owner"}, "name": "Fixture Owner"}
OWNER_SENDER = {"senderId": "fixture-owner", "senderName": "Fixture Owner", "senderIdentity": OWNER["identity"]}

# Shared mode: a teammate already wrote in the main thread.
PEER_MESSAGE = {"role": "user", "content": [{"type": "text", "text": "Can you check the flaky login test?"}],
                "__openclaw": {"id": "peer-1", "senderId": "fixture-peer", "senderName": "Peer Person",
                               "senderIdentity": {"type": "profile", "id": "fixture-peer"}}}


def peer_reply(run):
    return {"role": "user", "content": [{"type": "text", "text": "Thanks, I'll review it."}],
            "__openclaw": {"id": "peer-reply-" + run, "senderId": "fixture-peer", "senderName": "Peer Person",
                           "senderIdentity": {"type": "profile", "id": "fixture-peer"}}}


def initial_messages(shared):
    return {"agent:fixture:main": [PEER_MESSAGE]} if shared else {}


# Access mode: like a Gateway behind Cloudflare Access, an upgrade without the service token goes to a login page.
ACCESS_TOKEN = {"cf-access-client-id": "fixture-access.access", "cf-access-client-secret": "fixture-access-secret"}
ACCESS_LOGIN = "https://fixture.cloudflareaccess.com/cdn-cgi/access/login/fixture"


def access_refusal(headers, required):
    if not required or all(headers.get(name) == value for name, value in ACCESS_TOKEN.items()):
        return None
    return ("HTTP/1.1 302 Found\r\nLocation: " + ACCESS_LOGIN + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").encode()


class Client(socketserver.StreamRequestHandler):
    def handle(self):
        headers = {}
        request = self.rfile.readline().decode("latin-1").split()
        while True:
            line = self.rfile.readline()
            if line in (b"\r\n", b"\n", b""):
                break
            key, value = line.decode().split(":", 1)
            headers[key.lower()] = value.strip()
        signin = getattr(self.server, "signin", None)
        if signin is not None and headers.get("upgrade", "").lower() != "websocket":
            # Sign-in mode: the Access edge, the team domain and the relay answer every other request.
            if len(request) >= 2:
                try:
                    self.wfile.write(signin.handle_http(request[0], request[1], headers))
                    self.wfile.flush()
                except OSError:
                    pass
            return
        self.person = False
        if signin is not None:
            refusal, self.person = signin.admit(request[1] if len(request) >= 2 else "/", headers)
        else:
            refusal = access_refusal(headers, getattr(self.server, "access", False))
        if refusal:
            self.wfile.write(refusal)
            self.wfile.flush()
            return
        digest = hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        accept = base64.b64encode(digest).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
        self.wfile.flush()
        self.lock = threading.RLock()
        self.seq = 0
        self.timestamp = int(time.time() * 1000)
        self.emit("connect.challenge", {"nonce": "fixture-challenge", "ts": self.timestamp}, sequence=False)
        self.admitted = False
        self.stopped = set()
        self.finished = set()
        try:
            while True:
                frame = self.receive()
                if frame is None:
                    return
                self.dispatch(frame)
        except (EOFError, ConnectionError, BrokenPipeError, OSError):
            return

    def receive(self):
        header = self.rfile.read(2)
        if len(header) != 2:
            raise EOFError
        opcode, length = header[0] & 15, header[1] & 127
        if length == 126:
            length = struct.unpack("!H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.rfile.read(8))[0]
        if length > 26_214_400:
            raise ConnectionError
        masked = header[1] & 128
        mask = self.rfile.read(4) if masked else b""
        payload = self.rfile.read(length)
        if masked:
            payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
        if opcode == 8:
            return None
        if opcode == 9:
            self.send_bytes(payload, opcode=10)
            return self.receive()
        return json.loads(payload)

    def send_bytes(self, payload, opcode=1):
        with self.lock:
            length = len(payload)
            header = bytes([128 | opcode, length]) if length < 126 else bytes([128 | opcode, 126]) + struct.pack("!H", length) if length < 65536 else bytes([128 | opcode, 127]) + struct.pack("!Q", length)
            self.wfile.write(header + payload)
            self.wfile.flush()

    def send(self, value):
        self.send_bytes(json.dumps(value, ensure_ascii=False).encode())

    def emit(self, name, payload, sequence=True):
        with self.lock:
            frame = {"type": "event", "event": name, "payload": payload}
            if sequence:
                self.seq += 1
                frame["seq"] = self.seq
            self.send(frame)

    def result(self, frame, payload):
        self.send({"type": "res", "id": frame["id"], "ok": True, "payload": payload})

    def dispatch(self, frame):
        assert frame["type"] == "req"
        method, params = frame["method"], frame.get("params", {})
        if method == "connect":
            assert params["minProtocol"] <= 4 <= params["maxProtocol"]
            assert params["client"]["id"] == "gateway-client"
            assert params["client"]["mode"] == "ui" and params["role"] == "operator"
            assert params["client"]["platform"] == "macos" and params["client"]["deviceFamily"] == "Mac"
            assert params["device"]["nonce"] == "fixture-challenge"
            assert params["device"]["signedAt"] == self.timestamp
            assert len(params["device"]["id"]) == 64
            if getattr(self.server, "signin", None) is not None and not self.person:
                # Sign-in mode: Access let a service token through, so the trusted-proxy Gateway finds no user
                # to authenticate, and refuses as OpenClaw does (src/gateway/server/ws-connection/connect-auth.ts).
                self.send({"type": "res", "id": frame["id"], "ok": False, "error": {"code": "INVALID_REQUEST", "message": "unauthorized: trusted proxy user missing",
                    "details": {"code": "AUTH_UNAUTHORIZED", "authReason": "trusted_proxy_user_missing", "canRetryWithDeviceToken": False}}})
                return
            if getattr(self.server, "pairing", False):
                # Pairing mode: every connect needs approval on the Gateway host.
                self.send({"type": "res", "id": frame["id"], "ok": False, "error": {"code": "NOT_PAIRED", "message": "pairing required",
                    "details": {"code": "PAIRING_REQUIRED", "requestId": "req-fixture-1"}}})
                return
            self.admitted = True
            self.result(frame, {"type": "hello-ok", "protocol": 4,
                "server": {"version": "fixture-only", "connId": "fixture"},
                "features": {"methods": ["health", "chat.send", "chat.history", "chat.abort", "sessions.list", "sessions.subscribe", "sessions.messages.subscribe", "sessions.create", "sessions.patch", "models.list"], "events": ["chat", "agent", "sessions.changed"]},
                "auth": {"deviceToken": "synthetic-fixture-device-token", "role": "operator", "scopes": params["scopes"]},
                "snapshot": {"sessionDefaults": {"defaultAgentId": "fixture", "mainKey": "main", "mainSessionKey": "agent:fixture:main"},
                             "presence": [{"connectionId": "fixture", "instanceId": params["client"].get("instanceId"), "ts": self.timestamp, "user": OWNER}]},
                "policy": {"maxPayload": 26_214_400, "maxBufferedBytes": 52_428_800, "tickIntervalMs": 15000, "attachments": {"maxBytes": 19_464_192, "maxImageBytes": 6_291_456}}})
            return
        assert self.admitted
        if method == "health":
            self.result(frame, {"ok": True, "fixture": True})
        elif method == "fixture.close":
            self.send_bytes(b"", opcode=8)
            self.connection.shutdown(2)
        elif method == "fixture.accessAudit" and getattr(self.server, "signin", None) is not None:
            self.result(frame, self.server.signin.audit())
        elif method == "fixture.expireAccess" and getattr(self.server, "signin", None) is not None:
            self.result(frame, {"expired": self.server.signin.expire()})
        elif method == "models.list":
            self.result(frame, {"models": [{"id": "fixture-model", "provider": "fixture", "name": "Fixture model", "manualSelectionAllowed": True, "thinkingLevels": [{"id": "low", "label": "Low"}, {"id": "high", "label": "High"}]}]})
        elif method in ("sessions.list", "sessions.subscribe"):
            rows = list(self.server.sessions.values())
            payload = {"sessions": rows, "defaults": {"model": "fixture/fixture-model"}}
            self.result(frame, {"subscribed": True, "list": payload} if method.endswith("subscribe") else payload)
        elif method == "sessions.messages.subscribe":
            self.result(frame, {"subscribed": True})
        elif method == "question.list":
            self.result(frame, {"questions": [QUESTION] if getattr(self.server, "question", False) else []})
        elif method == "sessions.create":
            key = "agent:fixture:dashboard:" + str(uuid.uuid4())
            row = {"key": key, "agentId": "fixture", "sessionId": str(uuid.uuid4()), "displayName": params.get("titleSource", "New chat")[:30]}
            self.server.sessions[key] = row
            self.result(frame, {"ok": True, **row, "session": row})
        elif method == "sessions.patch":
            row = self.server.sessions[params["key"]]
            row.update({key: value for key, value in params.items() if key in ("model", "thinkingLevel", "label")})
            self.result(frame, {"ok": True, "key": params["key"], "entry": row, "resolved": row})
        elif method == "chat.history":
            selector_error = None
            if "offset" in params and "messageId" in params:
                selector_error = "offset and messageId cannot be used together"
            elif "sessionId" in params and "messageId" not in params:
                selector_error = "sessionId requires messageId"
            if selector_error:
                self.send({"type": "res", "id": frame["id"], "ok": False, "error": {"code": "INVALID_REQUEST", "message": selector_error}})
                return
            key = params["sessionKey"]
            self.result(frame, {"sessionKey": key, "sessionId": self.server.sessions[key]["sessionId"], "messages": self.server.messages.get(key, []), "sessionInfo": {**self.server.sessions[key], "hasActiveRun": False, "activeRunIds": []}})
        elif method == "chat.send":
            self.result(frame, {"runId": params["idempotencyKey"], "status": "started"})
            self.server.messages.setdefault(params["sessionKey"], []).append({"role": "user", "content": [{"type": "text", "text": params["message"]}], "__openclaw": {"id": params["idempotencyKey"], "idempotencyKey": params["idempotencyKey"] + ":user", **OWNER_SENDER}})
            threading.Thread(target=self.respond, args=(params,), daemon=True).start()
        elif method == "chat.abort":
            with self.lock:
                if params["runId"] in self.finished:
                    self.result(frame, {"ok": True, "aborted": False})
                else:
                    self.stopped.add(params["runId"])
                    self.emit("chat", {"runId": params["runId"], "sessionKey": params["sessionKey"], "state": "aborted"})
                    self.result(frame, {"ok": True, "aborted": True})
        else:
            self.send({"type": "res", "id": frame["id"], "ok": False, "error": {"code": "INVALID_REQUEST", "message": "Unsupported fixture method"}})

    def respond(self, params):
        run, key = params["idempotencyKey"], params["sessionKey"]
        try:
            with self.lock:
                if run in self.stopped:
                    return
                self.emit("agent", {"runId": run, "sessionKey": key, "stream": "tool", "data": {"name": "web_search", "phase": "start"}})
            time.sleep(0.15)
            for index, chunk in enumerate(["This is ", "a synthetic ", "WebSocket response."]):
                with self.lock:
                    if run in self.stopped:
                        return
                    self.emit("chat", {"runId": run, "sessionKey": key, "seq": index + 1, "state": "delta", "deltaText": chunk})
                time.sleep(0.08)
            message = {"role": "assistant", "content": [{"type": "text", "text": "This is a synthetic WebSocket response."}], "__openclaw": {"id": run + "-answer"}}
            with self.lock:
                if run in self.stopped:
                    return
                self.server.messages[key].append(message)
                if getattr(self.server, "shared", False):
                    # The teammate answers while the run settles, so only a history read shows it.
                    self.server.messages[key].append(peer_reply(run))
                self.finished.add(run)
                self.emit("chat", {"runId": run, "sessionKey": key, "state": "final", "message": message})
        except (ConnectionError, BrokenPipeError, OSError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--pairing", action="store_true", help="reject every connect with a pairing request")
    parser.add_argument("--question", action="store_true", help="hold one pending question in the main thread")
    parser.add_argument("--shared", action="store_true", help="seed a teammate's message in the main thread")
    parser.add_argument("--access", action="store_true", help="require a Cloudflare Access service token on the upgrade")
    parser.add_argument("--signin", action="store_true", help="play Cloudflare Access on this port, with a browser sign-in for a person")
    options = parser.parse_args()
    with Server(("127.0.0.1", options.port), Client) as server:
        server.pairing = options.pairing
        server.question = options.question
        server.shared = options.shared
        server.access = options.access
        server.signin = access_fixture.AccessFixture(server.server_address[1], service_token=ACCESS_TOKEN) if options.signin else None
        server.sessions = {"agent:fixture:main": {"key": "agent:fixture:main", "agentId": "fixture", "sessionId": "fixture-main", "displayName": "Main"}}
        server.messages = initial_messages(options.shared)
        print(server.server_address[1], flush=True)
        server.serve_forever()
