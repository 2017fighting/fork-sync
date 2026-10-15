#!/usr/bin/env bash
# sync-fork.sh — the per-Fork sync entry point (spec issue #1, Implementation
# Decisions). Receives exactly one Fork's config as a JSON object (the
# workflow's matrix step passes one entry; jq parses it here), then:
#
#   1. selects the Sync Tag: the greatest semver tag on the Upstream matching
#      the configured prefix, stable releases only (prereleases excluded);
#   2. rebases the Fork's Own Commits onto the Sync Tag (rebase --onto over
#      the merge-base with the Upstream's default branch), yielding linear
#      history; a pure Fork with zero Own Commits fast-forwards instead;
#   3. force-pushes the Fork's base branch, with lease against the just-fetched
#      ref;
#   4. Marks the Fork: a tag of the Sync Tag's name pointing at the Fork's own
#      head, force-moving any inherited tag of that name (ADR-0001).
#
# The Upstream is only ever read (ls-remote / fetch), never mutated.
#
# Usage: sync-fork.sh '<fork-config-json>'
#   {"fork": "<url>", "upstream": "<url>", "base_branch": "main",
#    "tag_prefix": "v", "forward_only": true, "include_prereleases": false}
#   fork, upstream, base_branch are required. Optional fields (the manifest
#   contract for the workflow's matrix step):
#     tag_prefix          — Sync Tag selection only sees tags with this
#                           prefix; the remainder must be semver. Default "v".
#     forward_only        — true: never move backward in Upstream history
#                           (default); false: strict tag sync, rebasing onto
#                           the Sync Tag even when that rewinds post-tag
#                           Upstream commits out of the Fork.
#     include_prereleases — false: prerelease tags (e.g. v1.4.0-rc.1) are
#                           skipped by selection (default); true: they may
#                           be chosen as the Sync Tag.
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
# precedence; prereleases (e.g. v1.4.0-rc.1) and non-semver names are
# ignored. Failing, exits with a code naming the configuration error:
#   1 — the Upstream has no tags at all;
#   2 — only prerelease tags matched the prefix (skipped by default);
#   3 — no tag matched the prefix at all.
select_sync_tag() {
  local upstream_url=$1 prefix=$2 name version best=""
  local saw_tag=false saw_prerelease=false
  while IFS=$'\t' read -r _sha ref; do
    name=${ref#refs/tags/}
    case "$name" in
      *'^{}') continue ;; # annotated tag peel lines
    esac
    saw_tag=true
    [ "${name#"$prefix"}" != "$name" ] || continue
    version=${name#"$prefix"}
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      if [ -z "$best" ] ||
        [ "$(printf '%s\n%s\n' "$best" "$version" | sort -V | tail -n 1)" = "$version" ]; then
        best=$version
      fi
    elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+$ ]]; then
      saw_prerelease=true
    fi # anything else: non-semver names never qualify
  done < <(git ls-remote --tags "$upstream_url")
  if [ -n "$best" ]; then
    printf '%s%s\n' "$prefix" "$best"
    return 0
  fi
  if [ "$saw_tag" = false ]; then
    return 1
  fi
  if [ "$saw_prerelease" = true ]; then
    return 2
  fi
  return 3
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
  # jq's `//` treats false like null, so boolean fields are read with an
  # explicit null check: a bare `.forward_only // true` would turn a
  # configured false back into true.
  jq -e 'if .forward_only == null then true
         else (.forward_only | type == "boolean") end' <<<"$config" >/dev/null ||
    die "config: .forward_only must be a boolean"
  forward_only=$(jq -r 'if .forward_only == null then true
                        else .forward_only end' <<<"$config")

  local sync_tag select_rc=0
  sync_tag=$(select_sync_tag "$upstream_url" "$tag_prefix") || select_rc=$?
  case "$select_rc" in
    1) die "the Upstream has no tags at all: cannot select a Sync Tag" ;;
    2) die "the Upstream's only tags matching prefix '$tag_prefix' are prereleases, which are skipped by default" ;;
    3) die "no stable tag with prefix '$tag_prefix' on the Upstream" ;;
  esac

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

  # No-op detection (spec issue #1, "No-op detection"): when the Fork already
  # carries a Mark equal to the Sync Tag pointing at its current base branch
  # head, the run does nothing. The Mark is read straight from the Fork
  # remote (ls-remote), never from the work repo: fetching a Fork whose
  # inherited tag was force-moved only yields "! [rejected] (already exists)"
  # and the local tag would silently keep the Upstream's position.
  local mark_sha
  mark_sha=$(git ls-remote "$fork_url" "refs/tags/$sync_tag" | cut -f1)
  if [ -n "$mark_sha" ] && [ "$mark_sha" = "$fork_base_sha" ]; then
    printf 'No-op: the Mark %s already points at the head of %s\n' \
      "$sync_tag" "$base_branch"
    printf 'Sync Tag: %s\n' "$sync_tag"
    return 0
  fi

  # Rebase rewrites the Own Commits; it needs a committer identity even on
  # runners without one configured. Authors are preserved by the rebase.
  if [ -z "$("${git[@]}" -C "$work" config user.email)" ]; then
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-fork-sync}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-fork-sync@invalid}"
  fi

  # Forward-only gate (the default policy): if the Fork's base branch already
  # contains the Sync Tag, the Fork never moves backward in Upstream history —
  # skip the rebase entirely (rebase --onto would rewind the post-tag Upstream
  # commits out of the Fork) and only refresh the Mark at the Fork's head.
  # Strict tag sync (forward_only: false) skips this gate: the rebase onto the
  # Sync Tag runs anyway, rewinding post-tag Upstream commits out of the Fork.
  local new_head
  if [ "$forward_only" = true ] &&
    "${git[@]}" -C "$work" merge-base --is-ancestor "$sync_commit" "$fork_base_sha"; then
    new_head=$fork_base_sha
  else
    if [ "$("${git[@]}" -C "$work" rev-list --count "$merge_base..$fork_base_sha")" -eq 0 ]; then
      # Pure fork (zero Own Commits): fast-forward the base branch straight
      # to the Sync Tag — no rebase machinery for a mirror with nothing to
      # replay.
      "${git[@]}" -C "$work" checkout --quiet -B "$base_branch" "$sync_commit"
    else
      "${git[@]}" -C "$work" checkout --quiet -B "$base_branch" "$fork_base_sha"
      "${git[@]}" -C "$work" rebase --onto "$sync_commit" "$merge_base" "$base_branch"
    fi
    new_head=$("${git[@]}" -C "$work" rev-parse "refs/heads/$base_branch")

    "${git[@]}" -C "$work" push --quiet \
      --force-with-lease="refs/heads/$base_branch:$fork_base_sha" \
      fork "refs/heads/$base_branch"
  fi

  # Mark the Fork: a tag of the Sync Tag's name pointing at the Fork's own
  # head, force-moving an inherited Upstream tag of that name (ADR-0001).
  "${git[@]}" -C "$work" tag --force "$sync_tag" "$new_head"
  "${git[@]}" -C "$work" push --quiet --force fork "refs/tags/$sync_tag"

  printf 'Sync Tag: %s\n' "$sync_tag"
}

main "$@"
