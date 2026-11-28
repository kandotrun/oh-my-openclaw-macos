import base64
import hashlib
import hmac
import json
import threading
import time
import unittest
import urllib.parse

import access_fixture as fixture

# Published vectors; nothing here is a real credential. The app is bob and the relay is alice in the
# NaCl box2 test (tests/box2.c), and GO_BODY is x/crypto nacl/box.Seal from alice to bob with the box2
# nonce, which is how cloudflared's relay seals a transfer (token/transfer.go, token/encrypt.go).
ALICE_SECRET = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
ALICE_PUBLIC = bytes.fromhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
BOB_SECRET = bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
BOB_PUBLIC = bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
NONCE = bytes.fromhex("69696ee955b62b73cd62bda875fc73d68219e0036b7a0b37")
BOX2_MESSAGE = bytes.fromhex(
    "be075fc53c81f2d5cf141316ebeb0c7b5228c52a4c62cbd44b66849b64244ffce5ecbaaf33bd751a1ac728d45e6c61296cdc3c01233561f41db66cce314adb310e3be825"
    "0c46f06dceea3a7fa1348057e2f6556ad6b1318a024a838f21af1fde048977eb48f59ffd4924ca1c60902e52f0a089bc76897040e082f937763848645e0705")
BOX2_BOX = bytes.fromhex(
    "f3ffc7703f9400e52a7dfb4b3d3305d98e993b9f48681273c29650ba32fc76ce48332ea7164d96a4476fb8c531a1186ac0dfc17c98dce87b4da7f011ec48c97271d2c2"
    "0f9b928fe2270d6fb863d51738b48eeee314a7cc8ab932164548e526ae90224368517acfeabd6bb3732bc0e9da99832b61ca01b6de56244a9e88d5f9b37973f622a43d14a6"
    "599b1f654cb45a74e355a5")
GO_BODY = ("aWlu6VW2K3PNYr2odfxz1oIZ4ANregs3qKLXF2yiSirZDY0+F85PVku8BSoEtpTJZuctjuM1G8VqNZ/iMUozXmpgRCog9zK0CREUocw+6Q48BbbniAbHKXogimHT"
           "woA4XNJ7AiftqSvH")
GO_PLAINTEXT = b'{"app_token":"app.token.fixture","org_token":"org.token.fixture"}'
# RFC 7515 Appendix A.2: the RS256 example signed with the published key.
RFC_INPUT = b"eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ"
RFC_SIGNATURE = ("cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4"
                 "BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqv"
                 "hJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw")

PORT = 61234
NOW = 1_800_000_000
SERVICE_TOKEN = {"cf-access-client-id": "synthetic.access", "cf-access-client-secret": "synthetic-secret"}
# bob's public key in padded base64url, as the sign-in link and the relay path carry it.
BOB_KEY = "3p7bfXt9wbTTW2HC7OQ1Nz-DQ8hbeGdNrfx-FG-IK08="
# The parameters cloudflared's buildRequestURL sends for http://127.0.0.1:61234/ and bob's key.
SIGN_IN = {"aud": fixture.AUD, "close_interstitial": "true", "edge_token_transfer": "true",
           "redirect_url": "http://127.0.0.1:61234/?aud=" + fixture.AUD + "&token=" + BOB_KEY.replace("=", "%3D"),
           "send_org_token": "true", "token": BOB_KEY}
# The same link byte for byte, as the app builds it.
SIGN_IN_QUERY = ("aud=" + fixture.AUD + "&close_interstitial=true&edge_token_transfer=true&redirect_url=http%3A%2F%2F127.0.0.1%3A61234%2F%3Faud%3D"
                 + fixture.AUD + "%26token%3D" + BOB_KEY.replace("=", "%253D") + "&send_org_token=true&token=" + BOB_KEY.replace("=", "%3D"))
TEAM_LOGIN = "https://fixture.cloudflareaccess.com/cdn-cgi/access/login/127.0.0.1?kid=" + fixture.AUD + "&redirect_url=%2F"


def box_open(sealed, sender_public, recipient_secret):
    """NaCl crypto_box_open over nonce || tag || ciphertext, as the app opens a transfer; None when forged."""
    nonce, tag, ciphertext = sealed[:24], sealed[24:40], sealed[40:]
    key = fixture.hsalsa20(fixture.x25519(recipient_secret, sender_public), bytes(16))
    stream = fixture.salsa20_stream(fixture.hsalsa20(key, nonce[:16]), nonce[16:], 32 + len(ciphertext))
    if not hmac.compare_digest(fixture.poly1305(stream[:32], ciphertext), tag):
        return None
    return bytes(a ^ b for a, b in zip(ciphertext, stream[32:]))


def rs256_verifies(token):
    """Whether the published RFC 7515 key signed this compact JWS."""
    header, claims, signature = token.split(".")
    modulus = int.from_bytes(fixture.b64url_decode(fixture.N), "big")
    exponent = int.from_bytes(fixture.b64url_decode(fixture.E), "big")
    encoded = pow(int.from_bytes(fixture.b64url_decode(signature), "big"), exponent, modulus).to_bytes(256, "big")
    digest = fixture.DIGEST_INFO + hashlib.sha256((header + "." + claims).encode()).digest()
    return encoded == b"\x00\x01" + b"\xff" * (256 - len(digest) - 3) + b"\x00" + digest


def decode(token):
    header, claims, _ = token.split(".")
    return json.loads(fixture.b64url_decode(header)), json.loads(fixture.b64url_decode(claims))


def parse(raw):
    """Status, lowercased headers and body of a raw HTTP/1.1 answer."""
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return int(lines[0].split()[1]), headers, body


def query(params, order=sorted):
    """Go's url.Values.Encode of `params`, or another order of the same pairs."""
    return urllib.parse.urlencode(order(params.items()))


def redirect(origin="http://127.0.0.1:61234", path="/", aud=fixture.AUD, token=BOB_KEY, suffix=""):
    return origin + path + "?" + urllib.parse.urlencode([("aud", aud), ("token", token)]) + suffix


class CryptoTests(unittest.TestCase):
    def test_x25519_derives_the_nacl_keys_and_shared_secret(self):
        self.assertEqual(fixture.x25519(ALICE_SECRET, fixture.BASE_POINT), ALICE_PUBLIC)
        self.assertEqual(fixture.x25519(BOB_SECRET, fixture.BASE_POINT), BOB_PUBLIC)
        # NaCl tests/scalarmult5.c: alice's secret times bob's public key.
        self.assertEqual(fixture.x25519(ALICE_SECRET, BOB_PUBLIC).hex(), "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

    def test_box_seal_matches_the_nacl_vectors(self):
        self.assertEqual(fixture.box_seal(NONCE, BOX2_MESSAGE, BOB_PUBLIC, ALICE_SECRET), NONCE + BOX2_BOX)
        # libsodium test/default/box_easy.exp: the empty message with the same keys and nonce.
        self.assertEqual(fixture.box_seal(NONCE, b"", BOB_PUBLIC, ALICE_SECRET), NONCE + bytes.fromhex("2539121d8e234e652d651fa4c8cff880"))
        # x/crypto nacl/box box_test.go TestBox.
        recipient = fixture.x25519(bytes([1] * 32), fixture.BASE_POINT)
        self.assertEqual(fixture.box_seal(bytes([4] * 24), bytes([3] * 64), recipient, bytes([2] * 32))[24:].hex(),
                         "78ea30b19d2341ebbdba54180f821eec265cf86312549bea8a37652a8bb94f07b78a73ed1708085e6ddd0e943bbdeb8755079a37eb31d86163ce241164a47629c0539f330b4914cd135b3855bc2a2dfc")

    def test_box_seal_reproduces_the_go_transfer_body(self):
        self.assertEqual(base64.b64encode(fixture.box_seal(NONCE, GO_PLAINTEXT, BOB_PUBLIC, ALICE_SECRET)).decode(), GO_BODY)
        self.assertEqual(box_open(base64.b64decode(GO_BODY), ALICE_PUBLIC, BOB_SECRET), GO_PLAINTEXT)
        forged = bytearray(base64.b64decode(GO_BODY))
        forged[-1] ^= 1
        self.assertIsNone(box_open(bytes(forged), ALICE_PUBLIC, BOB_SECRET))

    def test_rs256_reproduces_the_rfc7515_signature(self):
        self.assertEqual(fixture.b64url(fixture.rs256_sign(RFC_INPUT)), RFC_SIGNATURE)
        self.assertTrue(rs256_verifies(RFC_INPUT.decode() + "." + RFC_SIGNATURE))


class AccessRouteTests(unittest.TestCase):
    def setUp(self):
        self.now = float(NOW)
        self.access = fixture.AccessFixture(PORT, service_token=SERVICE_TOKEN, now=lambda: self.now, hold=0.01)

    def http(self, method, target, headers=None):
        return parse(self.access.handle_http(method, target, headers or {}))

    def sign_in(self):
        """The stand-in browser's GET of bob's sign-in link, then the relay's answer to bob's poll, opened."""
        self.assertEqual(self.http("GET", "/cdn-cgi/access/cli?" + SIGN_IN_QUERY)[0], 200)
        status, headers, body = self.http("GET", "/transfer/" + BOB_KEY)
        self.assertEqual(status, 200)
        sender = headers["service-public-key"]
        self.assertEqual((len(sender), sender[-1]), (44, "="))
        return json.loads(box_open(base64.b64decode(body), fixture.b64url_decode(sender), BOB_SECRET))

    def test_metadata_names_this_gateway_signed_by_the_published_key(self):
        for method in ("HEAD", "GET"):
            status, headers, body = self.http(method, "/", {"cf-access-metadata-request": "true"})
            self.assertEqual((status, body), (200, b""))
            metadata = headers["cf-access-metadata"]
            self.assertTrue(rs256_verifies(metadata))
            self.assertEqual(decode(metadata), ({"alg": "RS256", "kid": "fixture-rfc7515", "typ": "JWT"},
                                                {"type": "match", "hostname": "127.0.0.1", "auth_domain": "fixture.cloudflareaccess.com",
                                                 "aud": fixture.AUD, "app_hostname": "127.0.0.1", "iat": NOW}))

    def test_a_plain_request_is_sent_to_the_login_page_with_a_session_cookie(self):
        for method in ("GET", "HEAD"):
            status, headers, body = self.http(method, "/")
            self.assertEqual((status, body), (302, b""))
            # The team domain is this origin too, so a client that followed the redirect would stay on this Mac.
            self.assertEqual(headers["location"], "http://127.0.0.1:61234/cdn-cgi/access/login/127.0.0.1?kid=" + fixture.AUD + "&redirect_url=%2F")
            self.assertRegex(headers["set-cookie"], r"^CF_AppSession=[0-9a-f]{32}; Path=/; HttpOnly$")
            self.assertNotIn("cf-access-metadata", headers)

    def test_the_team_domain_publishes_the_signing_key_beside_another(self):
        status, headers, body = self.http("GET", "/cdn-cgi/access/certs")
        self.assertEqual((status, headers["content-type"]), (200, "application/json"))
        keys = json.loads(body)["keys"]
        self.assertEqual(len(keys), 2)
        [signing] = [key for key in keys if key["kid"] == "fixture-rfc7515"]
        self.assertEqual((signing["kty"], signing["alg"], signing["n"], signing["e"]), ("RSA", "RS256", fixture.N, "AQAB"))
        [other] = [key for key in keys if key["kid"] != "fixture-rfc7515"]
        self.assertNotEqual(other["n"], fixture.N)

    def test_the_exact_sign_in_link_has_the_relay_deliver_the_tokens_once(self):
        tokens = self.sign_in()
        self.assertEqual(set(tokens), {"app_token", "org_token"})
        for name, kind in (("app_token", "app"), ("org_token", "org")):
            self.assertTrue(rs256_verifies(tokens[name]))
            header, claims = decode(tokens[name])
            self.assertEqual(header, {"alg": "RS256", "kid": "fixture-rfc7515", "typ": "JWT"})
            self.assertEqual({key: claims[key] for key in ("type", "aud", "iss", "sub", "email", "iat", "nbf", "exp")},
                             {"type": kind, "aud": [fixture.AUD], "iss": "https://fixture.cloudflareaccess.com", "sub": "fixture-operator",
                              "email": "operator@example.com", "iat": NOW, "nbf": NOW, "exp": NOW + fixture.ACCESS_TTL})
        self.assertEqual(self.http("GET", "/transfer/" + BOB_KEY)[0], 404)
        self.assertEqual(self.access.audit(), {"leaks": [], "cliRequests": 1})
        # Each sign-in gets its own tokens.
        self.assertNotEqual(self.sign_in()["app_token"], tokens["app_token"])

    def test_a_sign_in_link_that_is_not_exactly_cloudflareds_approves_nothing(self):
        def without(name):
            return {key: value for key, value in SIGN_IN.items() if key != name}

        # Each case below changes one thing about the exact link.
        self.assertEqual(query(SIGN_IN), SIGN_IN_QUERY)
        cases = {"no " + name: query(without(name)) for name in SIGN_IN}
        cases.update({
            "another aud": query(dict(SIGN_IN, aud="other-aud")),
            "close_interstitial false": query(dict(SIGN_IN, close_interstitial="false")),
            "edge_token_transfer false": query(dict(SIGN_IN, edge_token_transfer="false")),
            "send_org_token false": query(dict(SIGN_IN, send_org_token="false")),
            "an extra parameter": query(dict(SIGN_IN, extra="1")),
            "a repeated parameter": SIGN_IN_QUERY + "&aud=" + fixture.AUD,
            "parameters out of order": query(SIGN_IN, order=lambda pairs: sorted(pairs, reverse=True)),
            "the key's padding left unescaped": SIGN_IN_QUERY.replace("IK08%3D", "IK08="),
            "an unpadded key": query(dict(SIGN_IN, token=BOB_KEY[:-1], redirect_url=redirect(token=BOB_KEY[:-1]))),
            "a 31-byte key": query(dict(SIGN_IN, token=base64.urlsafe_b64encode(BOB_PUBLIC[:31]).decode(),
                                        redirect_url=redirect(token=base64.urlsafe_b64encode(BOB_PUBLIC[:31]).decode()))),
            "a key in standard base64": query(dict(SIGN_IN, token=base64.b64encode(bytes([0xfb] * 32)).decode(),
                                                   redirect_url=redirect(token=base64.b64encode(bytes([0xfb] * 32)).decode()))),
            "a redirect over https": query(dict(SIGN_IN, redirect_url=redirect(origin="https://127.0.0.1:61234"))),
            "a redirect to another port": query(dict(SIGN_IN, redirect_url=redirect(origin="http://127.0.0.1:61235"))),
            "a redirect to another host": query(dict(SIGN_IN, redirect_url=redirect(origin="http://localhost:61234"))),
            "a redirect to another path": query(dict(SIGN_IN, redirect_url=redirect(path="/other"))),
            "a redirect with another aud": query(dict(SIGN_IN, redirect_url=redirect(aud="other-aud"))),
            "a redirect with another key": query(dict(SIGN_IN, redirect_url=redirect(token=fixture.b64url(ALICE_PUBLIC) + "="))),
            "a redirect with a fragment": query(dict(SIGN_IN, redirect_url=redirect(suffix="#x"))),
            "a redirect with more": query(dict(SIGN_IN, redirect_url=redirect(suffix="&x=1"))),
            "not a query": "%%%",
        })
        for name, text in cases.items():
            with self.subTest(name):
                self.assertEqual(self.http("GET", "/cdn-cgi/access/cli?" + text)[0], 400)
        self.assertEqual(self.http("HEAD", "/cdn-cgi/access/cli?" + SIGN_IN_QUERY)[0], 404)
        self.assertEqual(self.access.audit()["cliRequests"], 0)
        self.assertEqual(self.http("GET", "/transfer/" + BOB_KEY)[0], 404)

    def test_the_relay_holds_a_poll_before_the_sign_in_then_answers_404(self):
        self.access.hold = 0.2
        started = time.monotonic()
        self.assertEqual(self.http("GET", "/transfer/" + BOB_KEY), (404, {"content-length": "0", "connection": "close"}, b""))
        self.assertGreaterEqual(time.monotonic() - started, 0.15)

    def test_an_approval_answers_a_held_poll_at_once(self):
        self.access.hold = 30
        answers = []
        poll = threading.Thread(target=lambda: answers.append(self.http("GET", "/transfer/" + BOB_KEY)), daemon=True)
        poll.start()
        self.assertEqual(self.http("GET", "/cdn-cgi/access/cli?" + SIGN_IN_QUERY)[0], 200)
        poll.join(timeout=10)
        self.assertFalse(poll.is_alive())
        self.assertEqual(answers[0][0], 200)

    def test_the_upgrade_admits_the_person_until_access_expires_their_token(self):
        app = self.sign_in()["app_token"]
        self.assertEqual(self.access.admit("/", {"cf-access-token": app}), (None, True))
        self.assertEqual(self.access.expire(), 1)
        refusal, person = self.access.admit("/", {"cf-access-token": app})
        self.assertFalse(person)
        self.assertEqual(parse(refusal), (302, {"location": TEAM_LOGIN, "content-length": "0", "connection": "close"}, b""))
        self.assertEqual(self.access.expire(), 0)

    def test_an_app_token_ends_at_its_exp(self):
        app = self.sign_in()["app_token"]
        self.now += fixture.ACCESS_TTL - 1
        self.assertEqual(self.access.admit("/", {"cf-access-token": app}), (None, True))
        self.now += 1
        self.assertFalse(self.access.admit("/", {"cf-access-token": app})[1])
        self.assertEqual(self.access.expire(), 0)

    def test_the_upgrade_lets_the_service_token_through_without_a_person(self):
        self.assertEqual(self.access.admit("/", dict(SERVICE_TOKEN)), (None, False))
        without_service_tokens = fixture.AccessFixture(PORT, now=lambda: self.now)
        self.assertEqual(parse(without_service_tokens.admit("/", dict(SERVICE_TOKEN))[0])[0], 302)

    def test_the_upgrade_sends_anything_else_to_the_team_login_page(self):
        tokens = self.sign_in()
        for headers in ({}, {"cf-access-token": decode(tokens["app_token"])[1]["sub"]}, {"cf-access-token": tokens["org_token"]},
                        {"cf-access-client-id": SERVICE_TOKEN["cf-access-client-id"]},
                        {"cf-access-client-id": SERVICE_TOKEN["cf-access-client-id"], "cf-access-client-secret": "wrong"}):
            with self.subTest(sorted(headers)):
                refusal, person = self.access.admit("/", headers)
                self.assertFalse(person)
                self.assertEqual(parse(refusal)[:2], (302, {"location": TEAM_LOGIN, "content-length": "0", "connection": "close"}))

    def test_other_routes_are_not_found(self):
        for method, target in (("GET", "/cdn-cgi/access/login/127.0.0.1"), ("POST", "/"), ("GET", "/transfer"), ("POST", "/cdn-cgi/access/certs")):
            with self.subTest(method + " " + target):
                self.assertEqual(self.http(method, target)[0], 404)


class AccessAuditTests(unittest.TestCase):
    def setUp(self):
        self.access = fixture.AccessFixture(PORT, service_token=SERVICE_TOKEN, now=lambda: NOW, hold=0.01)

    def issue(self):
        """Approves bob's key and takes the tokens the relay seals for it."""
        self.access.handle_http("GET", "/cdn-cgi/access/cli?" + SIGN_IN_QUERY, {})
        _, headers, body = parse(self.access.handle_http("GET", "/transfer/" + BOB_KEY, {}))
        return json.loads(box_open(base64.b64decode(body), fixture.b64url_decode(headers["service-public-key"]), BOB_SECRET))

    def test_a_clean_sign_in_leaks_nothing(self):
        self.access.handle_http("GET", "/", {})
        self.access.handle_http("HEAD", "/", {"cf-access-metadata-request": "true", "user-agent": "OhMyOpenClaw"})
        self.access.handle_http("GET", "/cdn-cgi/access/certs", {})
        app = self.issue()["app_token"]
        self.access.admit("/", {"cf-access-token": app})
        self.access.admit("/", dict(SERVICE_TOKEN))
        self.assertEqual(self.access.audit(), {"leaks": [], "cliRequests": 1})

    def test_any_credential_on_an_access_route_is_a_leak(self):
        app = self.issue()["app_token"]
        credentials = {"cf-access-token": app, "cf-access-client-id": "synthetic.access", "cf-access-client-secret": "synthetic-secret",
                       "cookie": "CF_AppSession=synthetic", "authorization": "Bearer synthetic"}
        routes = {"/": ("HEAD", "/", {"cf-access-metadata-request": "true"}), "/cdn-cgi/access/certs": ("GET", "/cdn-cgi/access/certs", {}),
                  "/cdn-cgi/access/cli": ("GET", "/cdn-cgi/access/cli?" + SIGN_IN_QUERY, {}), "/transfer": ("GET", "/transfer/" + BOB_KEY, {}),
                  "/cdn-cgi/access/authorized": ("HEAD", "/cdn-cgi/access/authorized", {})}
        for route, (method, target, headers) in routes.items():
            for name, value in credentials.items():
                with self.subTest(name + " on " + route):
                    access = fixture.AccessFixture(PORT, service_token=SERVICE_TOKEN, now=lambda: NOW, hold=0.01)
                    access.handle_http(method, target, dict(headers, **{name: value}))
                    self.assertEqual(access.audit()["leaks"], [name + " on " + route])

    def test_the_org_token_anywhere_is_a_leak(self):
        org = self.issue()["org_token"]
        self.access.admit("/", {"cf-access-token": org})
        self.access.handle_http("GET", "/", {"cookie": "CF_Authorization=" + org})
        self.assertEqual(self.access.audit()["leaks"], ["the org token on the upgrade", "cookie on /", "the org token on /"])

    def test_a_cookie_or_authorization_on_the_upgrade_is_a_leak(self):
        app = self.issue()["app_token"]
        self.access.admit("/", {"cf-access-token": app, "cookie": "CF_AppSession=synthetic"})
        self.access.admit("/", {"authorization": "Bearer synthetic"})
        self.assertEqual(self.access.audit()["leaks"], ["cookie on the upgrade", "authorization on the upgrade"])

    def test_a_token_in_a_url_is_a_leak(self):
        app = self.issue()["app_token"]
        self.access.handle_http("GET", "/?token=" + app, {})
        self.access.admit("/?access=" + app, {"cf-access-token": app})
        self.assertEqual(self.access.audit()["leaks"], ["a token in the URL of /", "a token in the URL of the upgrade"])

    def test_the_audit_names_where_a_credential_went_never_the_credential(self):
        tokens = self.issue()
        for _ in range(2):
            self.access.handle_http("GET", "/cdn-cgi/access/certs", {"cf-access-token": tokens["app_token"]})
            self.access.handle_http("GET", "/", {"cookie": "CF_Authorization=" + tokens["org_token"]})
        audit = self.access.audit()
        self.assertEqual(audit["leaks"], ["cf-access-token on /cdn-cgi/access/certs", "cookie on /", "the org token on /"])
        text = json.dumps(audit)
        for token in tokens.values():
            for segment in token.split("."):
                self.assertNotIn(segment, text)


if __name__ == "__main__":
    unittest.main()
