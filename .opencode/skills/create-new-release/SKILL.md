---
name: create-new-release
description: Cut a full kube-workspaces release following docs/releasing.md. Use when the user asks to create/cut/make/run a new release, do a release, cut the release, release the platform, or release a new version — this covers the CI pre-flight gate, the desktop-client tag release, the four component releases, the chart bump, the deploy release, and the website bump. Do not use for single-repo patches outside the coordinated release.
---

# Create a New kube-workspaces Release

Carry out the full coordinated release exactly as documented in
`docs/releasing.md` in this repo. This deploy repo is the working directory; the
sibling checkouts under `<workspace-root>/..` (`/home/flaccid/src/github/kube-workspaces/`)
contain `controller`, `api`, `proxy`, `frontend`, `desktop-client`,
`image-catalog`, `kube-workspaces.github.io`. Use them when a step needs a local
checkout; otherwise clone into a temp dir. **Never skip a step, renumber the
sequence, or move a gate.**

## Invariants

- Order is fixed: **desktop-client → controller/api/proxy/frontend → deploy**.
  The four components share one platform `vX.Y.Z`; the desktop client is on its
  **own semver lineage** — bumped over its own history, never matched to the
  platform version — and is only released **when it has new commits** since its
  last tag. Nothing pins the client image (it is not a Docker image).
- The deploy chart's `appVersion` names component images that must already be
  published before deploy is released — that is why components precede deploy.
- Every workflow_dispatch release has a dry-run gate: run with `dry_run=true`,
  show the user the generated notes, and get explicit confirmation before
  `dry_run=false`.
- Between steps, gate on published artifacts (Docker images / GitHub Release /
  published chart). Never start the next step on hearsay.

## Decision points to ask the user

1. The platform version `vX.Y.Z` (suggest next patch above the latest tag if
   they have none in mind — read it via `gh api
   repos/kube-workspaces/deploy/releases --jq '.[0].tag_name'` or `git
   describe --tags --abbrev=0`).
2. Whether this is a full component release (chart `version` == `appVersion`)
   or a chart-only fix (`appVersion` lags, see "Bump the chart").
3. The desktop-client version — **only asked if it has new commits** (step 1).
   Own line, suggested as next patch above its latest tag from `gh api
   repos/kube-workspaces/desktop-client/releases`; never the platform version.
4. Before each `dry_run=false`. Show the classification summary, not just a
   "yes".
5. How to land the chart bump + website bump: direct push to `main` (this repo
   has admin pushes that bypass PR rules) or an actual PR.

## Step 0 — Pre-flight: CI must be green

Run:

```sh
make show-ci-status
```

- A repo with `STATUS=failed` and `ACTION=yes` — stop. Ask the user, and do not
  proceed until the failure is fixed. A release cut over red CI bakes the
  failure in.
- `ACTION=wait` (in progress) — poll `gh run list -R <org>/<repo>` until it
  resolves before continuing.
- Treat `desktop-client` `Build` as the critical check: its release is tag
  driven, so a red Build at the tagged commit is never re-run against the tag.

## Step 1 — Desktop client (kube-workspaces/desktop-client)

This repo has no `release.yaml` workflow. Releasing = tagging `main`. **Decide
first whether a release is warranted: it is only released when `main` has new
commits since its last release tag.**

1. Find the last release tag and count commits on `main` since it:
   ```sh
   last_tag=$(gh api repos/kube-workspaces/desktop-client/releases \
     --jq '.[0].tag_name')
   gh api "repos/kube-workspaces/desktop-client/compare/${last_tag}...main" \
     --jq '{ahead_by, status}'
   ```
2. **If `ahead_by` is `0`, skip this step entirely.** Report to the user that the
   desktop client is unchanged since `${last_tag}` and no tag or release will be
   made; the existing download stays current. Continue to step 2 without asking
   for a version.
3. If there are changes, confirm the version with the user — on its **own
   semver lineage**, next patch above `${last_tag}` (e.g. `v0.2.0` → `v0.2.1`).
   Never align it with the platform version.
4. Work in the sibling checkout (`../desktop-client`) or clone. Fetch latest:
   `git fetch origin main && git checkout -B main origin/main`. Record the
   exact commit (`git rev-parse HEAD`).
5. Verify the runs for that commit are green (`gh run list -R
   kube-workspaces/desktop-client --branch main --commit <sha>`); especially
   `Build`. If red, stop.
6. Tag and push:
   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```
7. Watch the `Build` workflow until it publishes, then verify the GitHub
   Release exists with the per-platform archives and `SHA256SUMS`:
   ```sh
   gh api repos/kube-workspaces/desktop-client/releases --jq '.[0] | [.tag_name, .created_at] | @tsv'
   ```
8. There is no dry-run preview; ask the user to review the published release.
   Anything wrong becomes a follow-up patch release on the same line.

## Step 2 — Component repositories (shared platform version)

For each of `controller`, `api`, `proxy`, `frontend`, in order:

1. Dry run:
   ```sh
   gh workflow run release.yaml --repo kube-workspaces/<component> \
     -f version=v0.X.Y -f dry_run=true
   ```
2. Wait for that run (`gh run list -R kube-workspaces/<component>` newest
   `release` run → `gh run watch --exit-status <run-id>`), then read the
   generated notes from the log (`gh run view <run-id> --log-failed` or the
   "Generate release notes" step). Present the user a summary: breaking /
   feature / fix / CI-docs counts and the "no functional changes" classification.
3. On explicit confirmation, re-run with `dry_run=false`. The workflow tags the
   repo, and the tag push triggers the `Build and Push Docker Image` workflow.
4. Gate: poll until the Docker build for that tag succeeds and the image is
   published. Component images are tagged with the bare version (e.g. `0.3.0`).
   Verify publication before touching the next component, e.g.:
   ```sh
   gh run list -R kube-workspaces/<component> --workflow 'Build and Push Docker Image' \
     --json status,conclusion,headBranch --jq '.[0]'
   ```
   or check the GHCR manifest directly like `docs/releasing.md`'s workflow does
   (`gh auth token` → `curl .../manifests/<bare>`).

Do not start the next component until this one's image exists — a later dry run
can't surface it.

## Step 3 — Bump the chart (this repo)

1. Open `helm/kube-workspaces/Chart.yaml` and confirm the two diverging fields
   with the user:
   ```yaml
   version: 0.6.19      # the chart's own version — must equal the deploy tag (bare)
   appVersion: "0.6.19" # the component version it pins — must already be released
   ```
   - Full release: both equal the platform version.
   - Chart-only fix: `version` moves, `appVersion` stays at the last released
     component version (may legitimately be behind; must NOT be ahead).
2. Run `make test-lint` and `make test-upgrade` (the latter installs the
   published chart, upgrades to local, rolls back). Do not skip these.
3. Land the change per the user's choice: direct push (admin) or PR.
4. Merging to `main` publishes the chart to GHCR. Confirm it:
   `helm show chart oci://ghcr.io/kube-workspaces/charts/kube-workspaces --version <bare>`
   (or `gh api .../packages`). The publish workflow refuses an existing version;
   if it failed, resolve before moving on.

## Step 4 — Release deploy

1. Dry run:
   ```sh
   gh workflow run release.yaml --repo kube-workspaces/deploy \
     -f version=v0.X.Y -f dry_run=true
   ```
2. Wait for completion. The workflow enforces: valid `vX.Y.Z` and tag not taken,
   chart `version`/`appVersion` consistency, and published images for all four
   components at `appVersion`. If the dry run fails, fix the specific failure
   and re-run — the user must never reach `dry_run=false` on a failed dry run.
3. Present the notes; on confirmation re-run with `dry_run=false`.

## Step 5 — Update the website (kube-workspaces.github.io)

1. In the `kube-workspaces.github.io` sibling checkout (or a clone), bump the
   version badge to the platform `vX.Y.Z`.
2. If the desktop client was released in step 1, point the desktop client
   download link at the new release tag.
3. Land per that repo's conventions (PR or push) and confirm the site rebuild
   workflow succeeded (`Build and deploy site`).

## End-of-release verification checklist

Confirm all of:

- Images published for `controller`, `api`, `proxy`, `frontend` at the chart's
  `appVersion` (bare).
- `desktop-client` release page has the archives + `SHA256SUMS` (only if step 1
  was run — skipped when it had no new commits).
- Chart published at the platform version.
- `deploy` tag + release exist at `vX.Y.Z`.
- Website badge and desktop-client link updated.

If anything here is missing, do not report the release as done. Re-run
`make show-ci-status` one last time as a final sanity sweep.

## Failure handling

- Stop at the first failure. Report it with the failing command output and what
  it blocks, then wait for the user rather than improvising a workaround or
  skipping gates.
- A release cut over red CI or missing images must be treated as broken; surface
  the exact artifact/run that failed.