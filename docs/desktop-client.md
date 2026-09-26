---
title: Desktop client
---

# Desktop client

The desktop client is a native application for accessing workspaces on a Kube
Workspaces instance — a real remote-desktop client (clipboard, audio on Tier 1,
fullscreen, adaptive quality) rather than a browser tab. Point it at your
instance, sign in, pick a running workspace, connect.

Downloads live on the [releases page](https://github.com/kube-workspaces/desktop-client/releases):
one archive per OS and CPU (**linux / macos / windows** × **amd64 / arm64**).

## What is in the download

| Artifact | Ships in | What it is |
|---|---|---|
| `kube-workspaces` (`kube-workspaces.exe` on Windows) | Every archive | The whole client: graphical shell, session viewer, and all CLI subcommands (`login`, `list`, `connect`, `probe`, `screenshot`, …). |
| `kube-workspaces-web` (`kube-workspaces-web.exe` on Windows) | Every archive **except** windows/arm64 | The per-OS browser engine (WebKitGTK / WebKit / WebView2) as a separate child process. It opens container/scratch workspace web UIs in a native window. Lives beside the shell (inside the `.app` on macOS) so the shell finds it at run time. |
| `Kube Workspaces.app` | macOS archives only | The macOS application bundle wrapping the shell and its web child. Drag it into Applications. |

The single exception is **windows/arm64**: no webview toolchain exists for that
target on the CI runners yet, so that archive ships shell-only. VM sessions work
fully; container workspaces fall back to the system browser instead of the
embedded webview. A shell-only local build (`make build` into `bin/`) behaves
the same way: the `web` subcommand reports the browser engine is unavailable.

Two runtime requirements apply to every archive, and neither is bundled:

- **Tier 1** decoding needs FFmpeg **libavcodec 59 / libavutil 57** (FFmpeg 5.1
  ABI) plus libopus, matching the executable's CPU architecture — `libavcodec.so.59`,
  `libavutil.so.57`, `libopus.so.0` on Linux; `.59.dylib` / `.57.dylib` / `.0.dylib`
  on macOS; `avcodec-59.dll`, `avutil-57.dll`, `opus.dll` or `libopus-0.dll` on
  Windows. Without them the client falls back to Tier 0 instead of failing. See
  [Tier 1](tier1.md) for the full runtime detail.
- On **Linux** the embedded webview needs the **WebKitGTK 4.1** runtime
  (`libwebkit2gtk-4.1`, Ubuntu 23.10+ / Debian 12+). macOS and Windows use
  engines the OS already provides (WebKit, WebView2).

## Installing on Windows

The release offers Windows zips (amd64 + arm64) and an **unsigned** MSI for
install hygiene (Start Menu shortcut, Add/Remove Programs entry, clean
upgrade/uninstall). The MSI is a test distribution: it warns exactly like the
zip until Authenticode signing is funded — see the
[code-signing plan](https://github.com/kube-workspaces/tracking/blob/main/future/code-signing-and-notarisation.md)
in the tracking repo.

Recommended manual location (no installer):

`%LocalAppData%\Programs\Kube Workspaces`
(`C:\Users\<you>\AppData\Local\Programs\Kube Workspaces`)

```powershell
Expand-Archive kube-workspaces-<version>-windows-amd64.zip -DestinationPath "$env:TEMP\kw-install" -Force
New-Item -ItemType Directory -Force "$env:LocalAppData\Programs\Kube Workspaces" | Out-Null
Copy-Item "$env:TEMP\kw-install\kube-workspaces-windows-amd64\*" "$env:LocalAppData\Programs\Kube Workspaces" -Force
Get-ChildItem "$env:LocalAppData\Programs\Kube Workspaces\*.exe" | Unblock-File
& "$env:LocalAppData\Programs\Kube Workspaces\kube-workspaces.exe"
```

Why this path:

- `LocalAppData` (not `RoamingAppData`): binaries are machine-local and must
  not roam with the profile; per-user installs stay writable without UAC, so
  the built-in updater works unelevated.
- Not `Downloads/`: downloaded files carry the Mark-of-the-Web, and the
  folder gets cleaned out by accident. Unblock once after extracting (see
  below) and run from the install dir instead.
- Not `System32` (or any system dir): it is reserved for the OS, needs
  elevation, and breaks the updater.
- `C:\Program Files\Kube Workspaces` is reserved for the future per-machine
  signed installer. A manual copy there works but needs elevation for every
  update (`update: install directory needs elevated permissions`).

Keep the folder together:

- `kube-workspaces.exe` and `kube-workspaces-web.exe` (plus any future
  `avcodec-59.dll`, `avutil-57.dll`, `opus.dll`) must sit **beside each other
  in one folder** — the shell finds its web child by sibling path, and codec
  DLLs load from the app directory only (working directory and `PATH` are
  deliberately excluded from DLL search). Never split the `.exe`s apart, and
  keep the DLL architecture matched to the `.exe` (x64 DLLs for amd64,
  ARM64 DLLs for arm64). Missing or arch-mismatched Tier 1 libraries fall back
  to Tier 0 RFB instead of failing.

First run (unsigned builds):

```powershell
Get-ChildItem "$env:LocalAppData\Programs\Kube Workspaces\*.exe" | Unblock-File
```

SmartScreen still warns with `Unknown publisher` → `More info` →
`Run anyway`. This is expected until signing lands; the MSI warns the same
way, at install time rather than launch time.

Container workspaces need the **WebView2 Runtime** (preinstalled on Windows
11; otherwise install the Evergreen bootstrapper from Microsoft). The
windows/arm64 archive is shell-only (no webview toolchain on CI): VM sessions
work fully there, container web UIs fall back to the system browser.

Moving the install dir is safe: tokens live in Windows Credential Manager and
profiles in `%AppData%\kube-workspaces\` — both location-independent. Close
all client instances before `kube-workspaces update` so locked files can swap;
from a per-user dir the update applies unelevated, from Program Files it
reports that elevation is needed (re-run elevated or reinstall per-user).

Optional conveniences (not created automatically by the zip):

```powershell
# Start Menu shortcut
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut("$env:AppData\Microsoft\Windows\Start Menu\Programs\Kube Workspaces.lnk")
$link.TargetPath = "$env:LocalAppData\Programs\Kube Workspaces\kube-workspaces.exe"
$link.Save()
```

The zip and the manual steps above do not register an Add/Remove Programs
entry; the MSI does. Per-machine MSI installs are an explicit
flag (the MSI is per-user by default even for administrators):
`msiexec /i kube-workspaces-<version>-windows-<arch>.msi ALLUSERS=1 INSTALLDIR="C:\Program Files\Kube Workspaces"`
(elevated).

CI builds are also downloadable from the desktop-client **Build** workflow:
`msi-windows-amd64` and `msi-windows-arm64`. The `SHA256SUMS` artifact covers
both installers and all six platform archives. The ARM64 installer is built
and inspected in CI; native ARM64 installation acceptance remains pending.

The in-app updater replaces binaries from zip releases, so Add/Remove Programs
still reports the last MSI-installed version. MSI repair can restore that
package's binaries. Install a newer MSI when Windows Installer version tracking
is required; uninstall before changing installation scope or architecture.

## Quickstart

Running the binary with no arguments opens the graphical shell:

```bash
./kube-workspaces
```

The shell walks through three screens — instance URL, sign-in, workspace list —
and opens the session in its own window. On the workspace list: `Enter` opens
the selected workspace, `F5` refreshes (it also polls every 5 s), `Ctrl-F`
filters by name, namespace, or type, **New** creates a workspace (name, type,
image), **Profiles** switches between configured instances without relaunching,
and the window reopens at its last size.

The CLI covers the same flow for scripting and diagnostics:

```bash
kube-workspaces login --server https://workspaces.example.com
kube-workspaces list --running
kube-workspaces connect my-vm
```

`login` uses the system browser (OIDC with loopback redirect + PKCE) where the
instance has an identity provider, and prompts for email/password for local
accounts. `connect` opens a display session for one VM workspace
(`--fullscreen`, `--quality`, `--namespace`, and related flags available).

## VM vs container behavior

Opening a **VM** workspace starts a display session in the window — see
[Virtual Machines](vm.md) for what backs it. Opening a **container/scratch**
workspace opens its web UI in the embedded webview child where it ships; the
in-app terminal (Console) and the system browser are the secondary actions.

## Display tiers

Two transports, chosen from the workspace's image — never a user setting:

- **Tier 0 (RFB/VNC)** is the universal floor and fallback: works on any image,
  including pre-boot, BIOS/GRUB, and the login screen. Adaptive quality (Tight
  JPEG tuning with a lossless repaint when idle) is on by default. There is no
  Tier 0 audio playback — the client only detects whether the guest advertises
  a sound device.
- **Tier 1 (in-guest agent)** is the premium path where the image ships the
  pinned Selkies agent: H.264 video plus Opus audio decoded to stereo 48 kHz
  PCM, selected automatically with sticky Tier 0 fallback. Native
  decode/presentation has been validated on Linux amd64; other native platforms
  and physical A/V checks remain pending work — see [Tier 1](tier1.md).

The display is single-session across both transports: if someone else holds it,
the server returns HTTP 409 and the client offers Enter-to-take-over consent.
Several sessions can stay connected at once — closing a session window parks
it in the background (the **Sessions** button in the list footer switches
between them; **Close** there disconnects for good) — but only one window is
visible at a time. A running VM's **Observe** action joins as a
view-only participant instead — see [Shared display](shared-display.md).

## Token storage and security

Session tokens are bearer credentials (24 h lifetime, no refresh) and live in
the OS keychain: Keychain on macOS, Credential Manager on Windows, Secret
Service on Linux. Instance profiles (URL, email, namespace) are ordinary config
in a JSON file under the user config directory.

Headless machines without a Secret Service can opt in to a `0600` token file,
but only explicitly:

```bash
export KUBE_WORKSPACES_INSECURE_TOKEN_FILE=1
```

That file is plaintext with permissions as its only protection — use it on
machines you control and prefer `logout` to leaving a stale file behind. Only
connect to instances served over TLS, and sign out on shared machines. Report
vulnerabilities to security@kubeworkspaces.io.

## Warning: not code-signed

Release binaries for all six platforms are **not code-signed or notarised**.
macOS Gatekeeper will refuse the app on first run and Windows SmartScreen will
warn about unrecognized apps; both require a manual override, explained in each
release's notes.
