# Arch Linux GNOME cloud-image workspace

## Delivery status

The image-catalog recipe is `images/arch-linux-gnome-vm.yaml`. It pins released
workspace-agent **v0.5.0**, including the GNOME backend and startup installer,
with an archive SHA256. Controller/API support and guest/browser/native media
acceptance are implemented. Adoption through a catalog/chart release remains
operator-coordinated; this entry may not yet be included in your deployed chart.
Older workspace-agent v0.4.0 does **not** contain the GNOME backend.

## No custom OS image build

This recipe imports an official, versioned Arch Linux x86-64 cloud QCOW2 using
CDI HTTP. Each workspace gets its own persistent root disk. Cloud-init installs
GNOME, GDM, QEMU guest agent, the media dependencies and a checksum-verified
workspace-agent archive on first boot. No containerDisk build or registry
publication is required.

The controller and API must both support HTTP root references. The catalog
entry must declare exactly `workspaceTypes: [vm]` and
`persistentRootDisk: true`; put the absolute HTTP(S) URL in `spec.image`.
Do not reuse that reference in a second Image CR: catalog defaults are resolved
by the reference, rather than by the Image's name. OCI references continue to
use the existing registry import path.

Prerequisites:

- KubeVirt and CDI, with a working default StorageClass and enough room for a
  30 GiB persistent root disk.
- An amd64 worker with KVM (or explicitly configured emulation).
- Importer access to the upstream cloud-image URL, and guest Internet/DNS access
  to Arch mirrors and the pinned agent archive.
- At least 4 GiB guest memory plus QEMU overhead. Under the VM catalog mapping,
  `memoryLimit: 4Gi` sets guest RAM and `memoryRequest: 5Gi` allocates the
  launcher pod's memory request and limit. Software H.264 also needs CPU capacity.

The upstream QCOW2 is versioned and its published SHA256 is recorded in the
recipe. The current CDI HTTP source carries the URL, not a checksum field;
it does not independently enforce that upstream digest. The agent archive is
explicitly verified with `sha256sum --check --strict` before installation.

## First boot and recovery

The cloud base does not contain GNOME. Initial import, full package upgrade and
desktop installation can take several minutes. Arch requires a full upgrade
before adding packages; keep the recipe's package upgrade enabled. A reboot
finishes provisioning. Kubernetes readiness means the VM is running, not that
package installation or the premium agent has finished.

The provisioned account is `arch`, with the catalog's declared demonstration
password `arch` and passwordless sudo. Supply your own cloud-init credentials
and SSH keys when using this recipe beyond disposable evaluation. The password
is configured by this recipe, not an upstream cloud-image default.

The recovery paths are independent of the premium agent:

```sh
virtctl console -n example-team arch-desktop
virtctl vnc -n example-team arch-desktop
virtctl ssh -n example-team --username arch vm/arch-desktop
```

Inside the guest:

```sh
cloud-init status --long
sudo journalctl -u cloud-final.service -b
systemctl status gdm qemu-guest-agent
systemctl --user status workspace-agent.service
journalctl --user -u workspace-agent.service -b
```

The official image's systemd-networkd/resolved networking is retained. Installing
GNOME does not enable a competing NetworkManager service.

## GNOME premium desktop

The agent runs as the ordinary console user, started by an XDG autostart entry
that imports the actual Wayland/session environment into a systemd **user**
service. GNOME 51 skips entries declaring the obsolete
`X-GNOME-Autostart-Phase`; the shipped entry must omit it. Do not replace the
worker with a root capture daemon or a lingering SSH session.

The backend uses Mutter RemoteDesktop/ScreenCast and PipeWire, GStreamer x264
software H.264 encoding, and Pulse/PipeWire loopback audio. Input, Unicode
clipboard and guest mode changes use the same GNOME session. Capture/input
reject an inactive or locked console. The first-login welcome dialog is
preseeded away; ordinary screen locking is retained.

The recipe forces the virtio `Virtual-1` head connected through a kernel
command-line setting, so closing a VNC recovery viewer cannot remove the
premium capture monitor. A GNOME `monitors.xml` seeds 1280×800 instead of
letting the forced head select its largest EDID mode. These settings target the
catalog's QEMU virtio display; other display hardware needs its own configuration.

The controller injects a public Workspace UID/root-generation binding into
NoCloud. The API must issue tickets for that same Linux `agent-generation`.
An older API that only reads the Windows generation produces
`workspace-generation-mismatch`; reconnecting cannot repair that version
mismatch. The public binding is not an enrollment credential or signing key.

## Operator acceptance before publication

Use a disposable namespace and verify:

1. CDI imports the official URL; the root grows to its requested size.
2. Cloud-init completes without errors after reboot; DNS, package upgrade,
   GNOME Wayland login, SSH and QEMU guest agent work.
3. The agent starts automatically at graphical login. Browser and desktop
   clients decode video/audio through the authenticated proxy, deliver input,
   exchange Unicode clipboard text and apply a real guest resize.
4. Switching between VNC and premium keeps a usable monitor. Reconnect after
   an idle interval and after a cold stop/start.
5. A user-file marker and the generation binding survive stop/start. Clone
   creates an independent root and distinct Workspace identity. Reset replaces
   only the selected root, reprovisions it and rotates its agent generation;
   previous-generation tickets are refused.

First-boot defaults only apply to new/reset roots. Updating an Image CR does not
retrofit already-provisioned persistent guests. Agent publication, catalog
release and chart adoption are separate coordinated delivery steps.

The recipe writes `manual_cache_clean: true` to cloud-init's system
configuration. A KubeVirt stop/start can change the VMI's NoCloud identity;
trusting this root's existing cache prevents rerunning its package installation,
SSH host-key generation and first-boot reboot. Reset and clone import a fresh
root with an empty cache. Do not copy such a provisioned root as a reusable
golden image without cleaning its cloud-init state and identity first.
