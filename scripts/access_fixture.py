"""The Cloudflare Access side of scripts/gateway-fixture.py --signin, never a real Cloudflare service.

One loopback origin plays three parts: the Access edge in front of the Gateway, the team domain that
publishes the signing keys, and the relay that hands the browser's sign-in to the app. The app maps the
team domain and the relay to this origin through CloudflareAccessEndpoints.loopbackFixture, so which
Cloudflare origin each request goes to is covered by the Swift unit tests, which record every URL.

The protocol is cloudflared's `access login` (token/token.go, token/transfer.go and token/encrypt.go at
ead8b81). Only standard library modules are used, the RSA key is the one RFC 7515 publishes, and every
token is synthetic. Nothing is logged: the audit names where a credential arrived, never the credential.
"""
import base64
import hashlib
import json
import os
import struct
import threading
import time
import urllib.parse

AUD = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
TEAM_DOMAIN = "fixture.cloudflareaccess.com"
GATEWAY_HOST = "127.0.0.1"
EMAIL = "operator@example.com"
SUBJECT = "fixture-operator"
# Issued tokens last an hour, unless fixture.expireAccess ends them first.
ACCESS_TTL = 3600
LOGIN_PATH = "/cdn-cgi/access/login/" + GATEWAY_HOST + "?kid=" + AUD + "&redirect_url=%2F"
# Where the edge sends an upgrade without a live credential; the app reads that as ACCESS_REQUIRED.
TEAM_LOGIN = "https://" + TEAM_DOMAIN + LOGIN_PATH
SIGN_IN_PARAMETERS = {"aud", "close_interstitial", "edge_token_transfer", "redirect_url", "send_org_token", "token"}
CREDENTIAL_HEADERS = ("cf-access-token", "cf-access-client-id", "cf-access-client-secret", "cookie", "authorization")
REASONS = {200: "OK", 302: "Found", 400: "Bad Request", 404: "Not Found"}


def b64url(data):
    """Unpadded base64url, as JWS segments use it."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(text):
    """base64url with or without its padding."""
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# ---- RS256: RSASSA-PKCS1-v1_5 with SHA-256, with the RSA key that RFC 7515 Appendix A.2 publishes ----

KEY_ID = "fixture-rfc7515"
N = ("ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZ"
     "o9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmo"
     "udF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ")
E = "AQAB"
D = ("Eq5xpGnNCivDflJsRQBXHx1hdR1k6Ulwe2JZD50LpXyWPEAeP88vLNO97IjlA7_GQ5sLKMgvfTeXZx9SE-7YwVol2NXOoAJe46sui395IW_GO-pWJ1O0BkTGoVEn2bKVRUCgu-GjBVa"
     "YLU6f3l9kJfFNS3E0QbVdxzubSu3Mkqzjkn439X0M_V51gfpRLI9JYanrC4D4qAdGcopV_0ZHHzQlBjudU2QvXt4ehNYTCBr6XCLQUShb1juUO1ZdiYoFaFQT5Tw8bGUl_x_jTj3ccPDV"
     "ZFD9pIuhLhBOneufuBiB4cS98l2SR_RQyGWSeWjnczT0QU91p1DhOVRuOopznQ")
# The DER prefix of a SHA-256 DigestInfo.
DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")
HEADER = {"alg": "RS256", "kid": KEY_ID, "typ": "JWT"}
_MODULUS = int.from_bytes(b64url_decode(N), "big")
_PRIVATE_EXPONENT = int.from_bytes(b64url_decode(D), "big")
_MODULUS_BYTES = (_MODULUS.bit_length() + 7) // 8


def rs256_sign(signing_input):
    digest = DIGEST_INFO + hashlib.sha256(signing_input).digest()
    encoded = b"\x00\x01" + b"\xff" * (_MODULUS_BYTES - len(digest) - 3) + b"\x00" + digest
    return pow(int.from_bytes(encoded, "big"), _PRIVATE_EXPONENT, _MODULUS).to_bytes(_MODULUS_BYTES, "big")


def jws(claims):
    """A compact RS256 JWS of `claims`, signed with the published key."""
    signing_input = b64url(json.dumps(HEADER, separators=(",", ":")).encode()) + "." + b64url(json.dumps(claims, separators=(",", ":")).encode())
    return signing_input + "." + b64url(rs256_sign(signing_input.encode()))


def _decoy_modulus():
    modulus = bytearray(b64url_decode(N))
    modulus[-1] ^= 2
    return b64url(bytes(modulus))


# Like a real team domain, this one publishes two keys; the decoy signs nothing.
KEYS = {"keys": [{"kty": "RSA", "kid": "fixture-decoy", "alg": "RS256", "use": "sig", "n": _decoy_modulus(), "e": E},
                 {"kty": "RSA", "kid": KEY_ID, "alg": "RS256", "use": "sig", "n": N, "e": E}]}

# ---- NaCl box: X25519 (RFC 7748), HSalsa20, XSalsa20 and Poly1305 ----

P = 2 ** 255 - 19
BASE_POINT = (9).to_bytes(32, "little")


def x25519(scalar, point):
    """The RFC 7748 Montgomery ladder over a clamped scalar."""
    clamped = bytearray(scalar)
    clamped[0] &= 248
    clamped[31] &= 127
    clamped[31] |= 64
    k = int.from_bytes(clamped, "little")
    x1 = int.from_bytes(point, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a = (x2 + z2) % P
        aa = a * a % P
        b = (x2 - z2) % P
        bb = b * b % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = d * a % P
        cb = c * b % P
        x3 = (da + cb) ** 2 % P
        z3 = x1 * (da - cb) ** 2 % P
        x2 = aa * bb % P
        z2 = e * (aa + 121665 * e) % P
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


SIGMA = struct.unpack("<4I", b"expand 32-byte k")


def _rotate(value, count):
    return ((value << count) & 0xffffffff) | (value >> (32 - count))


def _rounds(state):
    """Salsa20's 20 rounds, without the final addition."""
    x = list(state)

    def quarter(a, b, c, d):
        x[b] ^= _rotate((x[a] + x[d]) & 0xffffffff, 7)
        x[c] ^= _rotate((x[b] + x[a]) & 0xffffffff, 9)
        x[d] ^= _rotate((x[c] + x[b]) & 0xffffffff, 13)
        x[a] ^= _rotate((x[d] + x[c]) & 0xffffffff, 18)

    for _ in range(10):
        quarter(0, 4, 8, 12)
        quarter(5, 9, 13, 1)
        quarter(10, 14, 2, 6)
        quarter(15, 3, 7, 11)
        quarter(0, 1, 2, 3)
        quarter(5, 6, 7, 4)
        quarter(10, 11, 8, 9)
        quarter(15, 12, 13, 14)
    return x


def _state(key, block):
    k = struct.unpack("<8I", key)
    n = struct.unpack("<4I", block)
    return [SIGMA[0], k[0], k[1], k[2], k[3], SIGMA[1], n[0], n[1], n[2], n[3], SIGMA[2], k[4], k[5], k[6], k[7], SIGMA[3]]


def hsalsa20(key, block):
    x = _rounds(_state(key, block))
    return struct.pack("<8I", *(x[i] for i in (0, 5, 10, 15, 6, 7, 8, 9)))


def salsa20_stream(key, nonce, length):
    """The Salsa20 keystream for an 8-byte nonce, from block 0."""
    stream = bytearray()
    counter = 0
    while len(stream) < length:
        state = _state(key, nonce + struct.pack("<Q", counter))
        x = _rounds(state)
        stream += struct.pack("<16I", *((x[i] + state[i]) & 0xffffffff for i in range(16)))
        counter += 1
    return bytes(stream[:length])


def poly1305(key, message):
    r = int.from_bytes(key[:16], "little") & 0x0ffffffc0ffffffc0ffffffc0fffffff
    s = int.from_bytes(key[16:], "little")
    p = (1 << 130) - 5
    accumulator = 0
    for i in range(0, len(message), 16):
        accumulator = (accumulator + int.from_bytes(message[i:i + 16] + b"\x01", "little")) * r % p
    return ((accumulator + s) & ((1 << 128) - 1)).to_bytes(16, "little")


def box_seal(nonce, message, recipient_public, sender_secret):
    """NaCl crypto_box as nonce || tag || ciphertext, the layout the relay sends (token/encrypt.go)."""
    key = hsalsa20(x25519(sender_secret, recipient_public), bytes(16))
    stream = salsa20_stream(hsalsa20(key, nonce[:16]), nonce[16:], 32 + len(message))
    ciphertext = bytes(a ^ b for a, b in zip(message, stream[32:]))
    return nonce + poly1305(stream[:32], ciphertext) + ciphertext


# ---- The edge, the team domain and the relay ----

def response(status, headers=(), body=b""):
    lines = ["HTTP/1.1 %d %s" % (status, REASONS[status])] + ["%s: %s" % header for header in headers]
    lines += ["Content-Length: %d" % len(body), "Connection: close"]
    return ("\r\n".join(lines) + "\r\n\r\n").encode() + body


def route_name(path):
    """The route a path belongs to, as the audit names it: the relay's paths carry the public key."""
    return "/transfer" if path.startswith("/transfer/") else path


def is_transfer_key(text):
    """32 bytes in padded base64url, 44 characters, as cloudflared sends its public key."""
    try:
        raw = base64.urlsafe_b64decode(text)
    except ValueError:
        return False
    return len(raw) == 32 and base64.urlsafe_b64encode(raw).decode() == text


class AccessFixture:
    """Cloudflare Access for the fixture server on `port`. Its connection threads call it at once."""

    def __init__(self, port, service_token=None, now=time.time, hold=1.0):
        self.netloc = GATEWAY_HOST + ":" + str(port)
        # The edge lets this service token through, as a Service Auth policy does.
        self.service_token = service_token
        self.now = now
        # How long the relay holds a poll that finds no transfer.
        self.hold = hold
        self.relay_secret = os.urandom(32)
        self.relay_public = x25519(self.relay_secret, BASE_POINT)
        self.condition = threading.Condition()
        self.transfers = {}
        self.app_tokens = {}
        self.org_tokens = set()
        self.leaks = []
        self.cli_requests = 0

    def handle_http(self, method, target, headers):
        """The answer to a request that is not a WebSocket upgrade."""
        path, _, query = target.partition("?")
        self.inspect(route_name(path), target, headers, allowed=())
        if path == "/" and method in ("HEAD", "GET"):
            if headers.get("cf-access-metadata-request", "").lower() == "true":
                return response(200, [("cf-access-metadata", self.metadata())])
            # Like the edge, a plain request goes to the team's login page with a session cookie. The team
            # domain is this origin too, so a client that wrongly followed the redirect would stay on this Mac.
            return response(302, [("Location", "http://" + self.netloc + LOGIN_PATH),
                                  ("Set-Cookie", "CF_AppSession=" + os.urandom(16).hex() + "; Path=/; HttpOnly")])
        if path == "/cdn-cgi/access/certs" and method == "GET":
            return response(200, [("Content-Type", "application/json")], json.dumps(KEYS).encode())
        if path == "/cdn-cgi/access/cli" and method == "GET":
            return response(200) if self.approve(query) else response(400)
        if path.startswith("/transfer/") and method == "GET":
            return self.transfer(urllib.parse.unquote(path[len("/transfer/"):]))
        return response(404)

    def admit(self, target, headers):
        """Whether the edge lets a WebSocket upgrade through, and whether a signed-in person stands behind
        it: (None, True) for a live application token this relay issued, (None, False) for the service
        token, and otherwise the login redirect, which the app reads as ACCESS_REQUIRED."""
        self.inspect("the upgrade", target, headers, allowed=("cf-access-token", "cf-access-client-id", "cf-access-client-secret"))
        with self.condition:
            if self.app_tokens.get(headers.get("cf-access-token"), 0) > self.now():
                return None, True
        if self.service_token and all(headers.get(name) == value for name, value in self.service_token.items()):
            return None, False
        return response(302, [("Location", TEAM_LOGIN)]), False

    def expire(self):
        """Ends every application token issued so far, as Access does when the session ends."""
        with self.condition:
            live = [token for token, expiry in self.app_tokens.items() if expiry > self.now()]
            for token in self.app_tokens:
                self.app_tokens[token] = 0
        return len(live)

    def audit(self):
        """Where credentials arrived that do not belong there, and how many sign-ins the browser approved."""
        with self.condition:
            return {"leaks": list(self.leaks), "cliRequests": self.cli_requests}

    def inspect(self, route, target, headers, allowed):
        """Records each credential that reaches `route` where none belongs: a credential header other than
        `allowed`, the org token in any header, which the app never sends anywhere, or a token in the URL."""
        found = [name + " on " + route for name in CREDENTIAL_HEADERS if name in headers and name not in allowed]
        with self.condition:
            if any(token in value for token in self.org_tokens for value in headers.values()):
                found.append("the org token on " + route)
            if any(token in target for token in list(self.app_tokens) + list(self.org_tokens)):
                found.append("a token in the URL of " + route)
            self.leaks += [leak for leak in dict.fromkeys(found) if leak not in self.leaks]

    def metadata(self):
        """The signed `cf-access-metadata` that binds this application and its AUD to the Gateway host."""
        return jws({"type": "match", "hostname": GATEWAY_HOST, "auth_domain": TEAM_DOMAIN, "aud": AUD,
                    "app_hostname": GATEWAY_HOST, "iat": int(self.now())})

    def approve(self, query):
        """The person approves the sign-in in the browser: when the link is exactly the one cloudflared's
        buildRequestURL builds for this application, the relay seals new tokens for the link's key."""
        key = self.transfer_key(query)
        if key is None:
            return False
        now = int(self.now())
        app, org = self.issue("app", now), self.issue("org", now)
        transfer = json.dumps({"app_token": app, "org_token": org}).encode()
        sealed = base64.b64encode(box_seal(os.urandom(24), transfer, base64.urlsafe_b64decode(key), self.relay_secret))
        with self.condition:
            self.app_tokens[app] = now + ACCESS_TTL
            self.org_tokens.add(org)
            self.transfers[key] = sealed
            self.cli_requests += 1
            self.condition.notify_all()
        return True

    def transfer_key(self, query):
        """The public key a sign-in link names, or None unless its parameters are exactly cloudflared's:
        keys sorted and escaped as Go's url.Values.Encode does, and a redirect back to this application."""
        try:
            pairs = urllib.parse.parse_qsl(query, keep_blank_values=True, strict_parsing=True)
        except ValueError:
            return None
        values = dict(pairs)
        if len(values) != len(pairs) or set(values) != SIGN_IN_PARAMETERS or query != urllib.parse.urlencode(sorted(pairs)):
            return None
        key = values["token"]
        back = urllib.parse.urlsplit(values["redirect_url"])
        if (values["aud"] != AUD or any(values[name] != "true" for name in ("close_interstitial", "edge_token_transfer", "send_org_token"))
                or not is_transfer_key(key) or (back.scheme, back.netloc, back.path, back.fragment) != ("http", self.netloc, "/", "")
                or back.query != urllib.parse.urlencode([("aud", AUD), ("token", key)])):
            return None
        return key

    def issue(self, kind, now):
        """An `app` or `org` token for the person, signed like a real one; the app reads it unverified."""
        return jws({"aud": [AUD], "email": EMAIL, "exp": now + ACCESS_TTL, "iat": now, "nbf": now, "iss": "https://" + TEAM_DOMAIN,
                    "sub": SUBJECT, "type": kind, "identity_nonce": os.urandom(8).hex()})

    def transfer(self, key):
        """The relay's long poll: the sealed tokens for `key`, once, after its sign-in was approved. Until
        then it holds the poll for a while and answers 404."""
        with self.condition:
            self.condition.wait_for(lambda: key in self.transfers, timeout=self.hold)
            sealed = self.transfers.pop(key, None)
        if sealed is None:
            return response(404)
        return response(200, [("Content-Type", "text/plain"), ("service-public-key", base64.urlsafe_b64encode(self.relay_public).decode())], sealed)
