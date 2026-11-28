# Third party notices

## OpenClaw

The device authentication payload construction is adapted from OpenClaw at commit `a8a7ce94eb544f3c39cf25f674471c3f1e3fe4ab`.
Protocol behavior is implemented against that source snapshot; OpenClaw is an independent project.

Source: https://github.com/openclaw/openclaw/blob/a8a7ce94eb544f3c39cf25f674471c3f1e3fe4ab/apps/shared/OpenClawKit/Sources/OpenClawKit/DeviceAuthPayload.swift

The shared-session attribution rules follow the OpenClaw Control UI at commit `b1d355fcc9fcf91a4514c2612ce7b33211c710b6`: sender identity validation, the rule for which rows are the viewer's own, and the avatar hue and initials. The same license applies.

Sources: `src/chat/sender-identity.ts`, `ui/src/lib/chat/sender-label.ts`, `ui/src/pages/chat/components/chat-message-sender.ts`, and `ui/src/lib/identity-avatar.ts` in https://github.com/openclaw/openclaw/tree/b1d355fcc9fcf91a4514c2612ce7b33211c710b6

MIT License

Copyright (c) 2026 OpenClaw Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## TweetNaCl

`Sources/CTweetNaCl/tweetnacl.c` and `Sources/CTweetNaCl/include/tweetnacl.h` are TweetNaCl version 20140427, unmodified, from https://tweetnacl.cr.yp.to/software.html.
TweetNaCl is public domain (https://tweetnacl.cr.yp.to/). SHA-256: `tweetnacl.c` 02e65bc3013ff2168983365e55906bc783c4c7e0a60d8100f17bb303a17175c4, `tweetnacl.h` 43f29ad721d9927b747b0100ab4160c119e7bb180c7c98a66e4bf79d31244287.

## cloudflared

The Cloudflare Access browser sign-in follows the protocol of `cloudflared access login` in https://github.com/cloudflare/cloudflared at commit `ead8b814f22d9014581c8de40be8b175426d5e86` (Apache License 2.0).
No cloudflared code is copied. The client reimplements the protocol, and its tests check the sign-in links against cloudflared's output.
