# shellcheck shell=bash
# Fixture builder for the per-Fork sync seam tests (spec issue #1, Testing
# Decisions). Builds the canonical scenario over bare file:// remotes:
#
#   Upstream main = v1.3.2 + 4 commits, carrying older stable tags (v1.3.0,
#   v1.3.1) and one newer prerelease tag (v1.4.0-rc.1), so Sync Tag selection
#   must pick the greatest *stable* tag, not main's tip and not the prerelease.
#
#   Fork main = Upstream base + 2 Own Commits, carrying an inherited v1.3.2
#   tag that still points at the Upstream's tagged commit (off the Fork's
#   branch). The Fork forks at the Sync Tag's parent: with "v1.3.2 + 4
#   commits" on main, forking later would leave the Sync Tag already inside
#   the Fork's history and the rebase would never run.
#
# Commits use fixed authors, committers, and dates so every rebuild produces
# byte-identical remotes.

# Deterministic commit clock shared by every fixture builder: fixed authors,
# committers, and dates so every rebuild produces byte-identical remotes.
# Each builder resets it before its first commit.
FIXTURE_DATE=1700000000

fixture_commit() { # <work> <subject>
  local work=$1 d=$FIXTURE_DATE
  GIT_AUTHOR_NAME="Fixture Builder" \
    GIT_AUTHOR_EMAIL="fixtures@fork-sync.invalid" \
    GIT_AUTHOR_DATE="$d +0000" \
    GIT_COMMITTER_NAME="Fixture Builder" \
    GIT_COMMITTER_EMAIL="fixtures@fork-sync.invalid" \
    GIT_COMMITTER_DATE="$d +0000" \
    git -C "$work" commit --quiet --allow-empty -m "$2"
  FIXTURE_DATE=$((d + 60))
}

build_canonical_scenario() {
  local dir=$1
  local work="$dir/fixture-work"
  FIXTURE_DATE=1700000000

  git -c init.defaultBranch=main init --quiet --bare "$dir/upstream.git"
  git -c init.defaultBranch=main init --quiet --bare "$dir/fork.git"
  git -c init.defaultBranch=main init --quiet "$work"

  # Upstream main: v1.3.2 + 4 commits (u5..u8), stable and prerelease tags.
  fixture_commit "$work" "Upstream: u1"
  fixture_commit "$work" "Upstream: u2"; git -C "$work" tag v1.3.0
  fixture_commit "$work" "Upstream: u3"; git -C "$work" tag v1.3.1
  fixture_commit "$work" "Upstream: u4"; git -C "$work" tag v1.3.2
  fixture_commit "$work" "Upstream: u5"
  fixture_commit "$work" "Upstream: u6"
  fixture_commit "$work" "Upstream: u7"
  fixture_commit "$work" "Upstream: u8"; git -C "$work" tag v1.4.0-rc.1
  git -C "$work" push --quiet "$dir/upstream.git" refs/heads/main
  git -C "$work" push --quiet "$dir/upstream.git" --tags

  # Fork main: forked at u3 (the Sync Tag's parent) + 2 Own Commits.
  git -C "$work" checkout --quiet -b fork-main v1.3.1
  fixture_commit "$work" "Fork: first Own Commit"
  fixture_commit "$work" "Fork: second Own Commit"
  git -C "$work" push --quiet "$dir/fork.git" fork-main:refs/heads/main
  # Inherited Upstream tag, still pointing at the Upstream's tagged commit.
  git -C "$work" push --quiet "$dir/fork.git" refs/tags/v1.3.2

  # The remotes must stand alone: drop the scratch checkout.
  rm -rf "$work"

  # Consumed by the sourcing test runner.
  # shellcheck disable=SC2034
  FIX_UPSTREAM="file://$dir/upstream.git"
  # shellcheck disable=SC2034
  FIX_FORK="file://$dir/fork.git"
}

# Already-contains variant (spec issue #1, "Forward-only gate"): rewrites the
# canonical fixture's Fork so its main already contains the Sync Tag — forked
# at the Upstream's tip (4 commits past v1.3.2) with 2 Own Commits on top,
# still carrying the inherited v1.3.2 tag at the Upstream's commit. The sync
# must leave that history untouched (a rebase --onto v1.3.2 would rewind the
# post-tag Upstream commits out of the Fork) and only refresh the Mark.
build_already_contains_scenario() { # <dir>
  local dir=$1
  local work="$dir/variant-work"
  FIXTURE_DATE=1700010000

  git clone --quiet "$FIX_UPSTREAM" "$work"
  fixture_commit "$work" "Fork: first Own Commit"
  fixture_commit "$work" "Fork: second Own Commit"
  git -C "$work" push --quiet --force "$FIX_FORK" refs/heads/main:refs/heads/main
  rm -rf "$work"
}
