#!/usr/bin/env python3
"""manifest-to-matrix.py — the manifest → per-Fork-config transform (spec
issue #1, "Manifest consumption"; ticket #6).

Parses forks.yml ONCE with PyYAML (preinstalled on GitHub's ubuntu runners),
merges global defaults with per-Fork overrides (per-Fork wins), and prints
one compact JSON array — one object per Fork, in manifest order, exactly the
config contract scripts/sync-fork.sh consumes:

  {"fork": "<url>", "upstream": "<url>", "base_branch": "main",
   "tag_prefix": "v", "forward_only": true, "include_prereleases": false}

The workflow's setup job exports the array as its matrix output; the sync job
expands over it and passes exactly one element to scripts/sync-fork.sh.

Schema (single source for the shape: docs/deploying.md):
  defaults:  optional mapping — any of the three policy fields
  forks:     required list of Fork entries; [] is valid (the workflow's
             matrix job is skipped for an empty array)
  entry:     fork, upstream, base_branch — required, non-empty strings;
             tag_prefix / forward_only / include_prereleases — optional
             overrides of the merged default
Merging: built-in defaults <- manifest defaults <- entry (entry wins). A
field explicitly set to null counts as unset. Validation is strict:
unknown keys (at any level) and type errors fail the run — a typo like
`forward-only` would otherwise silently fall back to a default.

Usage: manifest-to-matrix.py <forks.yml>
Exit: 0 with the array on stdout; 1 with a diagnostic on stderr.
"""

import json
import sys

import yaml

# The built-in defaults. A manifest's `defaults` block (and then a Fork
# entry) overrides these; nothing else may introduce policy.
BUILTIN_DEFAULTS = {
    "tag_prefix": "v",
    "forward_only": True,
    "include_prereleases": False,
}
# The overridable policy fields, in the entry script's documented key order.
# tag_prefix: string ("" is valid — every semver tag matches, no prefix).
# forward_only / include_prereleases: boolean.
POLICY_FIELDS = {
    "tag_prefix": str,
    "forward_only": bool,
    "include_prereleases": bool,
}
REQUIRED_FIELDS = ("fork", "upstream", "base_branch")


def fail(message):
    print(f"manifest-to-matrix: {message}", file=sys.stderr)
    sys.exit(1)


def describe(value):
    """A YAML-accurate name for a wrong-typed value in diagnostics."""
    names = {
        str: "a string",
        bool: "a boolean",
        int: "a number",
        float: "a number",
        list: "a list",
        dict: "a mapping",
    }
    if value is None:
        return "null"
    return names.get(type(value), type(value).__name__)


def check_type(scope, field, value, expected):
    if type(value) is not expected:
        expected_name = {str: "a string", bool: "a boolean"}[expected]
        fail(f"{scope}: '{field}' must be {expected_name}, "
             f"got {describe(value)}")


def unknown_fields(keys, known):
    """A sorted, quoted list of any keys outside `known`, for a diagnostic."""
    extra = sorted(set(keys) - set(known))
    return ", ".join(f"'{field}'" for field in extra)


def merged_defaults(manifest):
    defaults = dict(BUILTIN_DEFAULTS)
    declared = manifest.get("defaults")
    if declared is None:
        return defaults
    if not isinstance(declared, dict):
        fail("defaults: must be a mapping of policy fields "
             "(tag_prefix, forward_only, include_prereleases)")
    unknown = unknown_fields(declared, POLICY_FIELDS)
    if unknown:
        fail(f"defaults: unknown field {unknown} "
             f"(expected one of: tag_prefix, forward_only, "
             "include_prereleases)")
    for field, expected in POLICY_FIELDS.items():
        if declared.get(field) is not None:
            check_type("defaults", field, declared[field], expected)
            defaults[field] = declared[field]
    return defaults


def main(argv):
    if len(argv) != 2:
        fail("usage: manifest-to-matrix.py <forks.yml>")
    try:
        with open(argv[1], encoding="utf-8") as handle:
            manifest = yaml.safe_load(handle)
    except OSError as exc:
        fail(f"cannot read manifest {argv[1]}: {exc.strerror}")
    except yaml.YAMLError as exc:
        fail(f"{argv[1]} is not valid YAML: {exc}")

    if not isinstance(manifest, dict):
        fail(f"{argv[1]} must be a YAML mapping with 'defaults' and 'forks'")

    # Unknown keys first: a typo like `fork:` explains an apparently
    # missing 'forks' key, so lead with the more revealing diagnostic.
    unknown = unknown_fields(manifest, ("defaults", "forks"))
    if unknown:
        fail(f"unknown top-level key {unknown} (expected 'defaults', 'forks')")

    if "forks" not in manifest:
        fail(f"{argv[1]}: missing required key 'forks' (the list of Fork entries)")
    if not isinstance(manifest["forks"], list):
        fail("forks: must be a list of Fork entries")

    defaults = merged_defaults(manifest)

    configs = []
    for index, entry in enumerate(manifest["forks"]):
        scope = f"forks[{index}]"
        if not isinstance(entry, dict):
            fail(f"{scope}: must be a mapping of Fork fields, "
                 f"got {describe(entry)}")
        unknown = unknown_fields(entry,
                                 REQUIRED_FIELDS + tuple(POLICY_FIELDS))
        if unknown:
            fail(f"{scope}: unknown field {unknown} "
                 f"(required: fork, upstream, base_branch; optional: "
                 "tag_prefix, forward_only, include_prereleases)")
        config = {}
        for field in REQUIRED_FIELDS:
            if entry.get(field) is None:
                fail(f"{scope}: missing required field '{field}' "
                     f"(required: fork, upstream, base_branch)")
            value = entry[field]
            if type(value) is not str or not value:
                fail(f"{scope}: '{field}' must be a non-empty string, "
                     f"got {describe(value)}")
            config[field] = value
        for field, expected in POLICY_FIELDS.items():
            value = entry.get(field)
            if value is None:  # unset (or explicit null): the default wins
                config[field] = defaults[field]
            else:
                check_type(scope, field, value, expected)
                config[field] = value
        configs.append(config)

    print(json.dumps(configs, separators=(",", ":")))


main(sys.argv)
