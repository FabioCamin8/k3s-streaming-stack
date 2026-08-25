# ADR-0004: Controlled updates

- Status: Accepted
- Date: 2026-08-25

## Context

Image updates can change application behavior, storage formats, ports, and authentication. Remux is early-stage software and may introduce breaking changes. A runtime updater would reduce reproducibility and make rollback and audit more difficult.

## Decision

Use Renovate to propose understandable pull requests for Kubernetes image references. Require review, verification, and an intentional merge before Kubernetes rolls out an update. Do not enable automerge initially.

## Consequences

The update path has an audit trail and a deliberate rollback point. Operators must spend time reviewing and validating updates, and a vulnerable release may require an explicit urgent PR rather than an invisible background change.

## Alternatives considered

- Watchtower or another blind runtime updater: rejected because it bypasses review and weakens reproducibility.
- Manual edits only: rejected because drift and missed upstream releases become harder to see.
- Automatic Renovate merging: deferred until workload-specific evidence and rollback confidence justify it, with Remux remaining excluded from that decision for now.
