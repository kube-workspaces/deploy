# Releasing

kube-workspaces is five repositories released together. The Helm chart's
`appVersion` pins all four component images to a single number, so they share a
version: one platform version is materially easier to support than four drifting
ones. The desktop client is released alongside them, on its own version line (see
"Order matters").

## Order matters

Release the **four components first**, then `deploy`. The chart's `appVersion`
names images that must already exist, and the release workflow refuses to proceed
otherwise.

The desktop client is released **first**, before the components. It is
standalone: it is not a Docker image, is not pinned by the chart, and versions
itself (its `vX.Y.Z` line is unrelated to the platform's), so it has no ordering
dependency on the rest. It goes early so the newest client is on the downloads
page by the time a platform release lands — the client consumes platform
features via the proxy, and we do not want a window where the published client
cannot talk to a just-released platform.

```
controller ─┐
api        ─┤
proxy      ─┼─> deploy (chart + appVersion)
frontend   ─┘

desktop-client ──> standalone binaries (not in the chart)
```

## Procedure

### 0. Pre-flight: CI must be green

Before heading into the component releases, check that nothing on the org's
default branches is failing — a release cut over red CI bakes the failure in,
and a re-run cannot be attached to the tag:

```sh
make show-ci-status
```

The script inspects the most recent workflow runs on each repo's default branch
and flags any repo whose newest commit has a failing run (`failed` / `yes`).
Failures already fixed on the tip are reported in the `NOTES` column as `older`
refs rather than action items, so the table answers the release question — does
anything need attention now — and not "were there ever red builds".

```sh
# Restrict to specific repos, or widen the window:
scripts/org-project-recent-actions-status.sh --repo controller --repo api
scripts/org-project-recent-actions-status.sh --runs 25
```

Address the failing repos before proceeding. The script exits non-zero when any
repo needs action. This matters for the desktop client in particular (step 1):
its release is tag-driven, so a red `Build` run at the tag's commit neither
blocks the tag nor gets re-run — it ships broken binaries.

### 1. Desktop client

`desktop-client` does **not** use the component `release.yaml` workflow and is
released on its own version line, independent of the platform version:

```sh
# in kube-workspaces/desktop-client
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

Pushing the tag triggers `build.yml`, which cross-builds the per-platform
archives, composes the release notes (download links, install steps, an unsigned
warning) and publishes the GitHub Release — binaries plus `SHA256SUMS`. There is
no dry-run preview; review the published release on the releases page and fix
anything wrong in a follow-up patch release on the same line.

The client must be green first. `make show-ci-status` flags it `failed` if the
newest commit's runs (notably `Build`) are not passing.

### 2. Component repositories

For each of `controller`, `api`, `proxy`, `frontend`:

```sh
gh workflow run release.yaml --repo kube-workspaces/<component> \
  -f version=v0.3.0 -f dry_run=true
```

Review the generated notes in the run summary, then re-run with
`dry_run=false`. Tagging triggers the Docker workflow, which publishes
`0.3.0`, `0.3` and `latest`.

Wait for those builds to finish before moving on.

### 3. Bump the chart

In `deploy`, set both fields in `helm/kube-workspaces/Chart.yaml`:

```yaml
version: 0.3.0      # the chart's own version — must equal the deploy tag
appVersion: "0.3.0" # the component version it pins — must already be released
```

The two are **not** required to match. `version` is the chart's own release line
and must equal the tag; `appVersion` names the component release the chart pins.
A chart-only fix — an ingress path, a template guard — bumps `version` without
there being any new component build, so `appVersion` legitimately lags:

```yaml
version: 0.2.2      # chart-only fix
appVersion: "0.2.1" # still pinning the 0.2.1 components
```

The release workflow enforces exactly that: `version` must equal the tag,
`appVersion` must not be *ahead* of it, and images must exist at `appVersion`.

Then verify and merge:

```sh
make test-lint
make test-upgrade   # installs the published chart, upgrades to local, rolls back
```

Merging to `main` publishes the chart to GHCR. The publish workflow refuses to
overwrite an existing version.

### 4. Release `deploy`

```sh
gh workflow run release.yaml --repo kube-workspaces/deploy \
  -f version=v0.3.0 -f dry_run=true
```

The workflow checks, before doing anything irreversible, that:

- the version is `vX.Y.Z` and the tag does not already exist
- `Chart.yaml` `version` **and** `appVersion` both match
- a matching image is published for all four components

Re-run with `dry_run=false` to tag and publish.

### 5. Update the website

Bump the version badge in
[kube-workspaces.github.io](https://github.com/kube-workspaces/kube-workspaces.github.io)
and, if the desktop client moved (step 1), point its download link at the new
release.

## Release notes

Notes are generated, not hand-written. `scripts/release-notes.sh` emits the
whole body:

1. **A preamble** that classifies the commits since the last tag and leads with
   what the reader needs to know.
2. **Upgrade instructions** tailored to the repo.
3. **A categorised "What's Changed" list**, grouped per the headings in
   `.github/release.yml` — identical across every kube-workspaces repo that
   publishes releases, and enforced by `scripts/check-release-config.sh`.

The commit list is built from commit subjects rather than left to GitHub's
`--generate-notes`, which groups commits **by pull request** and keys categories
off PR labels. Commits that land as direct pushes to `main` — common in this repo,
see the quirk below — have no PR and would otherwise produce an empty list.

### Components with no functional changes

A component often has nothing but CI and docs changes in a cycle, and still gets
tagged to hold the version line. The preamble says so explicitly:

> **No functional changes in this release.**
>
> The N commits since `vX.Y.Z` are CI, tooling and documentation only. This
> version exists to keep the kube-workspaces components aligned […] Upgrading is
> safe and changes no behaviour.

This is deliberately conservative. A commit only counts as non-functional if it
carries a `ci:`, `build:`, `docs:`, `chore:`, `style:` or `test:` prefix.
Anything unrecognised counts as *functional*, so an unprefixed commit prevents
the claim and is reported as unclassified — better to under-claim than to tell
someone a release is inert when it is not.

Breaking changes (`feat!:`, or any prefix with `!`) produce a warning callout at
the top instead.

### Labelling

Categorisation keys off PR labels. Available in every repo:

| Label | Section |
|-------|---------|
| `breaking` | ⚠️ Breaking changes |
| `security` | 🔒 Security |
| `enhancement` | ✨ Features |
| `bug` | 🐛 Fixes |
| `documentation` | 📚 Documentation |
| `ci`, `chore` | 🔧 CI and tooling |
| `dependencies` | ⬆️ Dependencies |

Unlabelled PRs land in *Other changes* rather than vanishing. `duplicate`,
`invalid`, `wontfix` and `question` are excluded.

## Versioning

Semantic versioning, judged against the **platform**, not individual components:

- **Patch** — fixes only, no new capability
- **Minor** — new capability, or a deprecation with a working fallback
- **Major** — anything requiring user action to upgrade

A field deprecated with a documented, tested fallback is a *minor*. Removing it
later is a *major*.

## Preview notes locally

```sh
scripts/release-notes.sh --repo deploy --from v0.2.0 --to HEAD
```

## Known quirks

### The `v0.2.0` publish run shows red

The `Publish Helm Chart` run triggered by the `v0.2.0` **release event** failed.
The chart is published and the release is complete — this is cosmetic.

The version guard was too blunt at the time: on a release event `HEAD` is the
tagged commit, which of course changed the chart, since bumping the version is how
the release was prepared. The push to `main` had already published it, so there
was nothing left to do. Fixed in `helm-publish.yaml`, which now only enforces the
"changed without a bump" rule on pushes to `main`.

Re-running does not clear it: a re-run checks out the tag, which predates the fix.
Clearing it would mean re-tagging a published release, which is not worth doing.
Releases from `v0.2.1` onward are unaffected.

### `main` history includes direct pushes

Branch protection on `deploy` requires pull requests but has
`enforce_admins: false`, so commits made with an admin token can and did land
directly on `main` — most of the test-suite and CI work arrived that way while it
was being iterated against real runners.

This used to leave the generated release notes with an empty "What's Changed"
list: GitHub groups commits by PR, and a direct push has no PR. The notes are now
generated from commit subjects by `scripts/release-notes.sh`, so they populate
regardless of how the commits landed.

The four component repositories were changed via PR throughout. If direct pushes
to `deploy` are unwanted, set `enforce_admins: true`:

```sh
gh api -X PATCH repos/kube-workspaces/deploy/branches/main/protection/enforce_admins
```

Note this also blocks `--admin` merges, so every PR would then need a reviewer.
