# Platform seams

The host-side services this engine offers a game: network transports, player identity, achievements and stats,
cloud saves, lobbies. This note records what is decided, what is built, and the questions that are still open.

Status on 2026-11-23 (phase 1): the Transport seam is built with web, native UDP, native TCP and in-memory backends.
The other four seams exist as traits with one local implementation each; no platform implementation of them exists
yet.
Device seams (haptics, motion, screen, pointer lock, camera, microphone) are built for the web and in memory: see the last section.

## Rules every seam follows

- **A trait, chosen at compile time.** A program names its backend when it is built (`comptime NetTransport =
  WebSocketTransport` in `app/main.mojo`); nothing is looked up at run time. This is the repo's existing style (the
  `GameMode` seam, `game/mode.mojo`). Mojo 1.2 cannot store function-typed fields in a struct, so a backend is a
  struct that implements the trait, with no callbacks stored in it.
- **One web and one native implementation per seam**, plus an in-memory one for tests where that makes sense.
- **Poll, never call back.** Asynchronous results wait in a queue and the game takes them with a `poll` inside its
  frame. Nothing calls into the wasm module from the host. This is the rule `net_poll` and `os_poll` already follow
  (ludens-wasm-rt's re-entry rule).
- **Byte payloads.** A seam moves bytes. It does not know the game's message format.
- **Capacity: drop and count.** When a queue is full or a message is larger than the receiver's buffer, the backend
  drops that one message, counts it, and keeps going. The next poll returns the message behind the dropped one. This
  is the existing `net_poll` rule (README B5, `tests/test_net.mjs`).
- **Where the code lives.** `platform/` holds the traits and the backends. It imports only the standard library and
  itself, and holds Mojo and Markdown only (layout rule R8, `scripts/check_layout.py`). The JS half of a web backend
  stays in `shell/web/` (rule R1: a shell only implements imports).
- **Native backends stay out of the wasm64 module.** They call libc through `external_call`. The module's import
  audit rejects any import that is not declared in `wasm.toml`, so `app/main.mojo` imports only the web backend's
  module. `platform/__init__.mojo` re-exports nothing for the same reason.

## Transport

One connection to one peer that carries byte messages. Source: `platform/transport.mojo`.

```mojo
trait Transport(Movable):
    def delivery(self) -> Int                             # DELIVERY_UNRELIABLE or DELIVERY_RELIABLE_ORDERED
    def max_message(self) -> Int                          # longest message send accepts
    def send(mut self, ptr: UInt64, length: Int) -> Int   # NET_OK, NET_NO_PEER, NET_INVALID, NET_FULL
    def poll(mut self, buf: UInt64, cap: Int) -> Int      # > 0 length, NET_NONE, NET_DROPPED, NET_CLOSED
    def dropped(self) -> Int                              # received messages dropped for being over cap
    def send_dropped(self) -> Int                         # outgoing messages dropped with NET_FULL
    def close(mut self)
```

`send_bytes` and `poll_bytes` do the same for a `List[UInt8]`.

| Result | Value | Meaning |
|---|---:|---|
| `NET_OK` | 0 | sent, or queued to go out on a later call |
| `NET_NONE` | 0 | poll: nothing waiting |
| `NET_DROPPED` | -1 | poll: the next message was larger than `cap`. It is dropped and counted; the next poll returns the message behind it |
| `NET_NO_PEER` | -1 | send: not connected, closed, or the peer is gone |
| `NET_CLOSED` | -2 | poll: the connection is over, and every message that arrived before the end has been returned |
| `NET_INVALID` | -3 | send: length 0, or more than `max_message()` |
| `NET_FULL` | -4 | send: the outgoing queue is full. The new message is dropped and counted |

The values -1 and 0 are the ones `net_send` and `net_poll` already return, so the web backend passes them through
unchanged.

An empty message cannot be told apart from `NET_NONE`, so it is never delivered. The native backends refuse one with
`NET_INVALID`. The web backend hands it to the host unchanged, as before; the receiver never sees it.

**Two delivery classes.**

- *Unreliable*: a message can be lost, duplicated or reordered, and arrives whole or not at all.
- *Reliable ordered*: every message arrives once, in the order sent, until the connection closes.

The rollback netcode in ludens-core (gameplay/netcode.mojo) resends every input the receiver has not acknowledged in
each message. It therefore runs over an unreliable transport and needs no retransmit protocol. Lobby traffic,
chat and save uploads need the reliable class.

A transport has one delivery class. A session that needs both opens two transports.

**Browsers cannot open raw UDP or TCP sockets.** A web build gets datagrams only from WebRTC DataChannels or
WebTransport, and streams only from WebSocket, WebTransport or WebRTC.

### Backends

| Backend | Target | Delivery | Max message | Status |
|---|---|---|---:|---|
| `WebSocketTransport` (`platform/transport_web.mojo`) | web | reliable ordered | no own limit (the receiver's cap) | built: the existing `net_send` / `net_poll` imports behind the trait |
| `MemoryTransport` (`platform/transport_memory.mojo`) | both | reliable ordered | 16 MiB (settable) | built: an in-process pair, for tests |
| `UdpTransport` (`platform/transport_udp.mojo`) | native | unreliable | 65507 | built |
| `TcpTransport` + `TcpListener` (`platform/transport_tcp.mojo`) | native | reliable ordered | 16 MiB | built: u32 little-endian length prefix per message |
| WebTransport (QUIC) | web | both (datagrams and streams) | datagrams: limited by the path MTU | later. Needs an HTTP/3 server with WebTransport support |
| WebRTC DataChannel | web | both (per channel) | differs by browser | later. Needs a signalling server, plus STUN, and TURN for peers behind symmetric NAT |
| QUIC via ngtcp2 | native | both | datagrams: path MTU | later. conda-forge has ngtcp2 1.25. ngtcp2 does no I/O and no TLS: it needs a crypto backend (for example its OpenSSL or GnuTLS helper) and a UDP socket, which this phase provides |
| WebRTC via libdatachannel | native | both | as WebRTC | later. Not on conda-forge: build from source (CMake; it bundles libjuice and usrsctp as submodules and needs a TLS library such as OpenSSL) |

### Phase 1 details (built)

- **Web.** The JS half is unchanged (`shell/web/net_host.mjs`), and so are the wasm imports (`net_send(i64, i64) ->
  i32`, `net_poll(i64, i64) -> i64`). `app/net.mojo` moved into `platform/transport_web.mojo`. The host does not
  report the socket's end, so this backend never returns `NET_CLOSED`.
- **Native sockets** (`platform/socket.mojo`). libc through `external_call`. Every send and recv uses `MSG_DONTWAIT`.
  `TcpListener.accept` runs `poll(2)` with a zero timeout first. There is no `fcntl`, because it is variadic and
  `external_call` cannot call a variadic function correctly on arm64. `TcpTransport.connect` blocks once, while the
  connection is set up. Addresses are numeric IPv4 or IPv6, chosen by whether the host string contains `:`. The
  constants are Linux values; the macOS branch is taken from the macOS headers and has not been built or run.
- **UDP** is one socket connected to one peer. A datagram larger than `cap` is read in full into a 64 KiB scratch
  buffer, then dropped and counted. A full send buffer gives `NET_FULL`. UDP has no connection, so a peer's end is
  not guaranteed to be seen. After an ICMP port-unreachable error, Linux reports `ECONNREFUSED` on a connected
  socket; that becomes `NET_CLOSED`.
- **TCP.** Outgoing bytes the kernel does not take at once wait in a queue of at most 4 MiB and go out on the next
  send or poll. A message larger than `cap` is skipped in the stream without being buffered. After the peer ends the
  stream, the messages that arrived before the end are returned first, then `NET_CLOSED`. A length of 0 or more than
  16 MiB in the stream is a protocol error and closes the connection. `TCP_NODELAY` is set.
- **Test.** `pixi run -e wasm test-transport` runs `tests/platform_transport.mojo`, built with the standard library
  only. It runs one script over memory, UDP on 127.0.0.1 and TCP on 127.0.0.1:
  - 16 messages of 1 to 65507 bytes, alternating direction, then a burst of 8;
  - the hash of the received bytes must equal the hash of the sent bytes on every backend;
  - an empty poll;
  - an empty message and one over `max_message()`, both refused;
  - a message over `cap`: answered `NET_DROPPED` once and counted, and the next one arrives intact;
  - for TCP only, a 1 MiB message over `cap` is skipped as well;
  - the closed-peer behaviour above;
  - the sockaddr bytes for 127.0.0.1 and ::1, built without a socket, so the IPv6 layout is checked even where the
    kernel has no IPv6.

  Every wait has a 2 s deadline. ::1 is tested when the host has IPv6 loopback. On the development container it has
  none (`socket()` fails with errno 97), so IPv6 socket I/O is untested. Result on the container: 44 checks passed, 0
  failed. A host with ::1 (the GitHub runner may have it) runs 27 more.

### Transport: open questions

- **Server fan-in.** A transport is point to point. A UDP server with many clients needs `recvfrom` with the
  sender's address, or one transport per client with the demultiplexing done above it. Not decided.
- **Non-blocking connect.** Needed for a client that must not stall a frame while it connects. Not decided.
- **Close on the web.** There is no close import for the WebSocket, and the socket's end is not reported to the app.
  It would take a new `net_*` import.
- **Name resolution.** Only numeric addresses for now. A `getaddrinfo` call blocks, so name resolution belongs off
  the frame thread or in the launcher.
- **Encryption.** UDP and TCP carry plain bytes. QUIC and WebRTC encrypt by design. Whether TCP gets TLS, or the
  native path goes straight to QUIC, is not decided.

## Identity, achievements and stats, cloud save, lobby

Each seam is a trait with one local implementation, so a game can be written against it before any platform backend
exists. A request returns at once; its result is a packet the game takes with `poll(buf, cap)`, in the layout
`os_poll` already uses: `[kind u8][id u32 LE][status u8][payload]` (`platform/packets.mojo`, `PacketQueue`). `id`
is the caller's number for the request. Every queue follows the drop-and-count rule: a result over `cap` is answered
-1 once and counted (`dropped()`); a full queue of 1024 results drops the new one and counts it.

| Seam | Module | Trait methods (besides `poll` and `dropped`) | Local implementation |
|---|---|---|---|
| Identity | `platform/identity.mojo` | `player_id()`, `token()` (opaque bytes for a game server to verify with the backend), `sign_in(id)` | `LocalIdentity(name)`: the token is "local:" and the name, which no server can trust |
| Achievements and stats | `platform/achievements.mojo` | `unlock(id, name)`, `set_stat(id, name, value)`, `is_unlocked(name)`, `stat(name)` | `LocalAchievements`, in memory |
| Cloud save | `platform/cloud_save.mojo` | `write_request(id, slot, ptr, length)`, `read_request(id, slot)`; up to 64 MiB a slot, the os_host.mjs file limit | `MemoryCloudSave`, in memory |
| Lobby | `platform/lobby.mojo` | `create(id, name, max_members)`, `join(id, name)`, `leave(id)`, `current()`; events for members joining and leaving | `MemoryLobbyHub().member(player_id)`: every member of one hub sees the same lobbies |

They are one seam per trait, not one combined service, because the platforms differ in which ones they offer. Achievements and stats
share a trait because every listed backend has both. A cloud save is bytes, for example the output of
ludens-core's ld_world_save. `pixi run -e wasm test-transport` also runs `tests/platform_services.mojo`: 33 checks
on the four local implementations (results in order, invalid requests refused, the over-cap drop, lobby membership
events). Nothing in `app/` uses these seams yet.

| Implementation | Seams | What it needs |
|---|---|---|
| Local (in memory, or the app's own storage) | all four | Nothing. The in-memory ones are built (above). A cloud save kept in the app's own storage is `app/os_cloud_save.mojo` (web, through `os_file_write` and `os_file_read_request`) and `platform/file_cloud_save.mojo` (native files); the save format and slots on top are in `docs/save-games.md` |
| Steam | all four | The Steamworks SDK's flat C API, in a future steamworks-mojo repository. Native only. Steam must be running, and a Steam app id is required. Ticket verification on the server side uses the Steam Web API |
| Google Play Games Services | identity, achievements and stats, cloud save (saved games) | The Android SDK, through a native Android shell (`shell/mobile/`, which does not exist yet). There is no web SDK |
| Web OAuth / OIDC with PKCE | identity | A redirect flow in `shell/web/` and an identity provider configured for the site's origin. The token goes to the game's own server for verification. Achievements, cloud save and lobbies then need that server |

### Open questions

- **Token form.** Whether the identity token stays opaque everywhere, or the seam also says which verifier it is
  for, is not decided.
- **Save conflicts.** How cloud save resolves two devices writing the same slot (last write wins, or keep both and
  let the game choose) is not decided.
- **Lobby addresses.** A lobby hands back a peer to connect to. That address is an IP and port for UDP or TCP, a
  Steam id for Steam networking, or a signalling session for WebRTC. The Transport API takes host strings now, which
  covers only the first case.

## Device seams (issue #135)

Built on 2026-11-24 for phases 1 and 2 of the issue: a trait, an in-memory backend and a web backend for each of haptics,
motion, screen, pointer lock, camera and microphone. Not built: the native Android shell backends (phase 3, after
ludens-core ROADMAP 17.104) and geolocation, share, clipboard and notifications (phase 4). Nothing in `app/main.mojo` uses
these seams yet, like the identity and cloud save seams before them.

| Seam | Trait and memory backend | Web backend (`app/os_device.mojo`) | Browser API the host uses (`shell/web/device_host.mjs`) |
|---|---|---|---|
| Haptics | `platform/haptics.mojo`, `MemoryHaptics` | `WebHaptics` | `navigator.vibrate`; `Gamepad.vibrationActuator.playEffect("dual-rumble")` |
| Motion | `platform/motion.mojo`, `MemoryMotion` | `WebMotion` | `devicemotion`, `deviceorientation`; `DeviceMotionEvent.requestPermission` where it exists |
| Screen | `platform/screen.mojo`, `MemoryScreen` | `WebScreen` | `requestFullscreen`, `screen.orientation.lock`, `navigator.wakeLock` |
| Pointer lock | `platform/pointer_lock.mojo`, `MemoryPointerLock` | `WebPointerLock` | `requestPointerLock`, `movementX` / `movementY` |
| Camera | `platform/camera.mojo`, `MemoryCamera` | `WebCamera` | `getUserMedia({video})`, a `<video>` drawn into a canvas, `getImageData` |
| Microphone | `platform/microphone.mojo`, `MemoryMicrophone` | `WebMicrophone` | `getUserMedia({audio})` into an AudioWorklet, a 1 s ring in the host |

Shared pieces are in `platform/device.mojo`: the device ids, `AVAIL_*` states, `DEV_*` return codes, the packet kinds and
`PermissionGate` (the permission state of an in-memory device).

Planned for the native Android shell (phase 3, not built): `VibratorManager` (amplitude and waveforms, which `vibrate_pattern` cannot
express today), `SensorManager`, Camera2 and `AudioRecord`. Phase 4 (geolocation, Web Share, notifications) has no trait yet.

**Availability.** `availability()` is `AVAIL_UNSUPPORTED` (no such API here, or an insecure page), `AVAIL_PROMPT` (usable
after a request), `AVAIL_GRANTED` or `AVAIL_DENIED`. `request_permission(id)` (haptics, motion, camera, microphone) answers
with a `KIND_DEV_PERMISSION` packet. A call on a device that is unsupported returns `DEV_UNSUPPORTED` (-5), on one that is denied
or not yet granted `DEV_NOT_GRANTED` (-6), on one that is already open `DEV_BUSY` (-7), and with an argument out of range
`DEV_INVALID` (-3). When a call can fail in more than one way the order is: haptics, unsupported then invalid; motion `start`, unsupported
then not granted; camera and microphone `open`, unsupported, not granted, invalid (a size or rate out of range, which is
refused before any prompt), then busy; screen requests, invalid then unsupported (which capability is needed depends on the op).

**Results and reads.** A request returns at once. Its result is a packet in the `os_poll` layout, kinds 32 to 36
(`KIND_DEV_PERMISSION`, `KIND_DEV_SCREEN`, `KIND_DEV_POINTER`, `KIND_DEV_CAMERA`, `KIND_DEV_MIC`), taken with the seam's `poll(buf, cap)`; `OsRouter`
(`app/os_router.mojo`) keeps one queue per kind, and per device for permission results, so the seams do not take each
other's packets. Reads of an open device are plain calls into a buffer the game owns, once per tick:

| Read | Returns |
|---|---|
| `Motion.read(ptr)` | the sequence number of the newest sample and 9 f32 (accel m/s², rotation rate deg/s, orientation deg), or 0 with the buffer untouched when nothing is newer |
| `Camera.read_frame(buf, cap)` | `w * h * 4` bytes of RGBA, or 0 when no frame is newer, or -1 when `cap` is too small (the frame stays). Frames the game did not read are counted in `skipped()` |
| `Microphone.read(buf, n)` | up to `n` f32 samples, oldest first. Over one second of unread samples the oldest are discarded and counted in `overruns()` |
| `PointerLock.take_delta(ptr)` | 1 and 2 f32 (dx, dy, pixels) since the last call while locked, else 0 |

**Browser rules the seams expose, not hide.** Fullscreen, pointer lock and (on iOS) the motion permission need a user
gesture; a request made without one answers `STATUS_ERROR`. Orientation lock works only while fullscreen, and leaving
fullscreen releases it. `navigator.vibrate` is missing on iOS Safari: `capabilities()` lacks `HAP_VIBRATE` there.
Motion needs a secure context (HTTPS or localhost). Chrome 158 defines `DeviceMotionEvent.requestPermission`, so
`availability()` is `AVAIL_PROMPT` there until the request is made. In headless Chrome the request was then granted at once.

**Rotation rate axes.** The W3C text puts `rotationRate.alpha` about z, `beta` about x and `gamma` about y. Chrome 158
reports alpha = x, beta = y, gamma = z (measured with DevTools sensor overrides, `scripts/device_web.mjs`). The host uses
Chrome's order when the user agent contains `Chrome/` and the W3C order otherwise. The second branch is a reading of the
text: no Firefox or Safari was available to check it.

**Microphone range.** Samples are nominally in [-1, 1]. Chrome's synthetic microphone peaks at 1.13 and nothing clamps it.

### Device seams: verified

| Layer | Test | What it shows | What it does not |
|---|---|---|---|
| In-memory backends | `tests/platform_device.mojo`, 89 checks, in `pixi run -e wasm test-transport` | the contract above on each fake: limits and their order, permission states and packets, reads that return 0, drop-and-count, one-shot gestures | that a browser agrees |
| Web backends, fake browser objects | `tests/test_device.mjs`, 91 checks, `pixi run -e wasm test-device`: `app/device_probe.mojo` compiled to wasm64, booted through `scripts/node_app.mjs`, over the real `os_dev_*` imports and `shell/web/device_host.mjs` | the Mojo to JS to browser-API path: argument limits, packets and ids, the router giving each seam its own result when four are in flight, the unsupported / prompt / denied paths (iOS-style `requestPermission`, no `getUserMedia`, no vibrate, an insecure page) | that a real browser behaves like the fakes |
| Real Chrome 158, headless, Linux container | `scripts/device_web_check.py`, 47 checks, `pixi run -e wasm device-web`, with a synthetic camera and microphone, DevTools sensor overrides and a user activation | `navigator.vibrate` accepts a call; motion samples carry the overridden accelerometer, gyroscope and orientation values; the camera opens at 640 x 480 and 1280 x 720 and its frames have colour and alpha 255; the microphone opens at 48000 Hz and delivers about one second of non-silent samples; fullscreen, the wake lock and pointer lock are granted from a gesture and a mouse move reaches `take_delta`; release works | any hardware, see below |

Not verified on real hardware, by anyone, for any backend:

- The vibration motor and gamepad rumble: headless Chrome accepts `navigator.vibrate` and has no gamepad, so `rumble` is checked only against the fake actuator (`playEffect("dual-rumble", ...)` arguments).
- A real gyroscope, accelerometer and magnetometer: sample rate, latency, the axis signs on a phone, and the rotation rate axes outside Chrome.
- A real camera and microphone: the permission prompt UI, device selection, front and back cameras, the real frame rate and the real microphone latency.
- iOS Safari (no `navigator.vibrate`, the motion permission prompt), Firefox, Android Chrome.
- Orientation lock: no real browser run (headless Chrome desktop). It was checked against the fake `screen.orientation` only.

**Camera copy cost** (phase 2 of the issue): Chrome 158 headless, Chrome's synthetic camera, 4-core Linux container. Five full
runs of `pixi run -e wasm device-web`; each run reads 120 new frames per size through `WebCamera.read_frame` into wasm memory, each
timed over that one call (opening, waiting for the frame and the checks are outside the timed region; `performance.now()` has 0.1 ms
resolution). The table gives the range of each statistic over the five runs. No frames were skipped in any run.

| Size | Bytes per frame | Median per frame | p95 | Max |
|---|---:|---:|---:|---:|
| 640 x 480 | 1228800 | 2.9 to 3.4 ms (middle run 3.0) | 4.3 to 6.4 ms | 6.0 to 12.8 ms |
| 1280 x 720 | 3686400 | 7.3 to 8.5 ms (middle run 8.0) | 12.3 to 13.4 ms | 16.0 to 22.3 ms |

The first single run on an earlier container gave medians of 2.1 and 5.6 ms. The five runs above ran on a rebuilt container (different
host) and are 40 % slower; the machine, not the code, is the likely cause, but I did not test that. Quote the ranges, not the first run.

The same copy in its three steps (60 frames per run, median of the run, range over the five runs; 640 x 480 / 1280 x 720): `drawImage`
1.2 to 1.8 / 3.7 to 4.9 ms, `getImageData` 1.0 to 1.3 / 2.7 to 3.7 ms, `Uint8Array.set` into wasm memory 0.1 to 0.2 / 0.5 ms. The copy
into wasm is 4 to 7 % of the per-frame cost; the rest is the canvas draw and read-back. At 1280 x 720 the copy takes about half of a
16.7 ms frame at its median and more than one frame at its maximum. A phone's camera, resolution and frame rate were not measured; the
owner has to measure those.

Mutation check: `pixi run -e wasm mutation-device` applies 35 one-line breaks of the contract to the memory backends, the host and the
router, and requires the covering test to fail. It is not in CI (it builds a test per mutation, about 2 minutes). Result in the PR.
