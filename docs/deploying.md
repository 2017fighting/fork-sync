# Deploying fork-sync

This repo is the central management repo: it holds the manifest
(`forks.yml`), the workflow (`.github/workflows/sync-forks.yml`), and the
sync scripts. It never holds the Forks' code. One run syncs every Fork in
the manifest in parallel, each Fork isolated in its own matrix row. For the
domain language (Upstream, Fork, Sync Tag, Own Commits, Mark, Forward-only)
see [GLOSSARY.md](../GLOSSARY.md); the system's behavior is specified in
issue #1.

## The manifest: adding a Fork

`forks.yml` at the repo root is the single declaration of what gets synced:

```yaml
defaults:
  forward_only: true      # never move backward in Upstream history (default)
  tag_prefix: "v"         # only tags like v1.3.2 are Sync Tag candidates
  include_prereleases: false  # rc/beta tags are skipped (default)

forks:
  - fork: "https://github.com/you/your-fork.git"        # required
    upstream: "https://github.com/original/project.git" # required
    base_branch: "main"                                 # required; must exist
                                                        # on the Fork
    # optional overrides of the defaults, per Fork:
    # tag_prefix: "release-"
    # forward_only: false        # strict tag sync: may rewind post-tag
    #                              Upstream commits out of the Fork
    # include_prereleases: true
```

- A Fork entry's own value always wins over `defaults`; `defaults` wins over
  the built-ins shown above. Every field the sync needs is resolved before
  the run starts.
- The shipped file lists this repo's real Forks. A misconfigured entry fails
  loudly instead of syncing anything; `forks: []` is valid and makes the run
  do nothing.
- Adding or removing a Fork is a one-line change: edit `forks.yml`, commit,
  push. The next run picks it up — daily at 04:17 UTC, or dispatch manually
  (below).

The workflow's setup job validates the manifest with
`scripts/manifest-to-matrix.py` before anything runs: a missing required
field, a wrong type (`forward_only: "yes-please"`), or an unknown key
(a typo like `forward-only`) fails the run immediately with a message naming
the offending entry — nothing touches any Fork. An empty `forks: []` is
valid and simply skips the sync.

## Creating the fine-grained PAT

The sync pushes to your Forks, which live in *other* repositories, so the
workflow's own `GITHUB_TOKEN` (scoped to this repo only) can never be used
for pushes. One fine-grained PAT covers every Fork:

1. GitHub → your avatar (top right) → **Settings** → **Developer settings**
   (bottom of the left sidebar) → **Personal access tokens** →
   **Fine-grained tokens** → **Generate new token**.
2. **Repository access**: *Only select repositories* → pick **every Fork**
   (and only the Forks — the sync only ever reads the Upstreams, and it
   never pushes to this central repo).
3. **Permissions** → **Repository permissions** → **Contents**:
   **Read and write**. Nothing else. (A fine-grained token always carries a
   mandatory read-only *Metadata* permission; that is expected.)
4. Generate and copy the token (`github_pat_...`) — it is shown once.

## Storing the secret

This repo → **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**:

- **Name**: `FORK_SYNC_PAT`
- **Secret**: the token from the previous step

The workflow reads only this one secret. If it is missing, every sync row
fails immediately with `the FORK_SYNC_PAT secret is not set`.

## First run and verification (manual smoke run)

The workflow runs daily at 04:17 UTC and can be triggered manually:

1. **Actions** tab → **Sync Forks** (left sidebar) → **Run workflow** →
   Run.
2. The run shows two kinds of rows: **Parse the manifest** (the setup job,
   one row) and **sync &lt;fork-url&gt;** — one row per Fork, so each Fork's
   status is visible at a glance. One Fork failing never cancels the others.
3. Open a Fork's row and check the log:
   - `Sync Tag: v1.3.2` — the Upstream release chosen for this run;
   - `No-op: the Mark ... already points at ...` — the Fork was already
     synced; nothing changed.
4. Verify the Fork itself:
   - `main` is the Sync Tag's commit with the Fork's Own Commits rebased on
     top (linear history);
   - the tag named like the Sync Tag (the **Mark**) points at the Fork's
     own head — on the Fork, `git rev-parse v1.3.2` and `git rev-parse main`
     give the same commit.

## Conflict issues

When rebasing a Fork's Own Commits onto the Sync Tag conflicts, the run
aborts before any push — the Fork stays byte-identical — and files (or
comments on) an issue **on this central repo**, titled
`fork-sync conflict: <fork-url> onto <sync-tag>`. While such an issue is
open, later conflicted runs comment on it instead of filing duplicates.

Resolve manually, exactly as the issue body spells out:

1. Clone the Fork with the remote named `fork` (`git clone -o fork <fork-url>`;
   the entry script names the Fork remote `fork` too) and add its Upstream
   as remote `upstream`.
2. `git fetch upstream --tags`
3. Rebase the Fork's Own Commits onto the Sync Tag, resolving conflicts:
   `git rebase --onto refs/tags/<tag> "$(git merge-base main upstream/HEAD)" main`
4. `git push --force-with-lease fork main`
5. Mark the Fork: `git tag --force <tag> main && git push --force fork refs/tags/<tag>`
6. Close the issue; the next run treats the Fork as synced.
