# Working in this repository

For hosted PR reviews, follow `Code Review Rules` below without running the local
skills refresh. For other tasks, run `just skills-sync` from the repository root.
Read `skills/origin89-working/SKILL.md` and the relevant domain skills under the
immutable `path` printed by that command. Keep that snapshot for the task; do not
refresh it halfway through work. Before branch, commit, push, or PR operations,
read `skills/origin89-commits/SKILL.md` from that snapshot. Read local instructions
and preserve stronger project constraints and project-specific skills.

If refresh reports cached content, continue with that verified cache and mention
that the script could not check for updates. If no cache is available or
validation fails, report the error; do not claim the shared rules loaded. Local
instructions and the user's request still apply. Do not overwrite local skill
files to fix a conflict without reconciling them.

[Origin89 engineering](https://github.com/origin89hq/engineering) owns the shared
rules. Keep only repository-specific architecture, commands, target constraints,
and exceptions below. Internal RFCs and research belong in
[internal-research](https://github.com/origin89hq/internal-research). Add documentation
only when its value and upkeep are clear; remove AI filler from every message.

Confirmed problems left outside the current fix need an issue in the owning
repository: search with `gh`, reuse a matching issue or create one with evidence,
and return its URL. Follow the shared working skill's unfinished-work rule.
Respect posting restrictions; if filing is blocked, provide the draft and say why.
Finish authorized fixes instead of replacing them with backlog issues.

## Project

The native SwiftUI iOS target is in `apps/ios/`. Use `just --list` for commands
and `just check` for the unsigned simulator build and Swift formatting check.
The checked-in Xcode project is authoritative. Add other app directories only
when their implementation starts. Keep signing credentials and team IDs local.

The current scope is scaffolding only. Do not add connection, pairing, protocol,
or equipment-control behavior without a feature request.

## Code Review Rules

Read the shared `origin89-review` skill and relevant domain skills when available.
In hosted review jobs that already provide `.origin89/engineering/skills/`, use
that checkout without running the local refresh. If shared context is missing,
review against the rules below and disclose that limit.

- Flag changes that bypass authorization, lose data or provenance, break a
  supported contract, or turn unknown or stale equipment input into permission
  to act. Check callers and existing guards before reporting a defect.
- Require meaningful success, invalid-input, boundary, and failure coverage for
  changed nontrivial behavior. Respect simpler contracts with fewer paths;
  hazardous behavior needs its full fault matrix and relevant bench evidence.
- For Rust domain logic, prefer typed state, errors, units, and identifiers.
  Strings at text boundaries are expected; flag strings that discard useful
  invariants or leave invalid domain states representable.
- Report the trigger, consequence, and precise location. Distinguish checks run
  from missing evidence. Leave formatting to the configured linters, and avoid
  duplicate or speculative findings. A review request does not authorize implementation.
- Keep current PR defects in the review. Track confirmed pre-existing or explicitly
  deferred problems as issues when filing is authorized; comments-only reviewers
  provide a draft and state that it was not filed.

- Treat simulator builds as compile evidence only; BLE and controller acceptance
  require physical-device checks. Keep controller authorization authoritative.
- Preserve the iOS 17 deployment target and Swift 6 language mode unless a
  compatibility change is intentional and documented.
