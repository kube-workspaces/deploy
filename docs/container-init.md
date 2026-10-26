# Container initialization with cloud-config

Container and scratch workspaces can opt into a supported subset of cloud-init
cloud-config through [container-init](https://github.com/kube-workspaces/container-init).
VM cloud-init continues to use the existing KubeVirt path.

## Enable the installer

Helm configures `ghcr.io/kube-workspaces/container-init:latest` by default;
no application values override is required. Workspaces still explicitly opt into
initialization through their Image defaults or Workspace configuration.
Container-init's Build workflow publishes multi-architecture `:latest` and
`:sha-<full-commit>` images on main pushes; exact release tags additionally
publish `:<version>`. To pin a digest or immutable commit reference, override:

```yaml
# Helm values
controller:
  containerInitImage: ghcr.io/kube-workspaces/container-init@sha256:<published-manifest-digest>
```

For Kustomize, patch the controller Deployment's `KW_CONTAINER_INIT_IMAGE`
environment variable, or supply `--container-init-image=<reference>` when
running the controller directly. Kustomize/direct controller configuration
defaults to empty; an explicitly empty Helm value also disables **injected**
mode. **Baked-in** mode needs no installer image. This image setting is separate
from the controller component image and the user's application image.

Use the updated Image/Workspace CRDs, controller and API together. The catalog
entry is owned by image-catalog and is vendored into deployments through the
normal catalog release/sync workflow.

## Image defaults

```yaml
apiVersion: kubeworkspaces.io/v1alpha1
kind: Image
metadata:
  name: alpine-container-init
spec:
  image: alpine:3.22
  defaultPort: 80
  workspaceTypes: [container, scratch]
  defaultCommand: [sleep]
  defaultArgs: [infinity]
  defaultContainerInit:
    mode: injected
  defaultUserData: |
    #cloud-config
    packages: [curl]
    write_files:
      - path: /etc/container-init-demo.txt
        content: "Initialized in the main container.\n"
        permissions: '0644'
    runcmd:
      - [touch, /run/container-init-demo-ready]
```

The complete catalog example also records `curl --version` output. It is a
terminal-only workspace; required port 80 does not represent a web application.
For catalog-selected scratch images, leave the command override empty to keep
catalog commands/args. Explicit overrides use JSON argv arrays rather than
whitespace-split shell commands.

`defaultContainerInit.mode` is `disabled`, `injected` or `baked-in`:

- Omitted/disabled: ordinary startup; user-data alone has no effect.
- Injected: install the binary and wrap an explicit resolved application argv.
  `defaultCommand` supplies the entrypoint; workspace `container.command` takes
  precedence and removes inherited args unless args were explicitly supplied.
- Baked-in: mount data only. The image's own entrypoint invokes its binary with
  `--user-data /run/container-init/user-data`, then starts its application.

## Resolution and delivery

The API snapshots mode and default user-data onto `Workspace.spec.containerInit`
at creation. Image edits do not retrofit existing workspaces. Inline data is
visible in the Image/Workspace CR; mounting a generated Secret does not make
the original inline data confidential. For private configuration, pass an
independently managed same-namespace Secret instead.

The controller renders each workload from the original Workspace template:

1. Creates/updates a Workspace-owned Secret for inline data, or reads the
   independently managed Secret reference.
2. Mounts its `user-data` key read-only at `/run/container-init/user-data`.
3. In injected mode, appends an installer init container which copies the runner
   into an `emptyDir`, mounted read-only at `/opt/container-init` in the main
   container. Existing init containers and volumes are preserved.
4. Runs `/opt/container-init/container-init --user-data /run/container-init/user-data -- <original argv>`.
5. Launches the application only after initialization succeeds.

This works for StatefulSets (`container`) and Deployments (`scratch`). Injection
does not modify the stored original PodSpec, so reconciles and clones do not
accumulate wrappers. Clones get independently owned generated Secrets. A
generated Secret name collision with an unrelated resource is an error, not
permission to adopt it. Referenced Secrets are never adopted or deleted.
Changing data updates the workload's data checksum and rolls out a new Pod;
editing a referenced Secret is watched as well. Disabling initialization removes
its generated mounts/wrapper and cleans up only its owned generated Secret.

## Direct Workspace CRs

Direct CR creation supplies the resolved configuration explicitly; the controller
does not repeatedly look up Image defaults. A private-data example:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alpine-init-data
  namespace: workspaces
stringData:
  user-data: |
    #cloud-config
    write_files:
      - path: /run/example.txt
        content: "ready\n"
---
apiVersion: kubeworkspaces.io/v1alpha1
kind: Workspace
metadata:
  name: alpine-init-demo
  namespace: workspaces
spec:
  type: container # or scratch
  containerInit:
    mode: injected
    userDataSecretRef:
      name: alpine-init-data
  template:
    spec:
      containers:
        - name: workspace
          image: alpine:3.22
          command: [sleep]
          args: [infinity]
          ports:
            - containerPort: 80
```

Alternatively use `containerInit.userData: |` for an inline snapshot. Enabled
configuration must select exactly one nonempty data source, at most **256 KiB**.
REST creation uses `container_init: {mode, user_data}` or
`container_init: {mode, user_data_secret}`; omitting data retains the Image's
default document, while explicit empty data is rejected. Explicit disabled mode
suppresses inherited data. VM workspaces reject container initialization.

## Execution and verification

Current keys are `bootcmd`, `write_files`, `package_update`, `package_upgrade`,
`packages` and `runcmd`. Selected account/password/SSH/CA/timezone modules are
pending and rejected before provisioning. See container-init's versioned README
for exact supported forms and ordering.

Alpine package provisioning starts as root, without privileged container mode.
No privilege drop is implemented yet: the application retains the invoking
identity unless its explicit entrypoint drops privileges. Non-root images must
use configuration their identity can execute; injection does not override the
application UID or bypass a read-only root filesystem.

Initialization reruns on every main container invocation, including restart or
Pod replacement. A surviving PVC marker cannot stand in for packages installed
into a discarded root layer. Arbitrary commands/append operations need to account
for reruns; failures stop application launch without rolling back prior work.

Verify the catalog demo through its terminal: `curl --version`, the contents of
`/etc/container-init-demo.txt` and `/run/container-init-demo-curl.txt`, the
completion marker, logs and final `sleep infinity` process. Pod Running/Ready
alone is not proof provisioning has finished. Use an application readiness probe
when exposing a real HTTP service; this terminal demo has no HTTP readiness.

## Isolated source-tree proof

With sibling `controller`, `api`, `container-init` and `image-catalog` checkouts:

```sh
python3 scripts/test-container-init.py
```

This opt-in test needs Go, Docker, Kind, kubectl and yq. It builds local
executables/installer, creates a uniquely named Kind cluster with a temporary
kubeconfig, exercises REST/catalog and direct-CR creation, and always removes
the cluster. It checks both workspace types, read-only injected mounts, package/
file results, exec handoff, replacement/stop-start, Secret-reference updates,
baked-in delivery and initialization failure. It does not use the current
kubectl context. Use `--sources` to select the directory holding the sibling
checkouts and `--node-image` to override the default Kind node image.
