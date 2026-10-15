# Shared Display (multi-session)

The shared display lets several participants watch one VM desktop at the same
time: **one controller plus view-only observers**, with explicit control
transfer. It is implemented in the API (`/v1/workspaces/{name}/display*`), the
web UI (`/workspaces/{name}/display`) and the desktop client (**Observe** on a
running VM). The legacy single-session `/v1/workspaces/{name}/vnc` path is
unchanged and remains the default.

**The feature ships opt-in.** It stays off by default and must be enabled
explicitly per environment (see below). The acceptance package behind it has
passed live — see [Acceptance status](#acceptance-status).

## Enabling

Set `KW_DISPLAY_SHARED=on` on the API deployment and restart it:

```sh
kubectl -n kube-workspaces-system set env deployment/kube-workspaces-api KW_DISPLAY_SHARED=on
```

With the gate on:

- `GET /v1/workspaces/{name}/display` advertises `enabled: true` with the
  session limits (protocol 1, up to 8 participants, RFB + Tier 1 transports,
  4096×2160 max framebuffer, 10 s stream-handshake timeout, 15 min idle
  membership TTL).
- The web UI shows the **Shared display** entry in a VM's terminal modal, and
  `/workspaces/{name}/display` joins as a view-only observer with
  Request/Release/Take control.
- The desktop client's **Observe** button joins as an observer; Ctrl+Alt+C
  requests/releases control, Enter confirms a take-over.

With the gate off (the default), the capability advertises `enabled: false`,
join/control calls answer 400, and the stream route answers 404 — clients hide
or explain the entry point accordingly.

## What happens inside

- One **broker generation** per workspace owns a single KubeVirt VNC console
  connection; every participant is served from that one capture, so KubeVirt
  still sees one VNC connection per workspace. The broker serves ZRLE
  (compressed) output against real client decoders, with Raw fallback per
  participant negotiation.
- Four Kubernetes Leases per workspace coordinate ownership: the
  **interactive seat** (`kw-display-*`, tier `vnc`/`tier1`) is the cross-tier
  controller mutex, the **capture lease** (`kw-display-capture-*`) coordinates
  the single console connection, the **control lease**
  (`kw-display-control-*`) gates participant input through a fence, and the
  **membership marker** (`kw-display-membership-*`) coordinates the session
  across API replicas.
- A **Tier 1 controller and Tier 0 RFB observers coexist**: while the
  seat is tier1-held, the broker runs observer-only (capture only) and refuses
  controller attaches with 409; when the Tier 1 session ends, the generation
  claims the freed seat and becomes a full shared display. See
  [Display tiers & audio](display-tiers.md) for the tier model.
- With several API replicas, the lease annotations record the owning pod.
  Requests that arrive at the wrong pod are **forwarded internally to the
  owner** (one hop, loop-guarded); if the owner cannot be resolved the client
  gets a 409 naming the owner and retries.

## Limits

- Up to 8 participants per workspace (controller + observers); a 9th join is
  refused with 429. Observer input is rejected server-side — view-only is
  enforced by the broker, not by client cooperation.
- A controller's input is fenced to the control lease; a take-over revokes the
  old holder and fences its writes within the existing fencing bound.
- Observer-only coexistence with Tier 1 is proven at the coordination layer;
  **native Tier 1 observers are not offered** (the pinned-agent multi-client
  gate did not pass: the agent stays single-primary).

## Rollback

```sh
kubectl -n kube-workspaces-system set env deployment/kube-workspaces-api KW_DISPLAY_SHARED-
```

Unset the variable and let the deployment restart. Broker generations end with
the process, capture/control claims are released, new shared joins stop, and
clients reconnect through the legacy exclusive `/vnc` path. No CRD fields,
chart values or ingress changes are involved. Rollback was rehearsed live.

## Acceptance status

Proven live (2026-09-22/23): broker protocol interop (native + noVNC
clients, late join, resize, slow-reader isolation), membership/control
contracts including REST transfer/release and cross-pod dual-controller 409,
capture/control lease split, cross-replica owner routing (two-pod proof:
non-owner loss transparent, owner loss recovers after fencing), Tier 1
coexistence at the coordination layer, ZRLE output at 100% with 5 stable
observers (first frame ~100–150 ms), a 60 s reconnect storm at capacity
without dropping the controller or growing memory, audio transport against
real QEMU, cursor visibility, browser click-through, and the rollback
rehearsal. See the tracking repo's
`_completed/platform-multi-session-plan.md` for the full table.

Open follow-ups, not gates: sounding-guest audio end-to-end plus any
playback (no PCM flowed from the silent proof guest), and heavier churn
rates if ever needed. Deferred client checks ride with the real-display
validation plan.

## See also

- [Display tiers & audio](display-tiers.md) — Tier 0 vs Tier 1, per-tier audio,
  and which client plays what
- [Virtual Machines](vm.md) — the legacy exclusive `/vnc` bridge
