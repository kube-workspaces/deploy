---
title: Tier 1 transport pilot
---

# Tier 1 transport pilot and rollback

Tier 1 uses the guest's Selkies H.264/Opus WebSocket through the workspace
proxy. The desktop client automatically selects it for a workspace advertising
`remoteDesktop.protocol: selkies`, with sticky Tier 0 (VNC) fallback when the
agent/decoder is unavailable. Native diagnostics remain available through
`selkies-probe --decode` / `--present`.

The API/proxy enforce cross-replica ownership with Kubernetes Leases. Current
desktop source also supports two reconnect attempts within ten seconds after
a live drop, preserving the window/last frame, clearing queued audio/input,
and recreating decoders. Startup has a five-second dial-to-decoded-frame
budget. HTTP 401/403/409 and agent refusal do not fall back around authorization
or ownership. Real deployment/native-platform acceptance remains scheduled work.

## Native runtime prerequisites

The graphical client and diagnostic are built with `CGO_ENABLED=0`. At runtime they load FFmpeg
**libavcodec 59 + libavutil 57** (FFmpeg 5.1 ABI) and libopus. Other FFmpeg
major versions are rejected; renaming a newer library does not make it ABI
compatible. Decoder library filenames are:

| OS | H.264 dependencies | Opus |
|---|---|---|
| Linux | `libavcodec.so.59`, `libavutil.so.57` | `libopus.so.0` |
| macOS | `libavcodec.59.dylib`, `libavutil.57.dylib` | `libopus.0.dylib` |
| Windows | `avcodec-59.dll`, `avutil-57.dll` | `opus.dll` or `libopus-0.dll` |

Libraries and their transitive dependencies must match the executable's CPU
architecture. Linux/macOS use the OS loader's configured library locations.
Windows uses safe default DLL search directories, including the application
directory, excluding the working directory and PATH. macOS/Windows library
packaging and runtime verification remain release gates.

Only YUV420P software H.264 is supported in this increment, up to 4096×4096;
limited/full-range BT.601 and BT.709 are converted to RGBA. Audio output is
48 kHz stereo signed 16-bit PCM. Presentation retains the latest decoded frame
and at most 200 ms of queued PCM. This bounds queues but does not establish
timestamp-based A/V synchronization or physical-display latency. The pinned
WebSocket audio/video headers have no shared presentation timestamps: playback
uses ordered arrival and the output sample clock, with latest-frame video and
bounded PCM rather than a fabricated timestamp synchronizer. On a reconnect,
queued PCM and the output device queue are reset before new-generation playback.

Interactive capture requests 30 fps normally and at most 5 fps after one
second without decoded-image changes or user input. `_arg_fps` is the pinned
agent's supported rate-control verb; motion/input restores active cadence on
the next 100 ms control tick. This reduces static CBR capture work without
using RFB's lossless-refresh algorithm on H.264. Physical quality/bandwidth
benefits must still be measured during acceptance.

## Run a diagnostic pilot

Use a dedicated, unoccupied VM with the pinned Selkies 2.0.0rc0 agent. The
diagnostic changes capture settings and resolution. Its direct/proxy socket
uses the proxy's ownership claim when routed through the platform. A direct
agent connection bypasses that ownership boundary; use direct diagnostics only
on an isolated pilot guest.

From the desktop-client repository, with the session credential already in
`KW_SESSION`:

```sh
CGO_ENABLED=0 go run ./cmd/selkies-probe \
  --server https://workspaces.example.com \
  --namespace example --workspace desktop-0 \
  --present --duration 60s
```

Use `--decode` instead of `--present` for headless decode measurements.
JSON output separates received frames, decoded frames/audio samples,
presentation calls and queue drops. Neither a received-frame count nor an
SDL dummy-driver result proves real-display fps, audible sync or input latency.

For a repeatable local fixture check on Linux with FFmpeg's `libx264` encoder:

```sh
KW_NATIVE_MEDIA_TEST=1 CGO_ENABLED=0 go test -v \
  ./internal/media ./cmd/selkies-probe
```

The fixture presentation test explicitly uses SDL dummy video/audio devices.
Without `KW_NATIVE_MEDIA_TEST=1`, native tests skip; a passing default test run
therefore does not constitute decoder runtime validation.

## Production enablement gates

Before production rollout, require all of the following evidence:

1. Deploy the implemented shared cross-replica display owner, with a proxy→API
   claim before every interactive socket upgrade (`DISPLAY_API_URL` must be
   configured). `/tier1/claim`, renewal/release, status and takeover use Leases;
   the process-local registry is only the same-replica fast path.
2. Revocation fences old input before a successor is admitted, including API
   restart, network partition, delayed control messages, stale claims and
   simultaneous VNC/Tier 1 connects. A local callback cannot cross a service
   boundary; closing a control socket alone is not a distributed fencing proof.
3. Guest NetworkPolicy or scoped guest authentication prevents direct pod/Service
   access from bypassing proxy authorization (pilot example below).
4. GUI input, clipboard, resize, bounded reconnect and Tier 0 fallback pass
   together. Access denial and ownership conflict retain their error/consent
   flow instead of falling back around the denial.
5. Linux/macOS/Windows × amd64/arm64 load/decode/playback and missing-library
   fallback checks pass on native runtimes. Cross-builds are separate evidence.
6. Real-display A/V sync, input latency, constrained-network behavior and
   static-text/full-motion quality have accepted results.

## Deployment order and persistent disks

### Pilot agent isolation

[`tier1-agent-networkpolicy.yaml`](./tier1-agent-networkpolicy.yaml) is a
per-workspace example for the default agent port 8080. Set its workspace
namespace/name and the trusted proxy namespace before applying. Its selectors
match the controller's `workspace-name` launcher-pod label and both deployment
paths' proxy component label. Namespace and pod selectors are ANDed so a
tenant cannot bypass isolation merely by labelling its own pod as a proxy.

The policy permits agent access only from that proxy and retains TCP/22 for
SSH. Other inbound services and any CNI-specific KubeVirt migration rules need
explicit site rules; this example is deliberately not installed globally.
NetworkPolicies are additive, so another broad ingress allow can defeat it.
Verify proxy access succeeds and an unrelated tenant pod's direct pod-IP and
Service-port access fails. Keep the pod port (8080), not Service port 80, in
the policy. A CNI that does not enforce NetworkPolicy cannot establish this
boundary. Host/root administrators remain outside this tenant isolation model.

Land the API/proxy ownership implementation and isolation configuration first,
then the native selector, then coordinate any image capability advert and
catalog/chart updates. An Image CR advert is capability metadata, not agent
readiness. Updating it does not install an agent into an existing persisted
disk. Pilot a fresh disposable VM first; retain VNC/SSH recovery while testing
an explicit guest upgrade on a snapshot or clone of an existing disk.

Keep guest `defaultPort: 8080`, Service port 80 forwarding, and SSH additional
port 22 coordinated. Chart releases, catalog releases and ArgoCD
`targetRevision` updates remain deliberate operator actions. A component
`:latest` push does not apply chart-side changes.

## Redistribution

The client currently bundles no FFmpeg or Opus libraries. Any future binary
bundle must record exact source versions, build flags, licenses, notices and
corresponding source/relinking obligations. FFmpeg's license depends on its
configuration: the Debian validation build enables GPL components, so it is
not evidence that a redistributable LGPL-only bundle has been prepared.
Opus uses the BSD-style license published with libopus. Dynamic loading alone
does not remove license obligations. Include native libraries in the platform
signing/notarization work when distribution is implemented.

## Rollback

For a diagnostic, close its window/process and reconnect using VNC. A
native-library initialization failure closes the socket and the graphical
client falls back to VNC. Do not uninstall guest display/audio components
or discard its persistent disk to recover the console.

To roll back automatic selection, withdraw the image advert for subsequent
connections, explicitly revoke active Tier 1 owners, and reconnect through the
normal VNC consent flow. Verify capability caches have expired. Removing an
advert does not close an existing socket. Revert primary-port changes only
together with Service and SSH mappings.
