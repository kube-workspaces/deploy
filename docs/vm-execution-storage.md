# VM execution storage

Agent-backed VM commands/shells use full protected session recording and metadata
audit. **Persistence is optional**: choose ephemeral history, externally managed
PostgreSQL/S3, or bundled PostgreSQL/RustFS. Ordinary execution and elevation have
separate permissions; selecting a storage mode does not grant either permission.

**Implementation status:** deployment/configuration, database migrations,
encrypted recording stores, protected playback and admission foundations are
implemented. Bounded root/SYSTEM commands/scripts are available through the
separately enabled QGA pilot; dedicated enrollment/mTLS, general operation
lifecycle and interactive shells remain separate work. Provisioned services or accepted
configuration do not establish execution readiness. These examples do not enable
`PlatformConfig.spec.vmExecution` or expose a guest shell by themselves.

## Modes

| Mode | Selection | History and dependencies |
|---|---|---|
| Disabled | Default `execution.enabled: false` | No execution configuration or storage services. |
| Ephemeral | `execution.enabled: true`, neither persistent selector enabled | No PostgreSQL/S3/PVC. Bounded encrypted temporary recording and process-local metadata; history may disappear on restart/replacement. |
| External | `execution.storage.external.enabled: true` | Operator-managed PostgreSQL and S3-compatible store. No bundled storage installed. |
| Bundled | `execution.storage.bundled.enabled: true` | PostgreSQL and RustFS subcharts with persistent volumes, internal Services and storage ingress NetworkPolicies. |

The external/bundled selectors are mutually exclusive. The same bundled selector
controls both Helm dependencies, avoiding partially installed hybrid storage.
Execution infrastructure requires authentication. Persistent failures must not
fall back to ephemeral mode. Ephemeral mode currently requires one API replica
and Recreate updates; persistent modes provide the foundation for distributed
coordination. Losing temporary storage must terminate/fence its executions, not
resume or rerun commands automatically.

The hybrid contract stores execution state, searchable audit/index metadata and
coordination in PostgreSQL; encrypted recording chunks/manifests go to S3. Session
metadata and client capability discovery must identify the selected durability.
Ephemeral mode still records full input/output and enforces resource bounds; it
does not promise retained or independently durable evidence.

## Ephemeral profile

```sh
helm template kw helm/kube-workspaces -n kube-workspaces-system \
  -f examples/execution-storage/ephemeral.yaml
```

The API gets a bounded `emptyDir` and a 512 MiB application recording budget by
default, with no persistent storage or persistent encryption key dependency.
The runtime generates an ephemeral key; discarded keys/history are unrecoverable.
Container restarts may leave ciphertext in `emptyDir`, but cannot be treated as
recoverable history with a new key. Resource exhaustion must fence admission/
input rather than silently stop recording. `emptyDir`/node lifecycle can remove
data earlier than configured retention.

## External PostgreSQL + S3

Use `examples/execution-storage/external.yaml`. Pre-create its database, bucket,
credentials and recording-key Secrets in the release namespace. References:

| Secret | Keys / contract |
|---|---|
| `execution-postgresql` | `database-url`: PostgreSQL URL using a dedicated app role/database and `sslmode=verify-full`. |
| `execution-s3` | `access-key`, `secret-key`: credentials restricted to the execution bucket/prefix. |
| `execution-recording-key` | `key`: base64 text encoding a random 32-byte recording key, or the API's versioned active/read-only keyring JSON. |

Set `execution.storage.s3.endpoint`, bucket and region for the provider. Custom
Secret key names and path-style requests are configurable. For a private S3 CA,
set `execution.storage.s3.caSecret` (key `ca.crt`); certificate validation remains
enabled. The mounted CA path can also be referenced by a PostgreSQL URL
`sslrootcert` parameter if both services use that CA. PostgreSQL client-certificate
mounts and workload-identity credentials are not yet provided by this profile.

External mode does not create buckets by default or manage credentials, database
backups or object-store retention policies. Operators manage those services and
permissions. SeaweedFS, RustFS, AWS S3 and other compatible providers use the same
S3 interface; no provider-specific APIs belong in the guest/client protocol.

## Bundled test profile

`examples/execution-storage/bundled.yaml` installs:

- **CloudPirates PostgreSQL chart 0.21.2**, using the upstream PostgreSQL image.
  A separate non-superuser application role/database is initialized once. The
  API receives app credentials, not the database administrator password.
- **Upstream RustFS chart 1.0.2**, standalone, with a 20 GiB data PVC and no public
  ingress or console enabled. The S3 endpoint is discovered from the subchart
  Service name, including fullname overrides.

Dependencies are pinned in `Chart.yaml`/`Chart.lock` and vendored for offline
rendering. RustFS is the initial bundled provider; managed SeaweedFS remains an
external S3 option. Bundled does not imply high availability or backups.

Create Secrets once, outside Helm values/Git. For example (generic installation
namespace; these are operator commands, not install hooks):

```sh
kubectl -n kube-workspaces-system create secret generic execution-postgresql-admin \
  --from-literal=postgres-password="$(openssl rand -hex 32)"
kubectl -n kube-workspaces-system create secret generic execution-postgresql-app \
  --from-literal=CUSTOM_USER=execution --from-literal=CUSTOM_DB=execution \
  --from-literal=CUSTOM_PASSWORD="$(openssl rand -hex 32)"
kubectl -n kube-workspaces-system create secret generic execution-rustfs \
  --from-literal=RUSTFS_ACCESS_KEY="$(openssl rand -hex 16)" \
  --from-literal=RUSTFS_SECRET_KEY="$(openssl rand -hex 32)"
kubectl -n kube-workspaces-system create secret generic execution-recording-key \
  --from-file=key=/secure/operator-owned/recording-key
```

Then render/review the bundled profile before the separately coordinated chart
adoption. Existing authentication/IdP or local-account configuration still needs
to be supplied in the installation's other values files.

```sh
helm template kw helm/kube-workspaces -n kube-workspaces-system \
  -f examples/execution-storage/bundled.yaml
```

The recording-key file above is a separately generated, access-restricted file,
not a literal placeholder key or a Helm value. Preserve it under operator key
custody. The chart never generates it or exposes its content in rendered manifests.

The test profile explicitly opts into internal PostgreSQL/TCP and S3/HTTP via
`execution.storage.allowInsecureTransport: true`. Recording content must be
application-encrypted before it reaches those stores; this flag does not disable
TLS certificate validation on HTTPS endpoints. NetworkPolicies allow API ingress
to storage (and S3 peer traffic) only within the release namespace; the CNI must
enforce NetworkPolicy. For verified transport encryption use external endpoints;
the baseline bundled profile does not configure PostgreSQL server TLS.

Adjust `postgresql.persistence.storageClass`/size and
`rustfs.storageclass.name`/dataStorageSize to the cluster's StorageClasses. Empty
class names use cluster defaults. PVCs are not backups: PostgreSQL claim-template
volumes are retained by StatefulSet defaults and the RustFS standalone PVC has
the upstream `helm.sh/resource-policy: keep` annotation. Namespace/PVC deletion,
storage failure or reclaim policies can still destroy data. Keep credentials
and the recording key with the retained data. Changing a Secret is not database
password rotation; initialization runs only on a new database volume.

For multiple releases, use distinct Secret names and bucket/prefixes. Switching
modes/providers or replacing volumes does not migrate history. Drain active
executions, copy/verify metadata and objects together, retain the corresponding
keys, and only then change storage references. Do not reuse a data volume across
incompatible database major versions or silently reinitialize missing history.

## Retention, keys and readiness

Initial configurable durations are 720 hours of recording and 8760 hours of
metadata. **They do not enable deletion and are not an approved permanent policy.**
Metadata retention must cover recording retention so replay/index and deletion
evidence are not removed before their recording objects. Full input
recording includes echo-disabled credentials: replay is a separate permission and
must itself be audited. Content never belongs in ordinary application/debug logs.

Retained data must remain decryptable across API restarts; a persistent recording
key is mandatory. The API accepts the original single key or a bounded versioned
keyring with one active writer key and up to eight read-only keys; the existing
Secret mount carries either format. Stage new read keys across every API replica
before changing the writer key, and retain old keys for evidence/recovery/backup
and rollback requirements. See [API recording-key rotation](https://github.com/kube-workspaces/api/blob/main/internal/execution/storage/KEY_ROTATION.md).
Back up keys separately with controlled
access; neither PostgreSQL/S3 availability nor a chart install alone establishes
recording health. Admission must verify both stores, the encryption key, write
authorization and available recording capacity before any process starts.

### Explicit retention workers

Both workers are **off by default** in Helm and Kustomize. These Helm values are
independent of storage durations and do not enable workspace execution policy:

| `execution.storage.retention` field | Default | Meaning |
|---|---|---|
| `recordingsEnabled` | `false` | Render `KW_EXECUTION_RETENTION_ENABLED`; delete eligible terminal command/script recordings. Requires persistent storage. |
| `metadataEnabled` | `false` | Render `KW_EXECUTION_METADATA_RETENTION_ENABLED`; additionally expire eligible execution/audit metadata after recording cleanup. Requires recordings enabled. |
| `policyAcknowledged` | `false` | Required before either worker can be armed, after reviewing durations, custody and rollout prerequisites. This acknowledgement alone enables nothing. |
| `recordings` | `720h` | Recording age cutoff, subject to explicit operator policy. |
| `metadata` | `8760h` | Minimum metadata/audit age; must cover recording duration. Every recent audit event prolongs protection. |

With enforcement enabled, chart durations must be positive **whole-hour strings**
from `1h` through `2562047h` (the whole-hour Go duration limit). This restricted
chart policy format allows overflow-safe render-time comparison. Duration-only
legacy configurations are unchanged while both workers are off; custom API
deployments still accept the runtime's broader Go duration format.

For an already reviewed persistent profile, the optional
`examples/execution-storage/retention.yaml` demonstrates both switches and
**illustrative**, not recommended/pre-approved, `24h`/`168h` values. Render only:

```sh
helm template kw helm/kube-workspaces -n kube-workspaces-system \
  -f examples/execution-storage/external.yaml \
  -f examples/execution-storage/retention.yaml
```

Substitute the bundled profile if desired. Do not include the destructive overlay
in an installation until operator approval and coordinated chart adoption. The
chart rejects disabled/ephemeral storage, metadata-only enforcement, unacknowledged
policy, non-boolean switches, invalid/overflowing hours and metadata shorter than
recordings. API startup independently validates persistent mode and durations.
Kustomize's base explicitly sets both runtime switches to `"false"`; an operator's
persistent-storage overlay must deliberately replace selected switches and supply
reviewed durations and all existing storage/authentication prerequisites.

Before enabling, upgrade every reader replica to retention-aware API binaries
(including metadata schema 000008), use an **unversioned** recording bucket and
grant narrowly scoped bucket versioning-read/list/delete permissions in addition
to normal recording access. Object-store policy is never changed by the worker.
Chart field availability is versioned separately: adopt a chart release containing
these fields; changing a values file alone does not update a pinned older chart.

Recording expiry commits a shared replay fence/audit before bounded deletion;
failed/partial cleanup remains fenced and resumable, including after a longer
later duration. Metadata expiry waits for completed recording cleanup and **all**
audit events' retention windows, then atomically deletes original history and
writes a minimal lifetime ID/deletion receipt. Original actor/scope/invocation/
result payloads are not copied to that receipt. Old IDs remain reserved; neither
expiry path reruns a guest command or reinterprets unknown as success. Active/
pending recovery, shell/upgrade and referenced upgrade evidence remain protected.
Ephemeral/orphan cleanup and deletion of backups/external copies are not included.

Rendering/tests are not deployed storage/rotation/retention acceptance. Review
irreversibility, minimal-ledger capacity, rollback and staging proof in the full
[API retention contract](https://github.com/kube-workspaces/api/blob/main/internal/execution/storage/RETENTION.md).

## Opt-in management issuer

The API now supports optional dedicated CA loading, shared enrollment-ledger
initialization and a protected-bootstrap import worker. The existing authenticated
`GET /v1/executions/status` reports `issuer_ready` separately from recording-store
availability. That bit does not advertise a guest execution capability or a public
enrollment endpoint.

The runtime opts in through `KW_MANAGEMENT_ISSUER_ENABLED` and requires mounted
CA certificate/chain, PKCS#8 private-key and explicit trust-root files, plus
`KW_MANAGEMENT_BOOTSTRAP_NAMESPACE` matching the controller's protected namespace.
CA signing private keys are not generated automatically or placed in images/Helm values.
Credential/Secret mounts and runtime environment adoption remain separately
coordinated; the storage profiles above do not enable the issuer.

The current issuer requires `external` or `bundled` execution storage with the
shared PostgreSQL enrollment ledger. It rejects ephemeral/process-local issuance
state: after restart, a forgotten redeemed token could otherwise enroll a second
CSR. Ephemeral recording remains a storage option, but full guest execution in
that mode still needs a replica-safe alternative enrollment ledger and the other
guest prerequisites.

The worker watches only protected-namespace management bootstrap metadata and
re-reads credentials before trusted import. It preserves committed CSR/certificate
results across re-import, denies token rebinding/expiry extension, and withholds
issuance when current identity, policy, authentication, CA trust/lifetime,
recording or ledger prerequisites fail. Trust/key rotation is coordinated with
process restart and old/new root overlap; it is not silent hot reload.

Detailed runtime configuration and lifecycle contracts:
[API management issuer](https://github.com/kube-workspaces/api/blob/main/internal/execution/management/README.md).
Protected guest key/token delivery and authenticated enrollment transport are
still required before a reachable machine listener or runner is enabled.
