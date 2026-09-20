---
title: Shared display pilot
---

# Shared display (multi-session) pilot and rollback

The shared display lets several participants watch one VM desktop at the same
time: **one controller plus view-only observers**, with explicit control
transfer. It is implemented in the API (`/v1/workspaces/{name}/display*`), the
web UI (`/workspaces/{name}/display`) and the desktop client (**Observe** on a
running VM). The legacy single-session `/v1/workspaces/{name}/vnc` path is
unchanged and remains the default.

**The feature ships opt-in.** Until the acceptance package (live-VM harness,
two-replica proof, pinned Tier 1 agent spike) passes, it is off by default and
must be enabled explicitly per environment.

## Enabling the pilot

Set `KW_DISPLAY_SHARED=on` on the API deployment and restart it:

```sh
kubectl -n kube-workspaces-system set env deployment/kube-workspaces-api KW_DISPLAY_SHARED=on
```

With the gate on:

- `GET /v1/workspaces/{name}/display` advertises `enabled: true` with the
  session limits (protocol 1, up to 8 participants, RFB + Tier 1 transports).
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
  still sees one VNC connection per workspace. Observers may negotiate ZRLE
  (compressed) or fall back to Raw.
- Three Kubernetes Leases per workspace coordinate ownership: the
  **interactive seat** (`kw-display-*`, tier `vnc`/`tier1`) is the cross-tier
  controller mutex, the **capture lease** (`kw-display-capture-*`) coordinates
  the single console connection, and the **control lease**
  (`kw-display-control-*`) gates participant input through a fence.
- A **Tier 1 (Selkies) controller and Tier 0 RFB observers coexist**: while the
  seat is tier1-held, the broker runs observer-only (capture only) and refuses
  controller attaches with 409; when the Tier 1 session ends, the generation
  claims the freed seat and becomes a full shared display.
- With several API replicas, the lease annotations record the owning pod.
  Requests that arrive at the wrong pod are **forwarded internally to the
  owner** (one hop, loop-guarded); if the owner cannot be resolved the client
  gets a 409 naming the owner and retries.

## Limits

- Up to 8 participants per workspace; observer input is discarded server-side.
- A controller's input is fenced to the control lease; a take-over revokes the
  old holder and fences its writes within the existing fencing bound.
- Observer-only coexistence with Tier 1 is proven at the coordination layer;
  **native Tier 1 observers are not offered** (the pinned-agent multi-client
  spike is still open).

## Rollback

```sh
kubectl -n kube-workspaces-system set env deployment/kube-workspaces-api KW_DISPLAY_SHARED-
```

Unset the variable and let the deployment restart. Broker generations end with
the process, capture/control claims are released, new shared joins stop, and
clients reconnect through the legacy exclusive `/vnc` path. No CRD fields,
chart values or ingress changes are involved.

## Acceptance status

Proven: broker protocol interop (native + noVNC clients, late join, resize,
slow-reader isolation), membership/control contracts, capture/control lease
split, cross-replica owner routing (shared coordination object + internal
hop), Tier 1 coexistence at the coordination layer, ZRLE output against real
client decoders. Still open: live two-replica proof, live-VM performance and
encoding validation, the pinned Selkies multi-client spike, and the
browser/native acceptance matrix. See the tracking repo's
`platform-multi-session-plan.md` for the current table.
