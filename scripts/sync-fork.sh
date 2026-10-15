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
#      head, force-moving any inherited tag of that name (ADR-0001);
#   5. on a rebase conflict: aborts before any Fork mutation (nothing has
#      been pushed yet), reports the Fork, the Sync Tag, and the conflicting
#      Own Commits, and files (or reuses) a resolution issue on the central
#      management repo via gh.
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
# Environment:
#   FORK_SYNC_CENTER_REPO — owner/name of the central management repo where
#   conflict issues are filed via gh; required only when a conflict must be
#   reported (the workflow injects it — ticket #6).
set -euo pipefail

die() {
  printf 'sync-fork: %s\n' "$*" >&2
  exit 1
}

# Sync-created objects (rebased Own Commits, the Mark) are never signed: CI
# runners hold no signing key. Scoped per command so the host's own signing
# config still governs everything the sync does not create.
git=(git -c commit.gpgSign=false -c tag.gpgSign=false)

# read_bool_field <config> <field> <default> — prints the field's boolean
# value. jq's `//` treats false like null, so it is never used here: a bare
# `.forward_only // true` would turn a configured false back into true. A
# missing/null field takes <default>; a present value must be a boolean or
# the read fails.
read_bool_field() {
  local config=$1 field=$2 default=$3 value
  value=$(jq -r --arg field "$field" --argjson default "$default" \
    '.[$field] as $v |
     if $v == null then $default
     elif ($v | type) == "boolean" then $v
     else empty end' <<<"$config")
  [ -n "$value" ] || die "config: .$field must be a boolean"
  printf '%s' "$value"
}

# select_sync_tag <upstream_url> <tag_prefix> <include_prereleases> — prints
# the Sync Tag's name. Among the Upstream's tags matching the prefix, the
# greatest by semver precedence; prereleases (e.g. v1.4.0-rc.1) are skipped
# unless include_prereleases is true; non-semver names are always ignored.
# Failing, exits with a code naming the configuration error:
#   1 — the Upstream has no tags at all;
#   2 — only prerelease tags matched the prefix (skipped unless included);
#   3 — no tag matched the prefix at all.
select_sync_tag() {
  local upstream_url=$1 prefix=$2 include_prereleases=$3
  local name version version_ok greatest_version=""
  local saw_tag=false saw_prerelease=false
  while IFS=$'\t' read -r _sha ref; do
    name=${ref#refs/tags/}
    case "$name" in
      *'^{}') continue ;; # annotated tag peel lines
    esac
    saw_tag=true
    [ "${name#"$prefix"}" != "$name" ] || continue
    version=${name#"$prefix"}
    version_ok=false
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      version_ok=true
    elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+$ ]]; then
      saw_prerelease=true
      if [ "$include_prereleases" = true ]; then
        version_ok=true
      fi
    fi # anything else: non-semver names never qualify
    if [ "$version_ok" = true ]; then
      if [ -z "$greatest_version" ] ||
        [ "$(printf '%s\n%s\n' "$greatest_version" "$version" | sort -V | tail -n 1)" = "$version" ]; then
        greatest_version=$version
      fi
    fi
  done < <(git ls-remote --tags "$upstream_url")
  if [ -n "$greatest_version" ]; then
    printf '%s%s\n' "$prefix" "$greatest_version"
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
  local fork_url=$1 sync_tag=$2 work=$3 rebase_output=$4 commit conflicts=""
  printf 'sync-fork: CONFLICT rebasing Own Commits; aborted\n' >&2
  printf 'sync-fork:   Fork: %s\n' "$fork_url" >&2
  printf 'sync-fork:   Sync Tag: %s\n' "$sync_tag" >&2
  printf 'sync-fork:   conflicting Own Commits:\n' >&2
  while IFS= read -r commit; do
    printf 'sync-fork:     %s\n' "$commit" >&2
    conflicts+="$commit"$'\n'
  done < <(conflicting_own_commits "$work" "$rebase_output")
  printf 'sync-fork:   the Fork is untouched (no branch or tag moved)\n' >&2
  notify_conflict "$fork_url" "$sync_tag" "$conflicts"
  exit 1
}

# conflict_issue_body <fork_url> <sync_tag> <conflicts> — the issue text:
# what aborted, which Own Commits conflicted, and the remedy (resolve
# manually, push, Mark, close).
conflict_issue_body() {
  local fork_url=$1 sync_tag=$2 conflicts=$3
  printf 'The automated sync of the Fork %s onto the Upstream Sync Tag %s\n' \
    "$fork_url" "$sync_tag"
  printf "was aborted: rebasing the Fork's Own Commits onto the tag hit a\n"
  printf 'conflict. The Fork is untouched — no branch and no tag was moved.\n'
  if [ -n "$conflicts" ]; then
    printf '\nConflicting Own Commits:\n'
    printf '%s' "$conflicts" | sed 's/^/  /'
  fi
  printf '\nRemedy (manual resolution):\n'
  printf '  1. Clone the Fork with the remote named "fork": git clone -o fork %s\n' "$fork_url"
  printf '     Then add its Upstream as remote "upstream".\n'
  printf "  2. Fetch the Upstream's tags: git fetch upstream --tags\n"
  printf "  3. Rebase the Fork's Own Commits onto the Sync Tag, resolving conflicts:\n"
  # The $(...) below is literal guidance for the human resolving by hand.
  # shellcheck disable=SC2016
  printf '       git rebase --onto refs/tags/%s "$(git merge-base main upstream/HEAD)" main\n' \
    "$sync_tag"
  printf '  4. Push the result: git push --force-with-lease fork main\n'
  printf '  5. Mark the Fork: git tag --force %s main && git push --force fork refs/tags/%s\n' \
    "$sync_tag" "$sync_tag"
  printf '  6. Close this issue; the next run will treat the Fork as synced.\n'
}

# notify_conflict <fork_url> <sync_tag> <conflicts> — the notification step
# (spec issue #1, Conflict handling): file an issue on the central
# management repo titled after the Fork and the Sync Tag, with remedy steps.
# The repo is FORK_SYNC_CENTER_REPO (owner/name), injectable so tests run
# against the fake gh; the workflow wires the real value (ticket #6).
# Reuse: while an issue about this Fork's sync conflicts is still open, the
# run comments on it instead of filing a duplicate (spec issue #1, story
# 18). Discovery is a title search for the Fork, matching the deterministic
# title below.
notify_conflict() {
  local fork_url=$1 sync_tag=$2 conflicts=$3
  local center_repo title body number issues
  center_repo=${FORK_SYNC_CENTER_REPO:-}
  [ -n "$center_repo" ] ||
    die "FORK_SYNC_CENTER_REPO (owner/name of the central management repo) is unset: cannot file the conflict issue"
  title="fork-sync conflict: $fork_url onto $sync_tag"
  body=$(conflict_issue_body "$fork_url" "$sync_tag" "$conflicts")
  issues=$(gh issue list --repo "$center_repo" --state open \
    --search "fork-sync conflict $fork_url in:title" --json number) ||
    issues='[]'
  number=$(jq -r '.[0].number // empty' <<<"$issues") || number=''
  if [ -n "$number" ]; then
    gh issue comment "$number" --repo "$center_repo" --body "$body"
    printf 'sync-fork: conflict reported on issue #%s of %s\n' "$number" "$center_repo" >&2
  else
    gh issue create --repo "$center_repo" --title "$title" --body "$body"
    printf 'sync-fork: conflict filed as a new issue on %s\n' "$center_repo" >&2
  fi
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
  forward_only=$(read_bool_field "$config" forward_only true)
  include_prereleases=$(read_bool_field "$config" include_prereleases false)

  local sync_tag select_rc=0
  sync_tag=$(select_sync_tag "$upstream_url" "$tag_prefix" "$include_prereleases") ||
    select_rc=$?
  case "$select_rc" in
    1) die "the Upstream has no tags at all: cannot select a Sync Tag" ;;
    2) die "the Upstream's only tags matching prefix '$tag_prefix' are prereleases, which are skipped by default; set include_prereleases: true to track them" ;;
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
      # On a conflict the rebase fails before anything has been pushed, so
      # aborting is simply not reaching the pushes below (report_rebase_conflict
      # never returns).
      local rebase_output
      if ! rebase_output=$("${git[@]}" -C "$work" rebase --onto "$sync_commit" \
        "$merge_base" "$base_branch" 2>&1); then
        report_rebase_conflict "$fork_url" "$sync_tag" "$work" "$rebase_output"
      fi
      printf '%s\n' "$rebase_output" >&2
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
