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


if __name__ == "__main__":
    unittest.main()
