# VM execution QGA pilot transport

The QGA (QEMU guest agent) pilot transport is an **opt-in backend** for the
synchronous Windows command pilot behind `POST /v1/executions/start`. It drives
a fixed, installed guest runner through the QEMU guest agent of the current
KubeVirt virt-launcher, using Kubernetes-authenticated pod exec as the hop.

It is a pilot. The dedicated mutually-authenticated TLS management transport
remains the follow-up; this backend is **never** a fallback from a failed mTLS
connection. Disabled by default.

## What it does

One bounded SYSTEM command per request:

- Windows only; executable + argument array + optional working directory.
- No interactive stdin, no detached jobs, no shell/PTY.
- Guest deadline at most 20 seconds; combined stdout/stderr capped at 16 KiB
  with explicit truncation reporting.
- The recording (invocation, output, timing, outcome) is committed before
  success is returned. Transport loss is an unknown outcome, never success and
  never an automatic rerun.

Authorization reuses the normal execution permissions (`workspace.exec` plus a
separately granted `workspace.exec.elevated` for SYSTEM), the controller-owned
`PlatformConfig` VM execution policy (`enabled` and `allowElevated`), and the
usual admission/recording infrastructure. See the API documentation for the
request schema.

## Enabling

Three prerequisites, all operator-controlled:

1. **Execution infrastructure** (`execution.enabled: true`, storage mode of
   choice). The pilot records through the same admission path.
2. **A PKCS#8 Ed25519 signing-key Secret** in the release namespace. The API
   signs one short-lived, single-use grant per command with it; the matching
   public key must be staged to each pilot guest (see below). Generate with:

   ```sh
   openssl genpkey -algorithm Ed25519 -outform PEM -o qga-signing.pem
   kubectl -n <namespace> create secret generic qga-grant-signing \
     --from-file=key=qga-signing.pem
   rm qga-signing.pem
   ```

3. **The guest runner**: a `kw-agent` build that provides the
   `management-exec` subcommand, installed in the pilot VM image, plus the
   management-grant key file at
   `C:\ProgramData\workspace-agent\management-grant-keys.json` containing the
   base64url-encoded public key:

   ```json
   { "version": 1, "keys": ["<base64url RawURL 32-byte public key>"] }
   ```

Helm values:

```yaml
execution:
  enabled: true
  qgaPilot:
    enabled: true
    signingKey:
      existingSecret: qga-grant-signing
      key: key
```

Enabling without `execution.enabled` or without the signing-key Secret fails at
template time. There is no inline or generated key material.

## Security model in one paragraph

The grant travels only over pod-exec stdin through a fixed wrapper (never as
pod-exec URL arguments or in logs), is bound to the actor, namespace,
workspace, VM UID, execution/recording IDs, a fresh guest challenge and a
digest of the server-resolved launcher pod, and expires within 60 seconds. The
guest independently verifies the grant and request bounds before creating any
process. The target launcher pod is resolved and re-verified server-side from
Workspace/VM/VMI state — never from client input or pod labels alone.

## Disabling

Set `execution.qgaPilot.enabled: false` (the default). The API then rejects
start requests with a configuration error; there is no fallback path.
