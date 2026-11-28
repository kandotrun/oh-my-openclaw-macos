import http.client
import importlib.util
from pathlib import Path
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("gateway_fixture", Path(__file__).with_name("gateway-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class FixtureConcurrencyTests(unittest.TestCase):
    def client(self):
        client = fixture.Client.__new__(fixture.Client)
        client.lock = threading.RLock()
        client.seq = 0
        client.admitted = True
        client.stopped = set()
        client.finished = set()
        client.server = SimpleNamespace(messages={"session": []})
        return client

    def test_abort_during_last_pause_has_no_later_final_or_history(self):
        client = self.client()
        frames = []
        client.send = frames.append
        pauses = 0

        def paused(_):
            nonlocal pauses
            pauses += 1
            if pauses == 4:
                client.dispatch({"type": "req", "id": "stop", "method": "chat.abort", "params": {"runId": "run", "sessionKey": "session"}})

        with patch.object(fixture.time, "sleep", side_effect=paused):
            client.respond({"idempotencyKey": "run", "sessionKey": "session"})
        states = [frame["payload"].get("state") for frame in frames if frame.get("event") == "chat"]
        self.assertIn("aborted", states)
        self.assertNotIn("final", states)
        self.assertEqual(client.server.messages["session"], [])

    def test_sequence_assignment_and_delivery_share_the_same_lock(self):
        client = self.client()
        first_ready = threading.Event()
        second_delivered = threading.Event()
        frames = []

        def send(frame):
            if frame["seq"] == 1:
                first_ready.set()
                second_delivered.wait(timeout=0.2)
            frames.append(frame)
            if frame["seq"] == 2:
                second_delivered.set()

        client.send = send
        first = threading.Thread(target=client.emit, args=("first", {}))
        second = threading.Thread(target=client.emit, args=("second", {}))
        first.start()
        self.assertTrue(first_ready.wait(timeout=2))
        second.start()
        first.join(timeout=2)
        second.join(timeout=2)
        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        self.assertEqual([frame["seq"] for frame in frames], [1, 2])

    def test_pairing_mode_rejects_connect_with_a_shell_safe_request_id(self):
        client = self.client()
        client.admitted = False
        client.timestamp = 1
        client.server.pairing = True
        frames = []
        client.send = frames.append
        client.dispatch({"type": "req", "id": "connect", "method": "connect", "params": {
            "minProtocol": 4, "maxProtocol": 4, "role": "operator", "scopes": ["operator.read"],
            "client": {"id": "gateway-client", "mode": "ui", "platform": "macos", "deviceFamily": "Mac"},
            "device": {"nonce": "fixture-challenge", "signedAt": 1, "id": "a" * 64}}})
        self.assertFalse(frames[0]["ok"])
        self.assertEqual(frames[0]["error"]["code"], "NOT_PAIRED")
        self.assertEqual(frames[0]["error"]["details"], {"code": "PAIRING_REQUIRED", "requestId": "req-fixture-1"})
        self.assertFalse(client.admitted)

    def connect(self, client, frames):
        client.admitted = False
        client.timestamp = 1
        client.server.pairing = False
        client.send = frames.append
        client.dispatch({"type": "req", "id": "connect", "method": "connect", "params": {
            "minProtocol": 4, "maxProtocol": 4, "role": "operator", "scopes": ["operator.read"],
            "client": {"id": "gateway-client", "mode": "ui", "platform": "macos", "deviceFamily": "Mac", "instanceId": "device-1"},
            "device": {"nonce": "fixture-challenge", "signedAt": 1, "id": "a" * 64}}})

    def test_hello_presence_names_this_connection_as_the_fixture_owner(self):
        client = self.client()
        frames = []
        self.connect(client, frames)
        hello = frames[0]["payload"]
        [row] = [row for row in hello["snapshot"]["presence"] if row["connectionId"] == hello["server"]["connId"]]
        self.assertEqual(row["instanceId"], "device-1")
        self.assertEqual(row["user"]["identity"], {"type": "profile", "id": "fixture-owner"})

    def test_chat_send_stamps_the_owner_on_the_user_record(self):
        client = self.client()
        client.send = [].append
        with patch.object(fixture.Client, "respond"):
            client.dispatch({"type": "req", "id": "send", "method": "chat.send", "params": {
                "sessionKey": "session", "message": "hi", "idempotencyKey": "run-1"}})
        [record] = client.server.messages["session"]
        self.assertEqual(record["__openclaw"]["id"], "run-1")
        # The client reconciles its local copy with the stored row through this key.
        self.assertEqual(record["__openclaw"]["idempotencyKey"], "run-1:user")
        self.assertEqual(record["__openclaw"]["senderIdentity"], {"type": "profile", "id": "fixture-owner"})

    def test_shared_mode_seeds_a_peer_message_in_the_main_thread(self):
        self.assertEqual(fixture.initial_messages(shared=False), {})
        [peer] = fixture.initial_messages(shared=True)["agent:fixture:main"]
        self.assertEqual(peer["role"], "user")
        self.assertEqual(peer["__openclaw"]["senderName"], "Peer Person")
        self.assertEqual(peer["__openclaw"]["senderIdentity"], {"type": "profile", "id": "fixture-peer"})

    def test_shared_mode_has_the_teammate_answer_once_my_run_settles(self):
        client = self.client()
        client.server.shared = True
        client.server.messages = {"agent:fixture:main": []}
        client.send = [].append
        with patch.object(fixture.time, "sleep"):
            client.respond({"idempotencyKey": "run-1", "sessionKey": "agent:fixture:main"})
        reply = client.server.messages["agent:fixture:main"][-1]
        self.assertEqual(reply["content"][0]["text"], "Thanks, I'll review it.")
        self.assertEqual(reply["__openclaw"]["senderIdentity"], {"type": "profile", "id": "fixture-peer"})

    def test_access_mode_sends_an_upgrade_without_the_service_token_to_a_login_page(self):
        self.assertIsNone(fixture.access_refusal({}, required=False))
        refusal = fixture.access_refusal({"cf-access-client-id": fixture.ACCESS_TOKEN["cf-access-client-id"]}, required=True)
        self.assertTrue(refusal.startswith(b"HTTP/1.1 302 "))
        self.assertIn(b"Location: https://fixture.cloudflareaccess.com/", refusal)
        self.assertIsNone(fixture.access_refusal(dict(fixture.ACCESS_TOKEN), required=True))

    def test_signin_mode_refuses_a_connect_that_no_person_stands_behind(self):
        # Access let a service token through, so the trusted-proxy Gateway finds no user to authenticate.
        client = self.client()
        client.server.signin = fixture.access_fixture.AccessFixture(61234)
        client.person = False
        frames = []
        self.connect(client, frames)
        self.assertFalse(frames[0]["ok"])
        self.assertEqual(frames[0]["error"]["code"], "INVALID_REQUEST")
        self.assertEqual(frames[0]["error"]["details"]["authReason"], "trusted_proxy_user_missing")
        self.assertFalse(client.admitted)

    def test_signin_mode_admits_the_person_and_answers_the_access_rpcs(self):
        client = self.client()
        client.server.signin = fixture.access_fixture.AccessFixture(61234)
        client.person = True
        frames = []
        self.connect(client, frames)
        self.assertEqual(frames[0]["payload"]["type"], "hello-ok")
        client.dispatch({"type": "req", "id": "audit", "method": "fixture.accessAudit", "params": {}})
        client.dispatch({"type": "req", "id": "expire", "method": "fixture.expireAccess", "params": {}})
        self.assertEqual(frames[1]["payload"], {"leaks": [], "cliRequests": 0})
        self.assertEqual(frames[2]["payload"], {"expired": 0})

    def test_the_access_rpcs_exist_only_in_signin_mode(self):
        client = self.client()
        frames = []
        client.send = frames.append
        for method in ("fixture.accessAudit", "fixture.expireAccess"):
            client.dispatch({"type": "req", "id": method, "method": method, "params": {}})
        self.assertEqual([frame["error"]["code"] for frame in frames], ["INVALID_REQUEST", "INVALID_REQUEST"])

    def test_signin_mode_answers_plain_requests_as_cloudflare_access_on_the_gateway_port(self):
        server = fixture.Server(("127.0.0.1", 0), fixture.Client)
        port = server.server_address[1]
        server.signin = fixture.access_fixture.AccessFixture(port)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        try:
            metadata = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            metadata.request("HEAD", "/", headers={"cf-access-metadata-request": "true"})
            answer = metadata.getresponse()
            self.assertEqual(answer.status, 200)
            self.assertEqual(answer.getheader("cf-access-metadata").count("."), 2)
            metadata.close()
            keys = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            keys.request("GET", "/cdn-cgi/access/certs")
            answer = keys.getresponse()
            self.assertEqual(answer.status, 200)
            self.assertIn("fixture-rfc7515", answer.read().decode())
            keys.close()
        finally:
            server.shutdown()
            server.server_close()

    def test_question_mode_holds_one_pending_question_in_the_main_thread(self):
        client = self.client()
        client.server.question = True
        frames = []
        client.send = frames.append
        client.dispatch({"type": "req", "id": "list", "method": "question.list", "params": {}})
        self.assertTrue(frames[0]["ok"])
        [record] = frames[0]["payload"]["questions"]
        self.assertEqual((record["status"], record["sessionKey"], record["agentId"]), ("pending", "agent:fixture:main", "fixture"))
        self.assertEqual(len(record["questions"]), 1)


if __name__ == "__main__":
    unittest.main()
