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

Two runtime considerations apply depending on your platform and build:

- **Tier 1** decoding needs FFmpeg **libavcodec 59 / libavutil 57** (FFmpeg 5.1
  ABI) plus libopus, matching the executable's CPU architecture — `libavcodec.so.59`,
  `libavutil.so.57`, `libopus.so.0` on Linux; `.59.dylib` / `.57.dylib` / `.0.dylib`
  on macOS; `avcodec-59.dll`, `avutil-57.dll`, `opus.dll` or `libopus-0.dll` on
  Windows. These are bundled in official release packages (except windows/arm64);
  bare unbundled builds fall back to Tier 0 if they are absent. See
  [Display tiers & audio](display-tiers.md) for the full runtime detail.
- On **Linux** the embedded webview needs the **WebKitGTK 4.1** runtime
  (`libwebkit2gtk-4.1`, Ubuntu 23.10+ / Debian 12+). macOS and Windows use
  engines the OS already provides (WebKit, WebView2).

### Tier 1 media libraries (where to get them)

Release packages bundle the Tier 1 libraries, so Tier 1 works out of the
box: Windows zips/MSIs, Linux tarballs, AppImage, Flatpak and RPMs carry
LGPL FFmpeg 5.1 + Opus builds beside the binaries (with `NOTICE`/`COPYING`
attribution and per-target `BUILD-INFO` records); the `.deb` instead
recommends the distro packages (`libavcodec59`, `libavutil57`, `libopus0`
— installed by default on Debian 12). The only exception is windows/arm64,
which has no 5.1 shared source yet and keeps the Tier 0 fallback there.

You only need this section if you run a bare build (e.g. `make build`) or
a platform without bundled libraries. Tier 1 needs the **FFmpeg 5.1 ABI**
— libavcodec 59 + libavutil 57 — plus libopus. Any other FFmpeg major is
rejected (renaming a newer library does not work), and every library must
match the exe's CPU architecture. Two failure modes tell you what is
missing: without video decoders the client falls back to Tier 0 (run with
`-v` and look for `cannot decode it` naming the module); without audio
decode Tier 1 video still engages but stays muted (the Debug card shows the
audio state). A compatible build placed beside the executable always wins
over system libraries, so manual libraries also serve as an override.

- **Linux (distro packages):** Debian 12 ships exactly the right ABI:
  `sudo apt install libavcodec59 libavutil57 libopus0`. Other distros vary —
  Ubuntu 22.04's stock FFmpeg is 4.4 (`libavcodec58`, too old). Check what
  is actually installed with
  `ldconfig -p | grep -E 'libavcodec\.so\.59|libopus\.so\.0'`.
- **macOS:** you need `libavcodec.59.dylib`, `libavutil.57.dylib` and
  `libopus.0.dylib`. Current Homebrew `ffmpeg` tracks newer majors and is
  incompatible; options are building 5.1.x from [ffmpeg.org](https://ffmpeg.org/download.html)
  source or retaining a 5.1 install, then confirming the `.59`/`.57` filenames.
- **Windows:** the clean route is building the LGPL libraries from pinned
  source with the repo's scripts (desktop-client
  `third_party/media-libs/`: `build-ffmpeg.sh win-amd64` needs mingw-w64,
  then `build-opus.sh win-amd64`, then copy the staged DLLs beside the
  exe) — same ABI the release packages ship, no license strings attached
  beyond LGPL/BSD. In a hurry, the **5.1 full build** archive from the
  [GyanD/codexffmpeg releases page](https://github.com/GyanD/codexffmpeg/releases)
  also works for personal use (copy `bin\avcodec-59.dll` +
  `bin\avutil-57.dll` beside `kube-workspaces.exe`), but note it is a
  GPL-configured build: fine on your own machine, never redistribute it —
  see [Display tiers & audio](display-tiers.md#redistribution). Either way,
  if `-v` then names a further missing module, it is a transitive
  dependency (e.g. `swresample`) — copy it from the same `bin\` too.
  For audio, place a 64-bit `opus.dll` (or `libopus-0.dll`) beside the exe,
  e.g. via `vcpkg install opus:x64-windows`. `Unblock-File` everything
  copied in, and keep x64 DLLs with the amd64 exe (ARM64 DLLs with arm64).
  DLLs load from the app directory only; running from a network share works,
  but if the loader refuses, move the folder to a local disk first.

Official release packages bundle compliant LGPL/BSD libraries; for unbundled
or manual builds, redistribution and license notes live under
[Display tiers & audio](display-tiers.md#redistribution).

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
entry; the MSI does. The MSI setup wizard offers **Just me** (default,
per-user, no elevation) or **All users on this computer** (Program Files,
administrator permission requested as needed), and the completion page offers
to open the app. Silent per-machine installation uses
`msiexec /i kube-workspaces-<version>-windows-<arch>.msi /qn ALLUSERS=1`
from an elevated terminal.

CI builds are also downloadable from the desktop-client **Build** workflow:
`msi-windows-amd64` and `msi-windows-arm64`. The `SHA256SUMS` artifact covers
both installers and all six platform archives. The ARM64 installer is built
and inspected in CI; native ARM64 installation acceptance remains pending.

The in-app updater detects how the client was installed. MSI installations
update through the installer: the new `.msi` installs unattended after the
client quits, keeping the same scope and directory, and Add/Remove Programs
shows the new version. Manual zip installations keep the in-place binary
swap; uninstall before changing installation scope or architecture.

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

Two display tiers, chosen from the workspace's image — never a user setting.
The full matrix (what each tier does, which client plays it, audio per tier,
guest and client requirements, network quality tiers) lives in
[Display tiers & audio](display-tiers.md):

- **Tier 0 (RFB/VNC)** is the universal floor and fallback: works on any image,
  including pre-boot, BIOS/GRUB, and the login screen. Adaptive quality (Tight
  JPEG tuning with a lossless repaint when idle) is on by default. There is no
  Tier 0 audio playback in this client — it only detects whether the guest
  advertises a sound device (audio playback over Tier 0 is a web-client
  feature).
- **Tier 1 (in-guest agent)** is the premium path: Selkies H.264 plus Opus
  audio decoded to stereo 48 kHz PCM on Selkies-capable images (selected
  automatically), or the `kw-agent` premium window wherever the image
  advertises protocol `agent` —
  both with sticky Tier 0 fallback. Both need the FFmpeg 59 / libopus runtime libraries
  above; without them the client falls back to Tier 0 instead of failing.

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
