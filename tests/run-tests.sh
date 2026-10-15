#!/usr/bin/env bash
# Test runner for the per-Fork sync entry point (scripts/sync-fork.sh).
#
# Plain bash; zero dependencies beyond git and jq. Every test exercises only
# the entry-point seam (spec issue #1, Testing Decisions): fixture bare
# remotes over file://, the script's exit code and stdout, the remotes'
# observable git state, and the fake gh's recorded invocations.
#
# Usage: tests/run-tests.sh [test function name ...]   (default: all tests)
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
TESTS_BIN="$here/bin"
SCRIPT="$root/scripts/sync-fork.sh"

. "$here/lib/fixtures.sh"

PASS=0
FAIL=0
FAILED=()

assert_rc() { # expected_rc actual_rc label
  [ "$2" -eq "$1" ] 2>/dev/null || {
    printf 'FAIL %s: expected exit code %s, got %s\n' "$3" "$1" "$2"
    return 1
  }
}

assert_eq() { # actual expected label
  [ "$1" = "$2" ] || {
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1"
    return 1
  }
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'FAIL %s: output did not contain "%s"\n  output: %s\n' "$3" "$2" "$1"
  return 1
}

assert_not_contains() { # haystack needle label
  case "$1" in
    *"$2"*)
      printf 'FAIL %s: output unexpectedly contained "%s"\n  output: %s\n' "$3" "$2" "$1"
      return 1
      ;;
  esac
}

assert_gh_not_called() { # label
  [ ! -s "$GH_SPY_LOG" ] || {
    printf 'FAIL %s: gh was called on a non-conflict run: %s\n' "$1" "$(cat "$GH_SPY_LOG")"
    return 1
  }
}

# Run the seam under test with one Fork's config (as the workflow's matrix
# step will) and the fake gh injected via PATH. Optional argument: extra
# config fields (a jq object) merged into the canonical config.
# FORK_SYNC_CENTER_REPO — the central management repo conflict issues are
# filed on — stays injectable so tests never touch the network (real wiring:
# ticket #6).
run_entry_point() { # [extra-config-json]
  local config
  config=$(jq -cn --arg fork "$FIX_FORK" --arg upstream "$FIX_UPSTREAM" \
    --argjson extra "${1:-null}" \
    '{fork: $fork, upstream: $upstream, base_branch: "main"} + ($extra // {})')
  export FORK_SYNC_CENTER_REPO="example/fork-sync-center"
  if ENTRY_OUTPUT=$(cd "$TEST_DIR" && PATH="$TESTS_BIN:$PATH" \
    "$SCRIPT" "$config" 2>&1); then
    ENTRY_STATUS=0
  else
    ENTRY_STATUS=$?
  fi
}

# Clone the Fork before the run so its pre-sync objects stay observable
# after the sync rewrites history.
clone_fork_observer() {
  git clone --quiet "$FIX_FORK" "$TEST_DIR/observe"
  OBSERVE="$TEST_DIR/observe"
  OBSERVED_PRE_HEAD=$(git -C "$OBSERVE" rev-parse refs/heads/main)
}

# Fetch the post-run base branch into the observer as refs/heads/after.
fetch_synced_base_branch() {
  git -C "$OBSERVE" fetch --quiet "$FIX_FORK" "refs/heads/main:refs/heads/after"
  SYNCED_HEAD=$(git -C "$OBSERVE" rev-parse refs/heads/after)
}

remote_sha() { # url ref — independent observation straight from a remote
  git ls-remote "$1" "$2" | cut -f1
}

test_syncs_fork_onto_sync_tag_with_rebased_own_commits() {
  local upstream_v132
  upstream_v132=$(remote_sha "$FIX_UPSTREAM" refs/tags/v1.3.2)
  clone_fork_observer

  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "sync exits 0"
  fetch_synced_base_branch

  # Linear history: the 4 Upstream commits plus the 2 Own Commits, no merges.
  assert_eq "$(git -C "$OBSERVE" rev-list --count refs/heads/after)" 6 \
    "history holds 4 Upstream commits + 2 rebased Own Commits"
  assert_eq "$(git -C "$OBSERVE" rev-list --count --merges refs/heads/after)" 0 \
    "history is linear (no merge commits)"

  # The Own Commits are rebased onto the Upstream's v1.3.2 commit, in order.
  assert_eq "$upstream_v132" "$(git -C "$OBSERVE" rev-parse refs/heads/after~2)" \
    "the commit under the Own Commits is the Sync Tag commit"
  assert_eq "Fork: first Own Commit" "$(git -C "$OBSERVE" log -1 --format=%s refs/heads/after~1)" \
    "first Own Commit preserved"
  assert_eq "Fork: second Own Commit" "$(git -C "$OBSERVE" log -1 --format=%s refs/heads/after)" \
    "second Own Commit preserved"

  # The base branch on the Fork remote is the rebased history, and the old
  # head is gone from it: the update could only land as a forced update.
  assert_eq "$(remote_sha "$FIX_FORK" refs/heads/main)" "$SYNCED_HEAD" \
    "base branch pushed to the Fork"
  if git -C "$OBSERVE" merge-base --is-ancestor "$OBSERVED_PRE_HEAD" refs/heads/after; then
    printf 'FAIL forced update: the old Fork head is still an ancestor of the synced head\n'
    return 1
  fi
}

test_marks_fork_head_by_force_moving_inherited_tag() {
  local upstream_v132
  upstream_v132=$(remote_sha "$FIX_UPSTREAM" refs/tags/v1.3.2)
  clone_fork_observer

  # Precondition: the Fork inherits v1.3.2 pointing at the Upstream's tagged
  # commit, which is not on the Fork's main.
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" "$upstream_v132" \
    "the Fork starts with an inherited v1.3.2 tag at the Upstream commit"
  if git -C "$OBSERVE" merge-base --is-ancestor "$upstream_v132" refs/heads/main; then
    printf 'FAIL fixture: the inherited tag target is already on the Fork main\n'
    return 1
  fi

  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "sync exits 0"
  fetch_synced_base_branch

  # The Mark: the same tag name now points at the Fork's own head.
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" "$SYNCED_HEAD" \
    "the Mark (v1.3.2) points at the Fork's own head"
  [ "$SYNCED_HEAD" != "$upstream_v132" ] || {
    printf 'FAIL the Mark was not moved off the Upstream commit\n'
    return 1
  }
}

test_reports_chosen_sync_tag() {
  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "sync exits 0"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the run reports the chosen Sync Tag"
}

test_leaves_upstream_untouched_and_never_notifies() {
  local upstream_before
  upstream_before=$(git ls-remote "$FIX_UPSTREAM")

  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "sync exits 0"

  assert_eq "$(git ls-remote "$FIX_UPSTREAM")" "$upstream_before" \
    "the Upstream remote is not mutated by the sync"
  assert_gh_not_called "a happy-path sync never touches the notification dependency"
}

test_conflict_aborts_all_fork_mutations_and_exits_nonzero() {
  local fork_before
  fork_before=$(git ls-remote "$FIX_FORK")

  run_entry_point
  if [ "$ENTRY_STATUS" -eq 0 ]; then
    printf 'FAIL conflict run: expected a non-zero exit code, got 0\n'
    return 1
  fi

  # ls-remote lists every branch and tag, so identical output proves the
  # aborted run moved nothing on the Fork remote.
  assert_eq "$(git ls-remote "$FIX_FORK")" "$fork_before" \
    "a conflicted run leaves the Fork's branches and tags byte-identical"
}

test_conflict_output_names_fork_sync_tag_and_conflicting_own_commits() {
  run_entry_point
  assert_contains "$ENTRY_OUTPUT" "$FIX_FORK" \
    "the conflict report identifies the Fork"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the conflict report identifies the Sync Tag"
  assert_contains "$ENTRY_OUTPUT" "Fork: conflicting Own Commit" \
    "the conflict report identifies the conflicting Own Commit"
}

test_conflict_files_issue_on_center_repo_when_none_is_open() {
  # No GH_FAKE_ISSUE_LIST staged: the fake gh reports no open issues.
  run_entry_point
  local spy
  spy=$(cat "$GH_SPY_LOG")
  assert_contains "$spy" "issue create --repo example/fork-sync-center" \
    "a conflict with no open issue files a new one on the central repo"
  assert_contains "$spy" "--title fork-sync conflict: $FIX_FORK onto v1.3.2" \
    "the issue title names the Fork and the Sync Tag"
  assert_contains "$spy" "Fork: conflicting Own Commit" \
    "the issue body names the conflicting Own Commit"
  assert_contains "$spy" "Close this issue" \
    "the issue body carries the remedy steps"
  assert_not_contains "$spy" "issue comment" \
    "no comment is posted when no issue is open"
}

test_conflict_comments_on_open_issue_instead_of_duplicating() {
  # Stage the open-issue state the fake gh reports: one open conflict issue
  # for this Fork, filed by an earlier conflicted run.
  printf '[{"number": 42, "title": "fork-sync conflict: %s onto v1.3.2"}]\n' \
    "$FIX_FORK" >"$TEST_DIR/gh-issue-list.json"
  export GH_FAKE_ISSUE_LIST="$TEST_DIR/gh-issue-list.json"

  run_entry_point
  local spy
  spy=$(cat "$GH_SPY_LOG")
  assert_contains "$spy" "issue list --repo example/fork-sync-center" \
    "discovery looks for open issues on the central repo"
  assert_contains "$spy" "$FIX_FORK in:title" \
    "discovery searches issue titles for this Fork"
  assert_contains "$spy" "issue comment 42 --repo example/fork-sync-center" \
    "an open issue for the Fork is commented on"
  assert_not_contains "$spy" "issue create" \
    "no duplicate issue is created while one is open"
}

test_noop_when_mark_already_points_at_base_head() {
  # The first sync Marks the Fork (v1.3.2 at main's head). A rerun before
  # any new Upstream tag must be a no-op: nothing pushed, no Mark changes.
  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "the first sync exits 0"
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" \
    "$(remote_sha "$FIX_FORK" refs/heads/main)" \
    "fixture: the Mark sits at the base branch head after the first sync"

  local fork_refs
  fork_refs=$(git ls-remote "$FIX_FORK")

  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "the rerun with no new tag exits 0"
  assert_eq "$(git ls-remote "$FIX_FORK")" "$fork_refs" \
    "the no-op pushes nothing: no ref on the Fork changes"
  assert_contains "$ENTRY_OUTPUT" "No-op" \
    "the no-op is clearly distinguished from a sync in the output"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the stable Sync Tag line survives for the status matrix"
  assert_gh_not_called "a no-op never notifies"
}

test_already_contains_refreshes_mark_leaving_history_untouched() {
  local upstream_v132
  upstream_v132=$(remote_sha "$FIX_UPSTREAM" refs/tags/v1.3.2)
  build_already_contains_scenario "$TEST_DIR"
  clone_fork_observer

  # Preconditions: the Fork's main already contains the Sync Tag (8 Upstream
  # commits + 2 Own Commits), and the inherited v1.3.2 still points at the
  # Upstream's commit.
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" "$upstream_v132" \
    "fixture: the Fork carries the inherited v1.3.2 at the Upstream commit"
  if ! git -C "$OBSERVE" merge-base --is-ancestor "$upstream_v132" refs/heads/main; then
    printf 'FAIL fixture: the Fork main does not contain the Sync Tag\n'
    return 1
  fi
  assert_eq "$(git -C "$OBSERVE" rev-list --count refs/heads/main)" 10 \
    "fixture: the Fork main holds 8 Upstream commits + 2 Own Commits"

  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "already-contains sync exits 0"

  # Forward-only: history untouched — the head is byte-identical, so no
  # rebase rewrote the Own Commits and no post-tag Upstream commit was lost.
  assert_eq "$(remote_sha "$FIX_FORK" refs/heads/main)" "$OBSERVED_PRE_HEAD" \
    "history untouched: the base branch head is byte-identical"
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" "$OBSERVED_PRE_HEAD" \
    "the Mark is refreshed at the Fork's head"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the run reports the chosen Sync Tag"
  assert_gh_not_called "a forward-only sync never notifies"
}

test_pure_fork_fast_forwards_to_sync_tag() {
  local upstream_v132 upstream_v131
  upstream_v132=$(remote_sha "$FIX_UPSTREAM" refs/tags/v1.3.2)
  upstream_v131=$(remote_sha "$FIX_UPSTREAM" refs/tags/v1.3.1)
  build_pure_fork_scenario "$TEST_DIR"
  clone_fork_observer

  assert_eq "$(remote_sha "$FIX_FORK" refs/heads/main)" "$upstream_v131" \
    "fixture: the pure Fork sits at v1.3.1 with zero Own Commits"

  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "pure-fork sync exits 0"

  # Fast-forward: the base branch lands exactly on the Sync Tag's commit —
  # no commit rewritten — and the old head stays inside the history.
  assert_eq "$(remote_sha "$FIX_FORK" refs/heads/main)" "$upstream_v132" \
    "the base branch fast-forwards to the Sync Tag's commit"
  fetch_synced_base_branch
  if ! git -C "$OBSERVE" merge-base --is-ancestor "$OBSERVED_PRE_HEAD" refs/heads/after; then
    printf 'FAIL fast-forward: the pre-sync head is not an ancestor of the synced head\n'
    return 1
  fi
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" "$upstream_v132" \
    "the Mark is created at the Sync Tag's commit, now the Fork's head"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the run reports the chosen Sync Tag"
  assert_gh_not_called "a pure-fork sync never notifies"
}

test_strict_mode_rewinds_post_tag_upstream_commits() {
  # Strict tag sync (forward_only: false, spec story 14): the Fork's main
  # already carries 4 post-tag Upstream commits plus 2 Own Commits. The sync
  # must rebase the Own Commits onto the Sync Tag anyway -- the post-tag
  # Upstream commits are rewound OUT of the Fork -- and Mark the rewound head.
  local upstream_v132 upstream_tip
  upstream_v132=$(remote_sha "$FIX_UPSTREAM" refs/tags/v1.3.2)
  upstream_tip=$(remote_sha "$FIX_UPSTREAM" refs/heads/main)
  build_already_contains_scenario "$TEST_DIR"
  clone_fork_observer

  run_entry_point '{"forward_only": false}'
  assert_rc 0 "$ENTRY_STATUS" "strict-mode sync exits 0"
  fetch_synced_base_branch

  assert_eq "$(git -C "$OBSERVE" rev-list --count refs/heads/after)" 6 \
    "history holds the 4 pre-tag Upstream commits + 2 rebased Own Commits"
  assert_eq "$upstream_v132" "$(git -C "$OBSERVE" rev-parse refs/heads/after~2)" \
    "the commit under the Own Commits is the Sync Tag commit"
  if git -C "$OBSERVE" merge-base --is-ancestor "$upstream_tip" refs/heads/after; then
    printf 'FAIL rewind: the post-tag Upstream tip is still an ancestor of the synced head\n'
    return 1
  fi
  assert_eq "Fork: first Own Commit" "$(git -C "$OBSERVE" log -1 --format=%s refs/heads/after~1)" \
    "first Own Commit preserved"
  assert_eq "Fork: second Own Commit" "$(git -C "$OBSERVE" log -1 --format=%s refs/heads/after)" \
    "second Own Commit preserved"
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" "$SYNCED_HEAD" \
    "the Mark (v1.3.2) points at the rewound Fork head"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the run reports the chosen Sync Tag"
  assert_gh_not_called "a strict-mode sync never notifies"
}

test_prerelease_tags_are_skipped_by_default() {
  # The canonical fixture carries v1.4.0-rc.1 above v1.3.2 (spec story 7):
  # selection must pick the greatest *stable* tag and never Mark a
  # prerelease on the Fork.
  run_entry_point
  assert_rc 0 "$ENTRY_STATUS" "sync with a newer prerelease present exits 0"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the greatest stable tag wins over the newer prerelease"
  [ -z "$(remote_sha "$FIX_FORK" refs/tags/v1.4.0-rc.1)" ] || {
    printf 'FAIL the skipped prerelease was Marked on the Fork\n'
    return 1
  }
  assert_gh_not_called "a stable sync never notifies"
}

test_upstream_without_tags_fails_loudly() {
  # Story 21: an Upstream with no tags at all is a configuration error. The
  # run must fail with a distinct message (not the prerelease-only failure)
  # and touch neither remote.
  local fork_refs
  build_tagless_upstream "$TEST_DIR"
  fork_refs=$(git ls-remote "$FIX_FORK")

  run_entry_point
  assert_rc 1 "$ENTRY_STATUS" "a tagless Upstream fails the run"
  assert_contains "$ENTRY_OUTPUT" "no tags at all" \
    "the configuration error is named precisely"
  assert_eq "$(git ls-remote "$FIX_FORK")" "$fork_refs" \
    "the failed run leaves the Fork untouched"
  assert_gh_not_called "a configuration error never notifies"
}

test_prerelease_only_upstream_fails_loudly() {
  # With prerelease skipping on (the default), an Upstream offering only
  # prereleases must fail the run — never silently skip the Fork — with a
  # message distinct from the tagless configuration error.
  local fork_refs
  build_prerelease_only_upstream "$TEST_DIR"
  fork_refs=$(git ls-remote "$FIX_FORK")

  run_entry_point
  assert_rc 1 "$ENTRY_STATUS" "a prerelease-only Upstream fails the run"
  assert_contains "$ENTRY_OUTPUT" "prereleases" \
    "the failure names the prerelease policy as the cause"
  assert_contains "$ENTRY_OUTPUT" "include_prereleases" \
    "the failure names the config field that flips the policy"
  assert_eq "$(git ls-remote "$FIX_FORK")" "$fork_refs" \
    "the failed run leaves the Fork untouched"
  assert_gh_not_called "a policy failure never notifies"
}

test_upstream_without_matching_prefix_fails_loudly() {
  # A prefix matching no tag is the same class of configuration error as a
  # tagless Upstream (distinct message), even though tags exist.
  local fork_refs
  fork_refs=$(git ls-remote "$FIX_FORK")

  run_entry_point '{"tag_prefix": "release-"}'
  assert_rc 1 "$ENTRY_STATUS" "a prefix matching no tag fails the run"
  assert_contains "$ENTRY_OUTPUT" "no stable tag with prefix 'release-'" \
    "the failure names the unmatched prefix"
  assert_eq "$(git ls-remote "$FIX_FORK")" "$fork_refs" \
    "the failed run leaves the Fork untouched"
  assert_gh_not_called "a configuration error never notifies"
}

test_include_prereleases_tracks_greatest_prerelease() {
  # With inclusion enabled, the greatest prerelease may win selection (spec
  # story 7's configurable flip side): v1.4.0-rc.1 beats the stable v1.3.2.
  local upstream_rc1
  upstream_rc1=$(remote_sha "$FIX_UPSTREAM" refs/tags/v1.4.0-rc.1)
  clone_fork_observer

  run_entry_point '{"include_prereleases": true}'
  assert_rc 0 "$ENTRY_STATUS" "sync onto a chosen prerelease exits 0"
  fetch_synced_base_branch

  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.4.0-rc.1" \
    "the greatest prerelease wins selection when included"
  assert_eq "$upstream_rc1" "$(git -C "$OBSERVE" rev-parse refs/heads/after~2)" \
    "the Own Commits are rebased onto the prerelease's commit"
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.4.0-rc.1)" "$SYNCED_HEAD" \
    "the Mark (v1.4.0-rc.1) points at the Fork's own head"
  assert_gh_not_called "a prerelease sync never notifies"
}

test_prefix_filters_tags_invisible_to_selection() {
  # Prefix filtering (spec story 6, "Implementation Decisions"): tags without
  # the configured prefix are invisible to selection. With prefix
  # "release-", the greater v9.9.9 and every other v-tag are ignored and
  # release-2.0.0 becomes the Sync Tag.
  local upstream_release200
  build_release_prefixed_upstream "$TEST_DIR"
  upstream_release200=$(remote_sha "$FIX_UPSTREAM" refs/tags/release-2.0.0)
  clone_fork_observer

  run_entry_point '{"tag_prefix": "release-"}'
  assert_rc 0 "$ENTRY_STATUS" "sync under a non-default prefix exits 0"
  fetch_synced_base_branch

  assert_contains "$ENTRY_OUTPUT" "Sync Tag: release-2.0.0" \
    "the greatest prefix-matching tag wins"
  assert_eq "$upstream_release200" "$(git -C "$OBSERVE" rev-parse refs/heads/after~2)" \
    "the Own Commits are rebased onto the release-prefixed Sync Tag's commit"
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/release-2.0.0)" "$SYNCED_HEAD" \
    "the Mark (release-2.0.0) points at the Fork's own head"
  [ -z "$(remote_sha "$FIX_FORK" refs/tags/v9.9.9)" ] || {
    printf 'FAIL a prefix-mismatched tag was Marked on the Fork\n'
    return 1
  }
  assert_gh_not_called "a prefixed sync never notifies"
}

TESTS=(
  test_syncs_fork_onto_sync_tag_with_rebased_own_commits
  test_marks_fork_head_by_force_moving_inherited_tag
  test_reports_chosen_sync_tag
  test_leaves_upstream_untouched_and_never_notifies
  test_noop_when_mark_already_points_at_base_head
  test_already_contains_refreshes_mark_leaving_history_untouched
  test_strict_mode_rewinds_post_tag_upstream_commits
  test_prerelease_tags_are_skipped_by_default
  test_upstream_without_tags_fails_loudly
  test_prerelease_only_upstream_fails_loudly
  test_upstream_without_matching_prefix_fails_loudly
  test_include_prereleases_tracks_greatest_prerelease
  test_prefix_filters_tags_invisible_to_selection
  test_pure_fork_fast_forwards_to_sync_tag
)

# Conflict-path tests run against the rebase-conflict fixture variant.
CONFLICT_TESTS=(
  test_conflict_aborts_all_fork_mutations_and_exits_nonzero
  test_conflict_output_names_fork_sync_tag_and_conflicting_own_commits
  test_conflict_files_issue_on_center_repo_when_none_is_open
  test_conflict_comments_on_open_issue_instead_of_duplicating
)

# builder_for <test-name> — the fixture variant a test runs against (the
# runner's default is the canonical scenario; conflict tests are listed in
# CONFLICT_TESTS).
builder_for() {
  local name
  for name in "${CONFLICT_TESTS[@]}"; do
    if [ "$name" = "$1" ]; then
      printf 'build_conflict_scenario\n'
      return
    fi
  done
  printf 'build_canonical_scenario\n'
}

run_test() {
  local name=$1 builder=${2:-build_canonical_scenario} dir out rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fork-sync-test.XXXXXX")
  printf -- '--- %s\n' "$name"
  # The group runs inside command substitution, NOT in an if-condition: bash
  # ignores `set -e` in a subshell used as a condition, which would turn any
  # failing assertion after the first into a silent pass.
  out=$({
    set -e
    # Hermetic: ignore the host's git config (signing, editors, insteadOf)
    # so fixtures rebuild identically on any machine.
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_EDITOR=true EDITOR=true
    TEST_DIR=$dir
    GH_SPY_LOG=$dir/gh-calls.log
    export GH_SPY_LOG
    : >"$GH_SPY_LOG"
    "$builder" "$dir"
    "$name"
  } 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'PASS %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL %s\n' "$name"
    printf '%s\n' "$out"
    FAIL=$((FAIL + 1))
    FAILED+=("$name")
  fi
  rm -rf "$dir"
}

main() {
  local name
  if [ "$#" -gt 0 ]; then
    for name in "$@"; do run_test "$name" "$(builder_for "$name")"; done
  else
    for name in "${TESTS[@]}"; do run_test "$name" "$(builder_for "$name")"; done
    for name in "${CONFLICT_TESTS[@]}"; do run_test "$name" build_conflict_scenario; done
  fi
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -ne 0 ]; then
    printf 'failed tests: %s\n' "${FAILED[*]}"
    exit 1
  fi
}

main "$@"
