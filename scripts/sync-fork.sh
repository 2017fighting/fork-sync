#!/usr/bin/env bash
# sync-fork.sh — the per-Fork sync entry point (spec issue #1, Implementation
# Decisions). Receives exactly one Fork's config as a JSON object (the
# workflow's matrix step passes one entry; jq parses it here), then:
#
#   1. selects the Sync Tag: the greatest semver tag on the Upstream matching
#      the configured prefix, stable releases only (prereleases excluded);
#   2. rebases the Fork's Own Commits onto the Sync Tag (rebase --onto over
#      the merge-base with the Upstream's default branch), yielding linear
#      history;
#   3. force-pushes the Fork's base branch, with lease against the just-fetched
#      ref;
#   4. Marks the Fork: a tag of the Sync Tag's name pointing at the Fork's own
#      head, force-moving any inherited tag of that name (ADR-0001).
#
# The Upstream is only ever read (ls-remote / fetch), never mutated.
#
# Usage: sync-fork.sh '<fork-config-json>'
#   {"fork": "<url>", "upstream": "<url>", "base_branch": "main",
#    "tag_prefix": "v"}
#   fork, upstream, base_branch are required; tag_prefix defaults to "v".
set -euo pipefail

die() {
  printf 'sync-fork: %s\n' "$*" >&2
  exit 1
}

# Sync-created objects (rebased Own Commits, the Mark) are never signed: CI
# runners hold no signing key. Scoped per command so the host's own signing
# config still governs everything the sync does not create.
git=(git -c commit.gpgSign=false -c tag.gpgSign=false)

# select_sync_tag <upstream_url> <tag_prefix> — prints the Sync Tag's name.
# Among the Upstream's tags matching the prefix, the greatest by semver
# precedence; prereleases (e.g. v1.4.0-rc.1) and non-semver names are ignored.
select_sync_tag() {
  local upstream_url=$1 prefix=$2 name version best=""
  while IFS=$'\t' read -r _sha ref; do
    name=${ref#refs/tags/}
    case "$name" in
      *'^{}') continue ;; # annotated tag peel lines
    esac
    [ "${name#"$prefix"}" != "$name" ] || continue
    version=${name#"$prefix"}
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [ -z "$best" ] ||
      [ "$(printf '%s\n%s\n' "$best" "$version" | sort -V | tail -n 1)" = "$version" ]; then
      best=$version
    fi
  done < <(git ls-remote --tags "$upstream_url")
  [ -n "$best" ] || return 1
  printf '%s%s\n' "$prefix" "$best"
}

# conflicting_own_commits <work> <rebase_output> — prints one
# "<sha> <subject>" line per Own Commit the failed rebase stopped on, taken
# from git's own "could not apply <sha>... <subject>" lines (both the
# "error: "-prefixed form and the trailing summary form).
conflicting_own_commits() {
  local work=$1 rebase_output=$2 short subject sha
  while IFS=$'\t' read -r short subject; do
    [ -n "$short" ] || continue
    sha=$("${git[@]}" -C "$work" rev-parse --quiet --verify "$short^{commit}") ||
      sha=$short
    printf '%s %s\n' "$sha" "$subject"
  done < <(printf '%s\n' "$rebase_output" |
    sed -n 's/^\(error: \)\{0,1\}[Cc]ould not apply \([0-9a-f]\{7,\}\)\.\.\. \(#\{0,1\} \)\{0,1\}\(.*\)$/\2\t\4/p' |
    awk -F'\t' '!seen[$1]++')
}

# report_rebase_conflict <fork_url> <sync_tag> <work> <rebase_output> — the
# rebase of the Own Commits failed (a content conflict, in practice: the
# rebase runs on already-fetched objects). Aborting needs no undoing: the
# Fork remote is only ever mutated by the pushes after a successful rebase,
# so a failure here means simply not pushing. Reports what conflicted and
# exits non-zero. Never returns.
report_rebase_conflict() {
  local fork_url=$1 sync_tag=$2 work=$3 rebase_output=$4 commit
  printf 'sync-fork: CONFLICT rebasing Own Commits; aborted\n' >&2
  printf 'sync-fork:   Fork: %s\n' "$fork_url" >&2
  printf 'sync-fork:   Sync Tag: %s\n' "$sync_tag" >&2
  printf 'sync-fork:   conflicting Own Commits:\n' >&2
  while IFS= read -r commit; do
    printf 'sync-fork:     %s\n' "$commit" >&2
  done < <(conflicting_own_commits "$work" "$rebase_output")
  printf 'sync-fork:   the Fork is untouched (no branch or tag moved)\n' >&2
  exit 1
}

# upstream_default_branch <upstream_url> — Own Commits are defined against the
# Upstream's default branch.
upstream_default_branch() {
  local name
  name=$(git ls-remote --symref "$1" HEAD |
    sed -n 's|^ref: refs/heads/\([^\t]*\)\tHEAD$|\1|p')
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

main() {
  [ "$#" -eq 1 ] || die "usage: sync-fork.sh '<fork-config-json>'"
  local config=$1
  local fork_url upstream_url base_branch tag_prefix
  fork_url=$(jq -er '.fork | strings' <<<"$config") ||
    die "config: .fork must be a string"
  upstream_url=$(jq -er '.upstream | strings' <<<"$config") ||
    die "config: .upstream must be a string"
  base_branch=$(jq -er '.base_branch | strings' <<<"$config") ||
    die "config: .base_branch must be a string"
  tag_prefix=$(jq -r '.tag_prefix // "v"' <<<"$config")

  local sync_tag
  sync_tag=$(select_sync_tag "$upstream_url" "$tag_prefix") ||
    die "no stable tag with prefix '$tag_prefix' on the Upstream"

  local default_branch
  default_branch=$(upstream_default_branch "$upstream_url") ||
    die "the Upstream's HEAD is not a branch"

  # Not local: the EXIT trap must see it after main returns.
  work=$(mktemp -d)
  trap 'rm -rf -- "${work:-}"' EXIT

  "${git[@]}" clone --quiet --no-tags "$fork_url" "$work"
  "${git[@]}" -C "$work" remote rename origin fork
  "${git[@]}" -C "$work" remote add upstream "$upstream_url"
  "${git[@]}" -C "$work" fetch --quiet upstream --tags
  "${git[@]}" -C "$work" fetch --quiet fork

  local sync_commit fork_base_sha merge_base
  sync_commit=$("${git[@]}" -C "$work" rev-parse "refs/tags/$sync_tag^{commit}")
  fork_base_sha=$("${git[@]}" -C "$work" rev-parse "refs/remotes/fork/$base_branch")
  merge_base=$("${git[@]}" -C "$work" merge-base \
    "refs/remotes/fork/$base_branch" "refs/remotes/upstream/$default_branch")

  # Rebase rewrites the Own Commits; it needs a committer identity even on
  # runners without one configured. Authors are preserved by the rebase.
  if [ -z "$("${git[@]}" -C "$work" config user.email)" ]; then
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-fork-sync}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-fork-sync@invalid}"
  fi

  "${git[@]}" -C "$work" checkout --quiet -B "$base_branch" "$fork_base_sha"
  local rebase_output
  if ! rebase_output=$("${git[@]}" -C "$work" rebase --onto "$sync_commit" \
    "$merge_base" "$base_branch" 2>&1); then
    report_rebase_conflict "$fork_url" "$sync_tag" "$work" "$rebase_output"
  fi
  printf '%s\n' "$rebase_output" >&2

  local new_head
  new_head=$("${git[@]}" -C "$work" rev-parse "refs/heads/$base_branch")

  "${git[@]}" -C "$work" push --quiet \
    --force-with-lease="refs/heads/$base_branch:$fork_base_sha" \
    fork "refs/heads/$base_branch"

  # Mark the Fork: a tag of the Sync Tag's name pointing at the Fork's own
  # head, force-moving an inherited Upstream tag of that name (ADR-0001).
  "${git[@]}" -C "$work" tag --force "$sync_tag" "$new_head"
  "${git[@]}" -C "$work" push --quiet --force fork "refs/tags/$sync_tag"

  printf 'Sync Tag: %s\n' "$sync_tag"
}

main "$@"
