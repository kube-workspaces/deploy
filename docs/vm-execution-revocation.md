# VM execution identity and revocation epochs

The controller owns `Workspace.status.managementExecution`:

```yaml
status:
  managementExecution:
    vmUID: <current-kubevirt-virtualmachine-uid>
    revocationEpoch: 0
```

The VM UID identifies the provisioned root incarnation. Rebooting a VMI does
not change it; reset/recreation does. The nonnegative int64 epoch is monotonic
for the entire Workspace lifetime, including VM recreation. The CRD rejects
epoch decreases and removal of initialized execution status. Only the controller
should have permission to write `workspaces/status`; tenant roles must not.

## Request revocation

Read the current epoch, choose a strictly greater integer, and request it:

```sh
kubectl get workspace example-vm -n example-team \
  -o jsonpath='{.status.managementExecution}'
kubectl patch workspace example-vm -n example-team --type=merge \
  -p '{"spec":{"executionRevocationEpoch":1}}'
```

`spec.executionRevocationEpoch` is a **minimum-epoch request**, never an authority
source. Fresh API reads deny admission as soon as the requested epoch exceeds controller
status, before reconciliation. Invalid stored requests also deny. The controller
acknowledges by raising status; repeating the same value is idempotent. Removing
the field or requesting a lower value is rejected by CRD CEL, including **before
controller acknowledgment**. This prevents cancelling a pending revocation to
re-enable an old identity. Status also retains its monotonic floor independently.
Concurrent requests should use Kubernetes resource-version preconditions; choose
a value higher than both the current status and any outstanding request.

On a ready VM the controller records the current VM UID and epoch before
provisioning management bootstrap. A stopped/not-ready VM may retain a pending
request until it is ready; admission remains denied in the meantime. Revocation
does not start, reboot, reset or replace the root disk.

## What is fenced

- Enrollment authorization and exact-CSR certificate retries require the current
  VM UID and epoch. Previously imported credentials cannot issue/retrieve a leaf
  after their binding is revoked.
- Protected bootstrap Secrets are keyed by Workspace UID, VM UID and nonzero
  epoch (the original name is retained for epoch zero). A new epoch gets fresh
  immutable bootstrap material. Old Secrets/ledger entries cannot enroll at the
  new epoch; their retention/cleanup remains an operator responsibility.
- The QGA pilot resolves controller status, binds the epoch into both the signed
  grant and request, and re-resolves after recording admission before guest
  staging. A changed UID/epoch or pending revocation prevents dispatch.
- The mTLS reference peer-authorizer checks current identity on each handshake.
  Production guest enrollment/listener integration remains a separate work item.

This is **admission and identity revocation**, not an immediate process-kill
facility. A command already dispatched may finish within the pilot's 20-second
deadline. There is no claim of guest-synchronized epoch revocation, cancellation
of existing management connections, or asynchronous job/lease cancellation.
Those require the follow-up authenticated guest transport and job lifecycle.
Revocation is separate from removing a user's execution grants.

## Rollout and recovery

Adopt the updated Workspace CRD and controller before using the API build that
requires this status. Missing/pruned status, stale VM UID, lookup failure and
pending/malformed revocation all fail closed. Deployments with the pilot disabled
remain disabled. Chart publication/adoption is separately coordinated.

Never recover by lowering/deleting the request or status. Repair out-of-schema
state under controlled administration, wait for controller acknowledgment, then
use fresh bootstrap material where enrollment is needed. For an accidental
revocation use the new epoch; old grants
and certificates stay revoked. VM reset is not required merely to raise an epoch.
