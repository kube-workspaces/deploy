---
title: Display tiers & audio
---

# Display tiers & audio

VM workspaces have **two display tiers** served over **three transports**.
This page summarises what each tier does, which client plays it, what audio
you get, and what the guest and the client machine each need. Operational
detail for enabling and rolling back Tier 1 lives at the bottom of this page.

## Terminology

Four words that are easy to mix up:

| Term | Meaning | Values |
|---|---|---|
| **Display tier** | The support contract: universal floor vs premium in-guest path. Shown as **Tier** in the desktop client's debug card. | `Tier 0`, `Tier 1` |
| **Transport** | Which software serves the pixels. Shown as **Transport** in the debug card. | `RFB`, `Selkies`, `Agent` |
| **Wire protocol** | The bytes on the WebSocket. Shown as **Protocol** in the debug card. | RFB over WebSocket, Selkies H.264/Opus over WebSocket, `kw-agent-v1` over WebSocket |
| **Network quality tier** | The adaptive-quality step *inside* Tier 0 RFB. **Applies to Tier 0 only** — see [Network quality tiers](#network-quality-tiers-tier-0-only). | Poor / Fair / Good (+ idle Lossless) |

Both `Selkies` and `Agent` transports are **Tier 1**. There is no Tier 2.

## Overview

| | **Tier 0 — RFB/VNC** | **Tier 1 — Selkies agent** | **Tier 1 — `kw-agent` agent** |
|---|---|---|---|
| Status | **Universal floor**, always available | **Implemented**, auto-selected where advertised | **Released** (`workspace-agent v0.1.0`, desktop client `v0.11.0`), live-proven |
| Path | API `/v1/workspaces/{name}/vnc` bridge → KubeVirt VNC subresource | Selkies agent in the guest, via the workspace proxy (pixel traffic stays off the Kubernetes API server) | `kw-agent` in the guest, via the proxy `/agent/` bridge (also off the API server) |
| Needs an agent in the guest? | No — works on any image | Yes — only images that ship pinned Selkies 2.0.0rc0 | Yes — only images/hosts running `kw-agent` (canonical guest port **44787**) |
| Video | Tight/JPEG, ZRLE, Hextile, CopyRect, Raw; no interframe coding | H.264 (YUV420P software, up to 4096×4096) | H.264 (software MF encode; DXGI capture on Windows) |
| Audio | Web client plays QEMU PCM; desktop client detects only (see [Audio](#audio)) | Opus → stereo 48 kHz PCM | Opus (WASAPI loopback on Windows) → stereo 48 kHz PCM |
| Resize | Fluid `SetDesktopSize` via virtio-gpu EDID + guest poller (Linux desktop images) | Window resize forwarded to the agent | True guest mode changes with ACK (`hello.displayModes`, nearest-mode snap) |
| Clipboard | RFB cut-text | Bidirectional text | Bidirectional Unicode text (capability-gated) |
| Input | Full keyboard/pointer | Full keyboard/pointer | Full keyboard/pointer (capability-gated; secure-attention stays unavailable) |
| Works when | Always: pre-boot, BIOS/GRUB, login screen, dead guest network | Only after the guest has booted and the agent is up | Only after the guest has booted and the agent is admitted in a logged-in console session |
| Best for | Recovery, setup, any image | Premium Linux desktops today | Premium Windows desktops; the cross-platform successor (Linux adapters follow) |

Tier 0 is the out-of-band console and is never going away. Tier 1 is the
premium path for interactive use.

## Client support

| | Web client (browser) | Desktop client (native) |
|---|---|---|
| Tier 0 RFB | ✅ noVNC display, adaptive quality, Sound toggle | ✅ adaptive RFB quality, lossless idle repaint; audio detect-only |
| Tier 1 Selkies | ❌ no Selkies viewer yet (planned: integrated premium component) | ✅ auto-selected with sticky Tier 0 fallback |
| Tier 1 Agent | ❌ no agent viewer yet (same planned component) | ✅ explicit opt-in premium window, or clipboard-helper beside RFB |
| Shared display observe | ✅ `/workspaces/{name}/display` observer | ✅ **Observe** action observer |
| Container `/audio/` | Via proxied audio socket where the image wires it | Embedded webview child where shipped; else system browser |

The desktop client never lets the user pick a tier: Selkies is chosen from
the workspace's image advert, the agent window opens automatically where the
image advertises protocol `agent` (`--agent-tier` forces it even without an
advert, `--no-agent-tier` keeps Selkies/RFB), and anything unplayable falls
back to Tier 0 for the rest of the session.

## Tier 0 — universal RFB

For `vm` workspaces the `/vnc` bridge dials the VMI VNC subresource and
proxies **raw RFB bytes** — no server-side decoding. The frontend attaches a
noVNC client; the desktop client drives its own RFB session. Both ends talk
RFB end-to-end, including `SetDesktopSize` for fluid resize. VNC is a
single-session, last-wins subresource: the platform holds one slot per
workspace per mode and answers **409 Conflict** while it is held, with
explicit take-over consent — a second dial never silently severs the first.
See [Virtual Machines](vm.md#vnc-display--get-v1workspacesnamevnc) for the
bridge, session registry and `virtctl` recovery paths.

Tier 0 needs nothing from the guest image and no libraries on the client
machine. It is the recovery path: if Tier 1 fails or the guest network is
dead, Tier 0 still shows the console.

## Network quality tiers (Tier 0 only)

The Poor / Fair / Good steps belong to the **Adaptive Quality Controller
(AQC)** that tunes Tier 0 RFB requests. They do **not** apply to Tier 1:
Selkies and Agent sessions have no quality tiers — Tier 1 idles by dropping
capture cadence instead (30 fps → at most 5 fps after one second without
pixel changes or input; motion/input restores it on the next 100 ms tick).

- **Web AQC** (`frontend/src/lib/adaptive-quality-controller.tsx`): measures
  throughput and RTT over the noVNC socket, picks Poor/Fair/Good with
  3-second hysteresis, and requests a full-screen refresh after 1 second
  idle. Full metrics/encoding detail lives in
  [Virtual Machines](vm.md#adaptive-quality-controller-aqc).
- **Native adaptive controller**
  (`desktop-client/internal/rfb/adaptive.go`): same bridge, same default-on
  behaviour. Samples framebuffer bytes, changed area, decoder occupancy and
  request-to-update latency in 400 ms windows; starts at Good, drops one
  tier immediately under pressure, recovers after 2 seconds of headroom;
  slows requests from 16 ms to 80 ms while idle and repaints once losslessly
  after sustained low motion. Thresholds are pressure ceilings, not measured
  capacity — see [Virtual Machines](vm.md#native-desktop-client--adaptive-rfb-quality)
  for the table.

Both controllers are client-side: no guest agent, Helm value, API setting
or proxy route is involved. CLI flags (`--quality`, `--compress`,
`--adaptive-quality=false`) pin Tier 0 to a fixed mode.

## Tier 1 — Selkies agent (Linux premium)

Tier 1 uses the guest's Selkies H.264/Opus WebSocket through the workspace
proxy. The desktop client automatically selects it for a workspace
advertising `remoteDesktop.protocol: selkies`, with sticky Tier 0 (VNC)
fallback when the agent or the local decoders are unavailable. Native
diagnostics remain available through `selkies-probe --decode` / `--present`.

### Guest requirements

- Image ships the pinned **Selkies 2.0.0rc0** agent (e.g. the `debian-xfce`
  catalog recipe) and advertises it:
  `remoteDesktop: {protocol: selkies, port: 8080}`, with `defaultPort: 8080`
  and Service port 80 forwarding kept coordinated with the SSH port mapping.
- An Image CR advert is capability metadata, not agent readiness. Updating
  it does not install an agent into an existing persisted disk — pilot a
  fresh disposable VM first and keep VNC/SSH recovery while testing a guest
  upgrade on a snapshot or clone.
- The API/proxy enforce cross-replica ownership with Kubernetes Leases
  (`/tier1/claim`, renewal/release, status, takeover); `DISPLAY_API_URL`
  must be configured on the proxy. Guest NetworkPolicy (example below)
  prevents direct pod/Service access from bypassing proxy authorization.

### Client requirements

The graphical client and diagnostic are built with `CGO_ENABLED=0`. At
runtime they load FFmpeg **libavcodec 59 + libavutil 57** (FFmpeg 5.1 ABI)
and libopus. Other FFmpeg major versions are rejected; renaming a newer
library does not make it ABI compatible:

| OS | H.264 dependencies | Opus |
|---|---|---|
| Linux | `libavcodec.so.59`, `libavutil.so.57` | `libopus.so.0` |
| macOS | `libavcodec.59.dylib`, `libavutil.57.dylib` | `libopus.0.dylib` |
| Windows | `avcodec-59.dll`, `avutil-57.dll` | `opus.dll` or `libopus-0.dll` |

Libraries and their transitive dependencies must match the executable's CPU
architecture. Linux/macOS use the OS loader's configured library locations.
Windows uses safe default DLL search directories, including the application
directory, excluding the working directory and PATH. The libraries are not
bundled: missing/incompatible video decoders trigger RFB fallback, and
missing audio decode disables audio only (video continues).

Only YUV420P software H.264 is supported, up to 4096×4096; limited/full-range
BT.601 and BT.709 are converted to RGBA. Audio output is 48 kHz stereo
signed 16-bit PCM. Presentation retains the latest decoded frame and at most
200 ms of queued PCM. The pinned WebSocket audio/video headers have no shared
presentation timestamps: playback uses ordered arrival and the output sample
clock, with latest-frame video and bounded PCM rather than a fabricated
timestamp synchronizer. On a reconnect, queued PCM and the output device
queue are reset before new-generation playback.

### Session behaviour

Startup has a five-second dial-to-decoded-frame budget. After a live drop
the client tries at most two reconnects within ten seconds, preserving the
window/last frame, clearing queued audio/input, and recreating decoders;
exhaustion falls back to RFB for the remainder of the session. HTTP 401/403,
recovery-time 409 and agent refusal are surfaced, never bypassed by
fallback. An initial 409 opens the busy-display overlay with Enter-to-take-over
consent. Interactive capture requests 30 fps normally and at most 5 fps
after one second without decoded-image changes or user input. Physical
quality/bandwidth benefits must still be measured during acceptance.

## Tier 1 — `kw-agent` agent (cross-platform premium)

The `workspace-agent` repo owns the baked-in guest agent (Windows first,
Linux adapters after Selkies parity): same-console-session H.264 video,
Opus playback audio and true guest resolution changes, with KubeVirt VNC
retained as the setup/recovery path. Wire spec:
`workspace-agent/docs/protocol/kw-agent-v1.md`.

### Guest requirements

- `kw-agent` running **in the logged-in console session** (not a SYSTEM
  service / Session 0 — Session 0 yields no pixels and no audio endpoints),
  serving the canonical port **44787** declared via the Image's
  `proxyConfig.agentPort` (forwarded through the KubeVirt masquerade
  interface and exposed on the workspace Service by the controller).
- Audio needs a real render endpoint: the opt-in Image `soundDevice: ich9`
  plus the inbox Windows HDA driver, with console-session audio playing.
  No microphone in this version.
- Arbitrary resize modes need a guest display driver exposing them (a
  signed virtual-display driver where the stock adapter offers only fixed
  modes). The agent advertises real modes in `hello.displayModes`; viewers
  snap requests to advertised modes.
- Clipboard is Unicode text up to 64 KiB, capability-gated (`--clipboard`).

### Client requirements

Same FFmpeg 59 / libopus native libraries as Selkies (not bundled). The
premium window opens automatically where the image advertises protocol
`agent` — the client never guesses agent availability from other capability
data. Refusal, busy seats and auth
failures surface; only recoverable transport failures fall back to Tier 0.
Input, resize and clipboard are capability-gated per session (unsupported
input is dropped, not fatal), with focus-loss key cleanup. The debug card
reports agent capture/video/audio/ACK/keyframe/mode counts.

A lighter mode pairs the agent with RFB: `shell --agent-clipboard` (or the
one-shot `clipboard --read/--write` CLI) carries guest Unicode clipboard
while the display stays on Tier 0 — no video decoder libraries needed.

### Platform requirements

Proxy `/agent/` bridge with `AGENT_API_URL` configured (helm + kustomize),
API attach tickets (attach → renew → release, second attach gets 409), and
controller `agentPort`/Service plumbing from the Image. The display is
single-session across transports: a Tier 1 controller and Tier 0 RFB
observers coexist through the shared-display broker (observer-only
generation while the seat is tier1-held); native Tier 1 observers are not
offered.

## Audio

| Tier | Web client | Desktop client | Guest needs |
|---|---|---|---|
| Tier 0 RFB | ✅ plays QEMU PCM via WebAudio (**Sound: On/Off** toggle; click unlocks the AudioContext) | Detects the QEMU sound device only (`probe --audio`); no playback | Sound device (`soundDevice: ich9`) + guest audio server |
| Tier 1 Selkies | n/a (no web viewer) | ✅ Opus → 48 kHz stereo PCM, mute toggle | Selkies agent + guest audio stack |
| Tier 1 Agent | n/a (no web viewer) | ✅ WASAPI-loopback Opus → 48 kHz stereo PCM, mute toggle | `kw-agent --capture-audio` in the console session + render endpoint |
| Container `/audio/` | Via the proxied audio socket where wired | Same (embedded webview / system browser) | Image with `audioPort` + matching `additionalPorts` entry (e.g. 6902), see [Proxy](proxy.md#audioport) |

Notes:

- No tier captures microphone audio.
- Tier 1 audio has no shared A/V presentation timestamps (ordered
  arrival + sample clock, bounded queues); no timestamp-sync or
  physical-latency guarantee is claimed.
- Missing audio decode on the client disables audio only — video continues.
- Container `/audio/` routing is independent of VM display audio: the proxy
  routes `/audio/` paths to a separate backend Service port (e.g. a
  PulseAudio → websockify process). `audioPort` alone does not expose the
  port — it needs the matching `additionalPorts` entry or noVNC fails with
  a protocol error.

## Recommended setup (best display & audio)

**Client side: the desktop client.** It is the only client that plays all
three transports, with adaptive Tier 0 quality, Opus audio decode, mute,
clipboard sync, guest resize, fullscreen keyboard grab and the Debug
connection card. Install the Tier 1 runtime libraries beside it (FFmpeg
libavcodec 59 + libavutil 57 and libopus, matching the exe architecture) —
without them even the best guest falls back to Tier 0. The web client is
Tier 0 only until the integrated premium viewer lands.

**Guest side: a Tier 1-capable image, per OS.**

- *Linux:* an image that ships the pinned Selkies 2.0.0rc0 agent with
  `remoteDesktop.protocol: selkies` (the `debian-xfce` catalog recipe is the
  reference), `videoDevice: virtio` for the paravirtual display, and a
  working guest audio stack for Opus capture. Add `soundDevice: ich9` if
  you also want Tier 0 web audio on the same image.
- *Windows:* `kw-agent` running in the logged-in console session on guest
  port 44787 (Image `proxyConfig.agentPort`), the `ich9` sound opt-in with
  the inbox HDA driver for a real render endpoint, and a display driver
  exposing the modes you want (stock Basic Display offers fixed modes
  only). The Linux agent adapters follow after Selkies parity — until then
  Selkies stays the Linux default.

**Platform side:** proxy Tier 1 / `/agent/` bridges configured
(`DISPLAY_API_URL`, `AGENT_API_URL`), Lease-backed ownership on API + proxy,
and guest NetworkPolicy so agents are reachable only through the proxy.

Why this is best: H.264 interframe video beats RFB rectangles on any moving
content, Opus replaces PCM tricks, resize applies real guest modes instead
of scaling a fixed framebuffer, and pixel traffic stays off the Kubernetes
control plane. Tier 0 stays as the always-on recovery console regardless.

## Which should I use?

- **Just works everywhere, including recovery:** Tier 0. Pick nothing — it
  is the default and the fallback.
- **Best Linux desktop quality today:** Tier 1 Selkies (desktop client +
  Selkies-capable image). Keeps pixel traffic off the control plane.
- **Best Windows desktop quality / cross-platform future:** Tier 1 Agent
  (desktop client opt-in + `kw-agent` in the guest). True resolution
  changes, live-proven input, audible audio.
- **Watch together:** shared display observe (opt-in `KW_DISPLAY_SHARED=on`),
  one controller plus view-only observers — see
  [Shared display](shared-display.md).

## Diagnostics

Use a dedicated, unoccupied VM for agent diagnostics. The Selkies
diagnostic changes capture settings and resolution. Its direct/proxy socket
uses the proxy's ownership claim when routed through the platform; a direct
agent connection bypasses that ownership boundary — use direct diagnostics
only on an isolated guest.

From the desktop-client repository, with the session credential already in
`KW_SESSION`:

```sh
# Selkies: headed decode measurements
CGO_ENABLED=0 go run ./cmd/selkies-probe \
  --server https://workspaces.example.com \
  --namespace example --workspace desktop-0 \
  --present --duration 60s
```

Use `--decode` instead of `--present` for headless decode measurements.
JSON output separates received frames, decoded frames/audio samples,
presentation calls and queue drops. Neither a received-frame count nor an
SDL dummy-driver result proves real-display fps, audible sync or input
latency.

```sh
# Tier 0 audio advertisement check
kube-workspaces probe my-vm --audio
```

```sh
# Agent premium: headed presentation through the real viewer
agent-probe --present --duration 20s \
  --server https://workspaces.example.com \
  --namespace example --workspace desktop-0
```

The desktop client's **Debug** toolbar button opens a live connection card
(tier, transport, wire protocol, audio state, throughput, activity,
per-transport counters) — the fastest way to confirm which tier is actually
serving a session.

For a repeatable local fixture check on Linux with FFmpeg's `libx264`
encoder:

```sh
KW_NATIVE_MEDIA_TEST=1 CGO_ENABLED=0 go test -v \
  ./internal/media ./cmd/selkies-probe
```

The fixture presentation test explicitly uses SDL dummy video/audio
devices. Without `KW_NATIVE_MEDIA_TEST=1`, native tests skip; a passing
default test run therefore does not constitute decoder runtime validation.

## Acceptance status

Implemented and live-proven: Tier 0 everywhere (both clients, adaptive
quality, web audio); Selkies auto-selection with sticky fallback and
bounded reconnect on the desktop client; agent video/input/resize/clipboard
and audible audio on the desktop client (`workspace-agent v0.1.0`,
desktop client `v0.11.0`).

Still open before broad rollout claims: real-display A/V sync, input
latency, constrained-network behaviour and static-text/full-motion quality
measurements; native runtime matrix beyond Linux amd64 (macOS/Windows load,
decode, playback and missing-library fallback); live two-replica fencing
proof; the pinned-agent multi-client spike for shared observers; the
integrated web premium viewer; Linux agent parity with Selkies. Tracked in
the (private) tracking repo's Windows/premium plan and real-display
validation plan.

## Deployment order and persistent disks

### Agent isolation

[`tier1-agent-networkpolicy.yaml`](./tier1-agent-networkpolicy.yaml) is a
per-workspace example for the default agent port 8080. Set its workspace
namespace/name and the trusted proxy namespace before applying. Its
selectors match the controller's `workspace-name` launcher-pod label and
both deployment paths' proxy component label. Namespace and pod selectors
are ANDed so a tenant cannot bypass isolation merely by labelling its own
pod as a proxy.

The policy permits agent access only from that proxy and retains TCP/22 for
SSH. Other inbound services and any CNI-specific KubeVirt migration rules
need explicit site rules; this example is deliberately not installed
globally. NetworkPolicies are additive, so another broad ingress allow can
defeat it. Verify proxy access succeeds and an unrelated tenant pod's
direct pod-IP and Service-port access fails. Keep the pod port (8080), not
Service port 80, in the policy. A CNI that does not enforce NetworkPolicy
cannot establish this boundary. Host/root administrators remain outside
this tenant isolation model.

Land the API/proxy ownership implementation and isolation configuration
first, then the native selector, then coordinate any image capability
advert and catalog/chart updates. Chart releases, catalog releases and
ArgoCD `targetRevision` updates remain deliberate operator actions. A
component `:latest` push does not apply chart-side changes.

Keep guest `defaultPort: 8080`, Service port 80 forwarding, and SSH
additional port 22 coordinated, and the agent port (44787 for `kw-agent`)
declared via `proxyConfig.agentPort` so the controller forwards and exposes
it. An Image CR advert is capability metadata, not agent readiness:
updating it does not install an agent into an existing persisted disk.
Pilot a fresh disposable VM first; retain VNC/SSH recovery while testing an
explicit guest upgrade on a snapshot or clone of an existing disk.

## Redistribution

The client bundles FFmpeg and Opus libraries in its release packages so Tier
1 works out of the box. The recorded bundling decision (kept current in
`third_party/media-libs/` in desktop-client):

- **FFmpeg is LGPL-only by construction:** pinned 5.1.x source, built with
  `--disable-gpl --disable-nonfree --disable-version3`, decoder-only (H.264
  decode; no x264/x265). Prebuilt "full" shared FFmpeg must never be
  substituted — those builds enable GPL components. The per-target
  `BUILD-INFO` files shipped in every package record source, version and the
  full configure line; `MANIFEST` pins source URLs and hashes.
- **Opus** uses the BSD-style license published with libopus; attribution
  (`NOTICE`, `COPYING.opus-BSD`) ships in every package.
- Both are used through **dynamic loading** and stay replaceable with any
  ABI-compatible build (drop-in beside the executable takes precedence).
  The client never statically links either library.

Any future change of source, version or flags must update the manifest,
rebuild every target, and refresh the shipped notices — exactly as this
section requires. FFmpeg's license depends on its configuration: the Debian
validation build enables GPL components, so it is not evidence that the
shipped LGPL-only bundle is compliant; only the recorded bundle build is.
Opus uses the BSD-style license published with libopus. Dynamic loading alone
does not remove license obligations. Include native libraries in the platform
signing/notarization work when distribution is implemented.

## Rollback

For a diagnostic, close its window/process and reconnect using VNC. A
native-library initialization failure closes the socket and the graphical
client falls back to VNC. Do not uninstall guest display/audio components
or discard its persistent disk to recover the console.

To roll back automatic selection, withdraw the image advert for subsequent
connections, explicitly revoke active Tier 1 owners, and reconnect through
the normal VNC consent flow. Verify capability caches have expired. Removing
an advert does not close an existing socket. Revert primary-port changes
only together with Service and SSH mappings. The shared-display gate rolls
back independently (`KW_DISPLAY_SHARED` unset) — see
[Shared display](shared-display.md#rollback).

## See also

- [Virtual Machines](vm.md) — the `/vnc` bridge, [AQC](vm.md#adaptive-quality-controller-aqc)
  and [native adaptive quality](vm.md#native-desktop-client--adaptive-rfb-quality) detail
- [Desktop client](desktop-client.md) — downloads, install, VM vs container behaviour
- [Shared display](shared-display.md) — multi-session observe/control
- [Proxy](proxy.md) — workspace traffic routing and [`audioPort`](proxy.md#audioport)
  for container audio
