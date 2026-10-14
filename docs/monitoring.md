---
title: Admin monitoring
---

# Admin monitoring

**Admin → Monitoring** shows live workspace/VM connections, client-facing
traffic, platform replica readiness, and optional Prometheus platform/tier
history. Live inventory works independently of Prometheus.

## What is measured

- Tier 0 RFB and shared RFB viewers terminate at the API.
- Tier 1 Selkies and workspace-agent bridges terminate at the workspace proxy.
- Container terminals, VM serial consoles, SSH, and TCP forwards terminate at
  the API and are separate from display tiers.
- Workspace application WebSockets and SSE requests are application streams.
  SSE is identified by the standard `Accept: text/event-stream` request and a
  successful event-stream response. Other HTTP requests are shown as in-flight
  requests, not persistent workspace sessions.

An **established connection** means bridge setup has completed, not that the
user has logged into the guest or that display frames are being presented.
Agent guest admission and media observation are reported separately; a
control-only/clipboard-helper connection is not assumed to be an interactive
display controller. Its purpose is shown as unclassified until a future
explicit purpose contract is available.

Running workspaces and connected workspaces are different counts. Three
viewers of one VM count as three client connections and one connected
workspace. Shared-display membership, ownership claims, and minted agent
tickets are not connection counts. API owner-forwarding hops do not create
another counted client connection. Direct guest connections that bypass the
platform bridges are not part of this inventory.

Directions:

- **Toward workspaces:** client → workspace.
- **Toward clients:** workspace → client.

HTTP counters measure consumed request bodies and actual downstream response
body writes, after HTML rewriting. Upgraded counters measure client-facing
WebSocket stream bytes, including framing and control frames, after bridge
establishment. They exclude upgrade handshakes, TLS/TCP/IP overhead and
retransmissions. Last traffic includes protocol control/keepalive traffic;
it is not a user-input/idle-time indicator. A quiet established connection
remains connected.

Actual workspace/interface network packets and bytes come from existing
cluster telemetry through the history API, not from the live bridge
endpoint. They are not synthesized from WebSocket messages or agent frames.
Whole-VM network traffic must not be added to proxy traffic totals, and
virt-launcher pod traffic appears under both container and VMI families.

## Enable private replica reporting

API and proxy expose a **separate private listener on port 9090**, only when
`KW_MONITORING_TOKEN` is configured. Its routes are:

```text
GET /snapshot
GET /metrics
Authorization: Bearer <shared monitoring token>
```

Both routes require the token even if platform login authentication is
disabled. The main API/proxy application Services and ingress do not expose
this port. Separate ClusterIP monitoring Services are provided. Keep port
9090 internal and allow API → API/proxy and Prometheus → API/proxy access if
the cluster enforces NetworkPolicies.

Create one shared Secret with a random `token` key before starting the updated
API/proxy pods. For the default release/base names:

```sh
kubectl -n kube-workspaces-system create secret generic kube-workspaces-monitoring \
  --from-literal=token="$(openssl rand -hex 32)"
```

Helm uses `<fullname>-monitoring` by default; set `monitoring.existingSecret`
to use another name. Kustomize base uses `kube-workspaces-monitoring`. The
Secret is operator-managed; templates never generate a random token during
GitOps rendering. Secret references are optional so existing deployments
remain startable before configuration; the page explicitly reports missing
proxy/remote-replica telemetry as partial coverage.

If the Secret is created or rotated after pods start, restart both components
to reload the environment:

```sh
kubectl -n kube-workspaces-system rollout restart \
  deployment/kube-workspaces-api deployment/kube-workspaces-proxy
```

Use the actual deployment names for custom Helm releases.

## Replica discovery and freshness

Each API replica runs a background collector every five seconds. It lists
workspaces once, discovers platform pods in its own namespace, and collects
authenticated per-pod reports with a four-second collection budget,
two-second request deadlines, and at most eight concurrent requests. Browser
polling reads this shared cache rather than triggering another fan-out.

- `POD_NAMESPACE`: platform namespace (default `kube-workspaces-system`).
- `KW_MONITORING_SELECTOR`: platform pod selector (default
  `app.kubernetes.io/name=kube-workspaces`). Helm pins its release instance.
- `KW_MONITORING_PLATFORM`: common API/proxy metric identity. Helm uses
  `<namespace>/<release>`; Kustomize uses
  `kube-workspaces-system/kube-workspaces`.

Snapshots have process boot IDs. Rates use successive counters from the same
process, so restarts cannot appear as traffic spikes. Recently finished
transfers contribute to rates even after their connections leave the live
inventory. Per-workspace transient traffic counters are retained for ten
minutes after activity when no connection remains; aggregate Prometheus
counters survive disconnect until process restart.

Missing/unreachable/old-version replicas produce **partial coverage**, not
zero activity. Failed replica reports do not retain stale active connections.
The UI marks old snapshots as stale and withholds current summary counts and
rates after a fetch failure or stale collection. Quiet connections remain
visible. Live polling pauses while the tab is hidden and backs off on errors.

## Prometheus history

Reuse an existing Prometheus installation. This chart does not install a
second monitoring stack, Grafana, or change cluster retention. Suggested
starting configuration is a 15-second scrape interval and 14-day retention,
subject to existing capacity.

Helm example:

```yaml
monitoring:
  existingSecret: kube-workspaces-monitoring
  prometheusURL: http://prometheus.monitoring.svc.cluster.local:9090
  # Optional Secret with a `token` key for the Prometheus query API:
  prometheusAuthSecret: ""
  serviceMonitor:
    enabled: true
    interval: 15s
    labels:
      release: monitoring # match the installed Prometheus selector
```

The optional ServiceMonitor requires Prometheus Operator CRDs and selects the
two monitoring Services. It scrapes **each pod endpoint**, not a single
load-balanced Service address, and uses the shared Secret as Bearer
authentication. Ensure the installed Prometheus namespace/ServiceMonitor
selectors include this namespace and these labels.

Kustomize operators can create an equivalent ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kube-workspaces-connections
  namespace: kube-workspaces-system
  # Add labels required by your Prometheus ServiceMonitor selector.
spec:
  namespaceSelector:
    matchNames: [kube-workspaces-system]
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-workspaces
      kubeworkspaces.io/monitoring: "true"
  endpoints:
    - port: monitoring
      path: /metrics
      interval: 15s
      authorization:
        type: Bearer
        credentials:
          name: kube-workspaces-monitoring
          key: token
```

Configure `KW_PROMETHEUS_URL` on the API deployment through a Kustomize patch;
optionally configure `KW_PROMETHEUS_TOKEN` from a separate query-auth Secret.
The query URL is operator-controlled, never supplied by the browser.

The page offers 15-minute, one-hour and 24-hour connection and bidirectional
traffic charts broken down by category/tier/transport. Queries are scoped to
`KW_MONITORING_PLATFORM`. No raw PromQL or arbitrary upstream URL is accepted
from clients. Missing history or a Prometheus failure does not disable live
monitoring. Gauge history is sampled: a short session may fall between
scrapes. Cumulative traffic counters preserve its transferred bytes.

Current exported metrics:

| Name | Type | Meaning |
|---|---|---|
| `kubeworkspaces_connections_active` | Gauge | Established owner-local streams/HTTP requests; exclude `category="http"` for session counts |
| `kubeworkspaces_connection_attempts_total` | Counter | Bridge/request attempts, excluding owner-forwarding hops |
| `kubeworkspaces_connections_established_total` | Counter | Completed setup transitions |
| `kubeworkspaces_connections_closed_total` | Counter | Ended established connections/requests |
| `kubeworkspaces_connection_setup_failures_total` | Counter | Attempts ending before establishment |
| `kubeworkspaces_traffic_bytes_total` | Counter | Traffic at the documented byte layer and direction |

Bounded metric labels are `kw_platform`, `category`, `transport`, `tier`, and
`byte_layer`; traffic also has `direction`. Workspace IDs, connection IDs,
users, full URLs, payloads, clipboard contents and credentials are not metric
labels. The live inventory supplies workspace/user detail only to admins.

The existing controller `kubeworkspaces_workspaces_total` gauge now derives
actual namespace/status totals from its cache at scrape time rather than
setting a namespace/status series to one during reconciliation. Controller
metrics still use the controller's existing endpoint/authentication setup;
the new API/proxy ServiceMonitor does not assume it matches those settings.

## Admin API

These handwritten admin routes follow the existing admin endpoint convention:

```text
GET /admin/monitoring/overview
GET /admin/monitoring/series?metric=connections&range=1h
GET /admin/monitoring/series?metric=toward_workspace&range=1h
GET /admin/monitoring/series?metric=toward_client&range=1h
GET /admin/monitoring/series?metric=network_container_bytes&range=1h
GET /admin/monitoring/series?metric=network_container_packets&range=1h
GET /admin/monitoring/series?metric=network_vmi_bytes&range=1h
GET /admin/monitoring/series?metric=network_vmi_packets&range=1h
```

Only these fixed metric keys are accepted; the browser cannot submit PromQL
or an upstream URL.

They require admin authorization through the existing API middleware and
return `Cache-Control: no-store`. With platform auth disabled, the existing
platform convention treats access as admin. In the frontend they are reached
through `API_BASE`, normally `/api/admin/monitoring/...`, with included cookie
credentials.

The overview includes `observed_at`, `complete`, `rates_ready`, `workspaces`
(each containing live connections and rates), per-replica `sources`, collection
`messages`, platform `components`, `setup_failures` since reporting processes
started, and `history_configured`. It is a full cached inventory; filters in
the first milestone are client-side. Separate paginated detail endpoints are
a future scale extension.

## Workspace/interface network history

Four fixed history queries expose cluster interface counters alongside the
platform proxy series:

| Metric key | Source family | Meaning |
|---|---|---|
| `network_container_bytes` | `container_network_receive/transmit_bytes_total` (kubelet/cAdvisor) | Cluster pod bytes, receive = toward workspaces, transmit = toward clients |
| `network_container_packets` | `container_network_receive/transmit_packets_total` | Cluster pod packets, same direction mapping |
| `network_vmi_bytes` | `kubevirt_vmi_network_receive/transmit_bytes_total` (KubeVirt `kubevirt-prometheus-metrics` Service) | VMI bytes by guest interface, same direction mapping |
| `network_vmi_packets` | `kubevirt_vmi_network_receive/transmit_packets_total` | VMI packets, same direction mapping |

Prerequisites: Prometheus must already scrape the kubelet/cAdvisor targets
for container series and the KubeVirt metrics Service for VMI series. This
chart only queries them; it does not install scrape jobs for those
components. If either family is absent, its charts return empty results while
live monitoring and proxy history keep working.

These are cluster-level sums in this milestone, not per-workspace
attribution and not platform-scoped by `KW_MONITORING_PLATFORM` (neither
family carries that label). Per-workspace/interface breakdowns remain future
work subject to a cardinality budget. Validate attribution live by running
traffic in one workspace and confirming the expected direction moves while
proxy stream bytes and interface bytes stay in separate charts.

## Operational acceptance

After deploying the updated API, proxy, frontend, controller and chart/base:

1. Confirm both private scrape targets and every API/proxy replica report.
2. Open Tier 0 RFB, shared observers, Tier 1 Selkies/agent, serial/SSH/TCP,
   container terminal, and application HTTP/WebSocket/SSE paths in turn.
3. Check connected counts, transport/tier and direction; disconnect/take over
   and confirm the old record disappears without affecting its replacement.
4. Check three shared viewers count as three connections and one workspace,
   without an extra count for capture/owner-forwarding.
5. Restart a replica and confirm its old connections are not retained and
   rates do not spike. Make a report unavailable and confirm partial coverage.
6. Confirm history appears after sufficient scrapes and remains independently
   unavailable if Prometheus is disabled/unreachable.
7. Open each network history metric and confirm container and VMI series move
   in the expected direction during workspace traffic, stay separate from
   proxy stream-byte charts, and report empty (not failed live monitoring)
   when the underlying target is unscraped.

Live collection does not change existing ownership guarantees. API serial/SSH/
TCP registries and agent grants remain process-local; agent renew/release on a
different API replica can still fail correlation. The proxy now correctly
validates renew responses, releases grants after failed upgrades, and tears
down on renew failure. Distributed agent grant/ownership coordination and
explicit helper/display purpose are follow-up lifecycle work. The Monitoring
page measures the actual bridges, not those grant/status endpoints.
