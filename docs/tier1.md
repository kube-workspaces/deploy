---
title: Tier 1 transport pilot
---

# Tier 1 transport pilot and rollback

Tier 1 uses the guest's Selkies H.264/Opus WebSocket through the workspace
proxy. The desktop client's normal connection still uses Tier 0 (VNC).
Native decoding and SDL playback are available through the **diagnostic**
`selkies-probe --decode` / `--present` commands in desktop-client source.
Automatic GUI selection and cross-service ownership are not enabled yet.

## Native runtime prerequisites

The diagnostic is built with `CGO_ENABLED=0`. At runtime it loads FFmpeg
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
timestamp-based A/V synchronization or physical-display latency.

## Run a diagnostic pilot

Use a dedicated, unoccupied VM with the pinned Selkies 2.0.0rc0 agent. The
diagnostic changes capture settings and resolution. Its direct/proxy socket
does **not** establish cross-tier ownership. Keep browser and native VNC
viewers disconnected during this experiment.

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

Before enabling automatic selection, require all of the following evidence:

1. A shared cross-replica display owner, with a proxy→API claim made before
   every interactive socket is upgraded. The API's process-local registry is
   insufficient for multiple replicas. `/tier1/claim` currently returns 501
   rather than acknowledging an ownership claim that it cannot enforce.
2. Revocation fences old input before a successor is admitted, including API
   restart, network partition, delayed control messages, stale claims and
   simultaneous VNC/Tier 1 connects. A local callback cannot cross a service
   boundary; closing a control socket alone is not a distributed fencing proof.
3. Guest NetworkPolicy or scoped guest authentication prevents direct pod/Service
   access from bypassing proxy authorization.
4. GUI input, clipboard, resize, bounded reconnect and Tier 0 fallback pass
   together. Access denial and ownership conflict retain their error/consent
   flow instead of falling back around the denial.
5. Linux/macOS/Windows × amd64/arm64 load/decode/playback and missing-library
   fallback checks pass on native runtimes. Cross-builds are separate evidence.
6. Real-display A/V sync, input latency, constrained-network behavior and
   static-text/full-motion quality have accepted results.

## Deployment order and persistent disks

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

For today's diagnostic, close its window/process and reconnect using the normal
VNC client. A native-library initialization failure closes the probe socket;
the normal GUI remains on VNC. Do not uninstall guest display/audio components
or discard its persistent disk to recover the console.

For future automatic selection, withdraw the image advert for subsequent
connections, explicitly revoke active Tier 1 owners, and reconnect through the
normal VNC consent flow. Verify capability caches have expired. Removing an
advert does not close an existing socket. Revert primary-port changes only
together with Service and SSH mappings.
