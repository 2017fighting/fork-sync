# shellcheck shell=bash
# Manifest-transform tests (ticket #6; spec issue #1, "Manifest
# consumption"): scripts/manifest-to-matrix.py is the manifest → per-Fork-JSON
# seam. Each test writes a forks.yml, runs the transform, and asserts on its
# exit code, its combined output, and the JSON array it prints — the exact
# string the workflow's setup job exports as its matrix output.
#
# The runner sources this file. The whole suite is gated on python3 + PyYAML
# (the GitHub runner has PyYAML preinstalled; elsewhere the runner prints one
# explicit SKIP line per test). The two tests at the bottom pin the shipped
# forks.yml and the workflow YAML itself.

MANIFEST_SCRIPT="$root/scripts/manifest-to-matrix.py"

MANIFEST_TESTS=(
  test_manifest_merges_defaults_with_per_fork_overrides
  test_manifest_defaults_are_optional
  test_manifest_missing_required_field_fails
  test_manifest_type_errors_fail
  test_manifest_unknown_keys_fail
  test_manifest_empty_forks_list_emits_empty_matrix
  test_manifest_missing_forks_key_fails
  test_manifest_invalid_yaml_fails
  test_workflow_and_manifest_yaml_are_well_formed
  test_workflow_wires_exactly_one_authorization_header
  test_shipped_forks_yml_validates
)

# Transform tests that also need the canonical git fixtures (the entry-point
# glue test drives a real sync from a matrix element).
MANIFEST_CANONICAL_TESTS=(
  test_matrix_element_config_drives_the_entry_point
)

write_manifest() { # <dir> — YAML from stdin into <dir>/forks.yml
  cat >"$1/forks.yml"
}

run_transform() { # <manifest-path> — exit status and combined output
  if MANIFEST_OUTPUT=$(python3 "$MANIFEST_SCRIPT" "$1" 2>&1); then
    MANIFEST_STATUS=0
  else
    MANIFEST_STATUS=$?
  fi
}

test_manifest_merges_defaults_with_per_fork_overrides() {
  write_manifest "$TEST_DIR" <<'YAML'
defaults:
  tag_prefix: "release-"
  forward_only: false
  include_prereleases: true
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
  - fork: "https://github.com/acme/gadget-fork.git"
    upstream: "https://github.com/acme/gadget.git"
    base_branch: "develop"
    tag_prefix: "v"
    forward_only: true
    include_prereleases: false
YAML

  run_transform "$TEST_DIR/forks.yml"
  assert_rc 0 "$MANIFEST_STATUS" "a valid manifest exits 0"
  # Expected written by hand from the manifest above (independent of the
  # implementation): the first Fork inherits every default, the second
  # overrides all three — per-Fork wins. Key order is the entry script's
  # documented config contract; manifest order is preserved.
  assert_eq "$MANIFEST_OUTPUT" \
    '[{"fork":"https://github.com/acme/widget-fork.git","upstream":"https://github.com/acme/widget.git","base_branch":"main","tag_prefix":"release-","forward_only":false,"include_prereleases":true},{"fork":"https://github.com/acme/gadget-fork.git","upstream":"https://github.com/acme/gadget.git","base_branch":"develop","tag_prefix":"v","forward_only":true,"include_prereleases":false}]' \
    "defaults merge in, per-Fork overrides win, manifest order preserved"
}

test_manifest_defaults_are_optional() {
  write_manifest "$TEST_DIR" <<'YAML'
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
YAML

  run_transform "$TEST_DIR/forks.yml"
  assert_rc 0 "$MANIFEST_STATUS" "a manifest without a defaults block exits 0"
  # The spec's built-in defaults (spec issue #1): forward-only on, prefix
  # "v", prereleases skipped.
  assert_eq "$MANIFEST_OUTPUT" \
    '[{"fork":"https://github.com/acme/widget-fork.git","upstream":"https://github.com/acme/widget.git","base_branch":"main","tag_prefix":"v","forward_only":true,"include_prereleases":false}]' \
    "the built-in defaults fill every policy field"
}

test_manifest_missing_required_field_fails() {
  # The second entry is missing its upstream: a misconfiguration that must
  # surface at setup time, naming the field and the offending entry.
  write_manifest "$TEST_DIR" <<'YAML'
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
  - fork: "https://github.com/acme/gadget-fork.git"
    base_branch: "main"
YAML

  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "an entry missing a required field fails"
  assert_contains "$MANIFEST_OUTPUT" "forks[1]" \
    "the diagnostic names the offending entry by index"
  assert_contains "$MANIFEST_OUTPUT" "'upstream'" \
    "the diagnostic names the missing field"
  assert_contains "$MANIFEST_OUTPUT" "missing required field" \
    "the diagnostic says what is wrong"
}

test_manifest_type_errors_fail() {
  write_manifest "$TEST_DIR" <<'YAML'
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
    forward_only: "yes-please"
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "a string where a boolean belongs fails"
  assert_contains "$MANIFEST_OUTPUT" "'forward_only' must be a boolean" \
    "the diagnostic names the field and its expected type"
  assert_contains "$MANIFEST_OUTPUT" "a string" \
    "the diagnostic names the offending type"

  write_manifest "$TEST_DIR" <<'YAML'
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
    tag_prefix: 7
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "a number where a string belongs fails"
  assert_contains "$MANIFEST_OUTPUT" "'tag_prefix' must be a string" \
    "the diagnostic names the field and its expected type"

  write_manifest "$TEST_DIR" <<'YAML'
defaults:
  include_prereleases: "true"
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "a type error in defaults fails"
  assert_contains "$MANIFEST_OUTPUT" "defaults: 'include_prereleases' must be a boolean" \
    "the diagnostic names the defaults block as the offending scope"

  write_manifest "$TEST_DIR" <<'YAML'
forks:
  - "https://github.com/acme/widget-fork.git"
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "an entry that is not a mapping fails"
  assert_contains "$MANIFEST_OUTPUT" "forks[0]: must be a mapping" \
    "the diagnostic names the entry's expected shape"

  write_manifest "$TEST_DIR" <<'YAML'
defaults:
  - forward_only: true
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "a non-mapping defaults block fails"
  assert_contains "$MANIFEST_OUTPUT" "defaults: must be a mapping" \
    "the diagnostic names the defaults block's expected shape"
}

test_manifest_unknown_keys_fail() {
  # Strict by choice (documented in the script and docs/deploying.md): a
  # hand-edited manifest with a typo like `forward-only` would otherwise
  # silently fall back to the default and mis-sync the Fork.
  write_manifest "$TEST_DIR" <<'YAML'
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
    forward-only: false
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "an unknown field in an entry fails"
  assert_contains "$MANIFEST_OUTPUT" "forks[0]: unknown field 'forward-only'" \
    "the diagnostic names the entry and the unknown field"

  write_manifest "$TEST_DIR" <<'YAML'
defaults:
  forward_only: true
  include_prerelease: false
forks:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "an unknown field in defaults fails"
  assert_contains "$MANIFEST_OUTPUT" "defaults: unknown field 'include_prerelease'" \
    "the diagnostic names the defaults scope and the unknown field"

  write_manifest "$TEST_DIR" <<'YAML'
fork:
  - fork: "https://github.com/acme/widget-fork.git"
    upstream: "https://github.com/acme/widget.git"
    base_branch: "main"
YAML
  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "an unknown top-level key fails"
  assert_contains "$MANIFEST_OUTPUT" "unknown top-level key 'fork'" \
    "the diagnostic names the top-level typo (forks misspelled)"
}

test_manifest_empty_forks_list_emits_empty_matrix() {
  # An explicitly empty manifest is a valid transitional state (a freshly
  # deployed repo before its first real Fork): the transform emits an empty
  # matrix and GitHub Actions skips the sync job for an empty array.
  write_manifest "$TEST_DIR" <<'YAML'
forks: []
YAML

  run_transform "$TEST_DIR/forks.yml"
  assert_rc 0 "$MANIFEST_STATUS" "an empty forks list exits 0"
  assert_eq "$MANIFEST_OUTPUT" "[]" \
    "an empty forks list emits an empty JSON array"
}

test_manifest_missing_forks_key_fails() {
  # Omitting the forks list entirely is a broken manifest (unlike an empty
  # one): the file's whole purpose is the list.
  write_manifest "$TEST_DIR" <<'YAML'
defaults:
  forward_only: true
YAML

  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "a manifest without a forks key fails"
  assert_contains "$MANIFEST_OUTPUT" "missing required key 'forks'" \
    "the diagnostic names the missing key"
}

test_manifest_invalid_yaml_fails() {
  write_manifest "$TEST_DIR" <<'YAML'
forks:
  - fork: "https://github.com/acme/widget-fork.git"
   upstream: "https://github.com/acme/widget.git"
YAML

  run_transform "$TEST_DIR/forks.yml"
  assert_rc 1 "$MANIFEST_STATUS" "a syntactically invalid manifest fails"
  assert_contains "$MANIFEST_OUTPUT" "not valid YAML" \
    "the diagnostic says the file failed to parse"
}

# The glue between the two seams (ticket #6): the matrix element the
# transform emits is exactly the config the entry point consumes. Drives a
# real sync over the canonical file:// fixtures from transform output to the
# Mark on the Fork remote.
test_matrix_element_config_drives_the_entry_point() {
  clone_fork_observer
  write_manifest "$TEST_DIR" <<YAML
forks:
  - fork: "$FIX_FORK"
    upstream: "$FIX_UPSTREAM"
    base_branch: "main"
YAML

  run_transform "$TEST_DIR/forks.yml"
  assert_rc 0 "$MANIFEST_STATUS" "the manifest transform exits 0"
  local config
  config=$(jq -c '.[0]' <<<"$MANIFEST_OUTPUT")

  export FORK_SYNC_CENTER_REPO="example/fork-sync-center"
  if ENTRY_OUTPUT=$(cd "$TEST_DIR" && PATH="$TESTS_BIN:$PATH" \
    "$SCRIPT" "$config" 2>&1); then
    ENTRY_STATUS=0
  else
    ENTRY_STATUS=$?
  fi
  assert_rc 0 "$ENTRY_STATUS" \
    "the entry point syncs from a matrix element as the workflow passes it"
  assert_contains "$ENTRY_OUTPUT" "Sync Tag: v1.3.2" \
    "the sync reports the Sync Tag"
  fetch_synced_base_branch
  assert_eq "$(remote_sha "$FIX_FORK" refs/tags/v1.3.2)" "$SYNCED_HEAD" \
    "the Mark (v1.3.2) points at the Fork's own head"
  assert_gh_not_called "a happy-path sync never notifies"
}

# The shipped YAML files must at least parse (task #6: the workflow itself
# is verified by linting/inspection — this only guards against shipping
# syntactically broken YAML).
test_workflow_and_manifest_yaml_are_well_formed() {
  python3 - "$root/.github/workflows/sync-forks.yml" "$root/forks.yml" <<'PY'
import sys
import yaml

ok = True
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except OSError as exc:
        print(f"{path} is unreadable: {exc}")
        ok = False
        continue
    except yaml.YAMLError as exc:
        print(f"{path} is not well-formed YAML: {exc}")
        ok = False
        continue
    if not isinstance(document, dict):
        print(f"{path} is not a YAML mapping")
        ok = False
sys.exit(0 if ok else 1)
PY
}

# Regression pin (run 38699330127): actions/checkout persists its own
# GITHUB_TOKEN as a LOCAL http extraheader, and the workflow added a GLOBAL
# one for the PAT. Git then sent two Authorization headers and GitHub
# rejected every fetch with a 400 "Duplicate header: Authorization" — so
# each Fork failed before its Upstream was ever read. Exactly one
# Authorization header must reach github.com: checkout must not persist a
# credential, any leftover extraheader must be dropped, and the PAT must be
# installed with --replace-all (appending a second value to the key would
# reintroduce the duplicate).
test_workflow_wires_exactly_one_authorization_header() {
  python3 - "$root/.github/workflows/sync-forks.yml" <<'PY'
import re
import sys

import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

problems = []
steps = workflow["jobs"]["sync"]["steps"]

checkout = next(
    (step for step in steps if str(step.get("uses", "")).startswith("actions/checkout")),
    None,
)
if checkout is None:
    problems.append("the sync job has no actions/checkout step")
else:
    persisted = (checkout.get("with") or {}).get("persist-credentials")
    if persisted is not False:
        problems.append(
            "actions/checkout must set persist-credentials: false in the sync "
            "job, or it leaves its own Authorization extraheader behind "
            f"(found {persisted!r})"
        )

sync = next((step for step in steps if step.get("name") == "Sync one Fork"), None)
if sync is None:
    problems.append("the sync job has no 'Sync one Fork' step")
else:
    run = sync.get("run", "")
    # Flatten line continuations and whitespace runs so the pins below assert
    # the command sequence, not how the YAML author wrapped the lines.
    flat = re.sub(r"\\\n\s*", " ", run)
    flat = re.sub(r"[ \t]+", " ", flat)
    unset = re.search(
        r"git config --local --unset-all http\.https://github\.com/\.extraheader [^|]*\|\| true",
        flat,
    )
    install = re.search(
        r"git config --global --replace-all http\.https://github\.com/\.extraheader",
        flat,
    )
    if unset is None:
        problems.append(
            "the sync step must drop any persisted extraheader first "
            "('git config --local --unset-all ... || true')"
        )
    if install is None:
        problems.append(
            "the sync step must install the PAT with --replace-all, never by "
            "appending a second value to the extraheader key"
        )
    if unset and install and unset.start() > install.start():
        problems.append("the extraheader must be unset before the PAT is installed")

for problem in problems:
    print(f"{path}: {problem}")
sys.exit(1 if problems else 0)
PY
}

# The shipped manifest is live configuration (real Forks), so it is not pinned
# to specific entries: what must hold is that it validates and that every entry
# resolves to the full per-Fork contract with the documented defaults applied —
# exactly the JSON the workflow's setup job hands the entry script.
test_shipped_forks_yml_validates() {
  run_transform "$root/forks.yml"
  assert_rc 0 "$MANIFEST_STATUS" "the shipped manifest validates"
  python3 - "$MANIFEST_OUTPUT" <<'PY'
import json
import sys

configs = json.loads(sys.argv[1])
contract = [
    "fork",
    "upstream",
    "base_branch",
    "tag_prefix",
    "forward_only",
    "include_prereleases",
]

problems = []
if not configs:
    problems.append("the shipped manifest declares no Forks")
for config in configs:
    name = config.get("fork", "<entry without fork>")
    if sorted(config) != sorted(contract):
        problems.append(f"{name}: keys are {sorted(config)}, expected {sorted(contract)}")
        continue
    if not all(str(config[field]).startswith("https://") for field in ("fork", "upstream")):
        problems.append(f"{name}: fork and upstream must be https URLs")
    if not isinstance(config["forward_only"], bool) or not isinstance(
        config["include_prereleases"], bool
    ):
        problems.append(f"{name}: forward_only and include_prereleases must be booleans")
    if not isinstance(config["tag_prefix"], str):
        problems.append(f"{name}: tag_prefix must be a string")
    if not isinstance(config["base_branch"], str) or not config["base_branch"]:
        problems.append(f"{name}: base_branch must be a non-empty string")

for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
PY
}
