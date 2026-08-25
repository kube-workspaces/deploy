# Releasing

kube-workspaces is five repositories released together. The Helm chart's
`appVersion` pins all four component images to a single number, so they share a
version: one platform version is materially easier to support than four drifting
ones.

## Order matters

Release the **four components first**, then `deploy`. The chart's `appVersion`
names images that must already exist, and the release workflow refuses to proceed
otherwise.

```
controller ─┐
api        ─┤
proxy      ─┼─> deploy (chart + appVersion)
frontend   ─┘
```

## Procedure

### 1. Component repositories

For each of `controller`, `api`, `proxy`, `frontend`:

```sh
gh workflow run release.yaml --repo kube-workspaces/<component> \
  -f version=v0.3.0 -f dry_run=true
```

Review the generated notes in the run summary, then re-run with
`dry_run=false`. Tagging triggers the Docker workflow, which publishes
`0.3.0`, `0.3` and `latest`.

Wait for those builds to finish before moving on.

### 2. Bump the chart

In `deploy`, set both fields in `helm/kube-workspaces/Chart.yaml`:

```yaml
version: 0.3.0      # the chart's own version
appVersion: "0.3.0" # the component version it pins
```

Then verify and merge:

```sh
make test-lint
make test-upgrade   # installs the published chart, upgrades to local, rolls back
```

Merging to `main` publishes the chart to GHCR. The publish workflow refuses to
overwrite an existing version.

### 3. Release `deploy`

```sh
gh workflow run release.yaml --repo kube-workspaces/deploy \
  -f version=v0.3.0 -f dry_run=true
```

The workflow checks, before doing anything irreversible, that:

- the version is `vX.Y.Z` and the tag does not already exist
- `Chart.yaml` `version` **and** `appVersion` both match
- a matching image is published for all four components

Re-run with `dry_run=false` to tag and publish.

### 4. Update the website

Bump the version badge in
[kube-workspaces.github.io](https://github.com/kube-workspaces/kube-workspaces.github.io).

## Release notes

Notes are generated, not hand-written. Two parts combine:

1. **A preamble** from `scripts/release-notes.sh`, which classifies the commits
   since the last tag and leads with what the reader needs to know.
2. **A categorised commit list** appended by GitHub, grouped per
   `.github/release.yml` — identical in all five repos, and enforced by
   `scripts/check-release-config.sh`.

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
