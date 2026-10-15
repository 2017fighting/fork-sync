# fork-sync

Keeps a fork's main up to date with the upstream's stable releases (tags), while
preserving the fork's own commits.

## Language

**Upstream**:
The original repository (A) that the fork was created from; the source of
stable release tags.
_Avoid_: origin (ambiguous), source repo

**Fork**:
The user's repository (B) that tracks Upstream's releases and carries its own
commits on top.
_Avoid_: downstream, clone

**Sync Tag**:
The Upstream release tag chosen as the sync target for one run.
_Avoid_: latest tag (imprecise), target tag

**Own Commits**:
Commits reachable from the Fork's main but not from Upstream's main.
_Avoid_: local commits, custom commits, patches

**Forward-only**:
The sync policy where the Fork never moves backward in Upstream history: if the
Fork already contains the Sync Tag, the run only re-marks it. The opposite
policy (strict tag sync) may rewind post-tag Upstream commits out of the Fork.
_Avoid_: no-rollback (vague)

**Mark**:
Creating (or force-moving) a tag on the Fork's main with the Sync Tag's name,
recording "this Fork is synced onto that Upstream release".
_Avoid_: re-tag, mirror tag
