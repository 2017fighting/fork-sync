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

build_canonical_scenario() {
  local dir=$1
  local work="$dir/fixture-work"
  local date=1700000000

  git -c init.defaultBranch=main init --quiet --bare "$dir/upstream.git"
  git -c init.defaultBranch=main init --quiet --bare "$dir/fork.git"
  git -c init.defaultBranch=main init --quiet "$work"

  fixture_commit() { # subject
    GIT_AUTHOR_NAME="Fixture Builder" \
      GIT_AUTHOR_EMAIL="fixtures@fork-sync.invalid" \
      GIT_AUTHOR_DATE="$date +0000" \
      GIT_COMMITTER_NAME="Fixture Builder" \
      GIT_COMMITTER_EMAIL="fixtures@fork-sync.invalid" \
      GIT_COMMITTER_DATE="$date +0000" \
      git -C "$work" commit --quiet --allow-empty -m "$1"
    date=$((date + 60))
  }

  # Upstream main: v1.3.2 + 4 commits (u5..u8), stable and prerelease tags.
  fixture_commit "Upstream: u1"
  fixture_commit "Upstream: u2"; git -C "$work" tag v1.3.0
  fixture_commit "Upstream: u3"; git -C "$work" tag v1.3.1
  fixture_commit "Upstream: u4"; git -C "$work" tag v1.3.2
  fixture_commit "Upstream: u5"
  fixture_commit "Upstream: u6"
  fixture_commit "Upstream: u7"
  fixture_commit "Upstream: u8"; git -C "$work" tag v1.4.0-rc.1
  git -C "$work" push --quiet "$dir/upstream.git" refs/heads/main
  git -C "$work" push --quiet "$dir/upstream.git" --tags

  # Fork main: forked at u3 (the Sync Tag's parent) + 2 Own Commits.
  git -C "$work" checkout --quiet -b fork-main v1.3.1
  fixture_commit "Fork: first Own Commit"
  fixture_commit "Fork: second Own Commit"
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
