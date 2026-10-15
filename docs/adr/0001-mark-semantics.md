# ADR-0001: The Mark reuses the Sync Tag's name on the Fork

## Status

Accepted. Implements the spec (issue #1, "Further Notes") for ticket #2.

## Context

After a sync, the Fork's base branch is the Sync Tag plus the Fork's Own
Commits. The Fork usually already carries a tag with the Sync Tag's name as an
*inherited* Upstream tag, pointing at the Upstream's tagged commit (fetched at
fork time or by a later `git fetch --tags`). The system needs a durable record
on the Fork of "this Fork is synced onto that Upstream release", and later
tickets need to read that record for no-op detection.

Two options were considered:

1. **A new tag name** (e.g. `fork/v1.3.2` or `synced/v1.3.2`) pointing at the
   Fork's own head, leaving the inherited Upstream tag untouched.
2. **Reuse the Sync Tag's name**, force-creating or force-moving that tag on
   the Fork so it points at the Fork's own head.

## Decision

We reuse the Sync Tag's name. The **Mark** is a tag on the Fork named exactly
like the Sync Tag, force-created or force-moved to point at the Fork's own
base-branch head after the rebase, and pushed with force. An inherited
Upstream tag of that name is deliberately overwritten.

## Consequences

- On the Fork, `git rev-parse v1.3.2` answers "where is my synced v1.3.2" —
  one name, one answer, no new vocabulary for Fork owners to learn or for
  no-op detection (later ticket) to look up.
- The tag name no longer identifies the Upstream's commit on the Fork: the
  same tag name names different objects in the two repositories. Anyone
  comparing tags across Upstream and Fork must expect this.
- The move is hard to reverse: once the force-pushed tag is public, existing
  checkouts of the Fork keep the moved tag and a revert cannot recall it
  (their `git fetch` will refuse to clobber it back).
- Only the latest Sync Tag is Marked; intermediate Upstream releases between
  two runs get no Mark on the Fork (spec: "Only the latest tag is synced").

The trade-off was accepted because the Fork is the release surface its owner
cares about: a release tag on the Fork should reflect the Fork's code, not the
Upstream's commit.
