# ADR-0006: Low-maintenance automatic application updates

- Status: Accepted
- Date: 2026-08-27

## Context

The original update decision in [ADR-0004](0004-controlled-updates.md) chose
Renovate pull requests and human review for all workload image changes. That
was an appropriate initial reproducibility boundary while the application
contracts, health behavior, persistence, and recovery path were unknown.

The project now targets low-maintenance operation: stable application releases
should normally be detected and rolled out by Kubernetes with health checks and
recovery boundaries, while major or breaking upstream changes can still require
human intervention. This is bounded-risk automation, not an always-newest
promise.

## Decision

1. This ADR supersedes ADR-0004 only for application workload update
   mechanics. ADR-0004's reviewed/manual strategy remains the default for
   platform-level changes.
2. AIOStreams intentionally tracks the mutable stable image
   `ghcr.io/viren070/aiostreams:latest` with `imagePullPolicy: Always`. This is
   an explicit exception to the preference for immutable versioned tags. A
   future updater is expected to observe digest changes behind that tag.
3. Keel is the leading candidate for that future updater, but it is not
   deployed or approved by this milestone. Remux is early-stage 0.x software;
   its initial policy remains more conservative and must be validated later.
4. Automatic application updates require working startup/readiness/health
   checks, migration safety, persistence proof, failure testing, and a known
   previous-image recovery mechanism before they are enabled.
5. Mutable-tag rollback is a specific risk: rolling a Deployment back to an
   older ReplicaSet does not guarantee the old image bytes if a new Pod pulls
   the now-updated `latest` tag. A known prior immutable digest or another
   proven recovery strategy must be validated before AIOStreams automation.
6. No automatic rollback is claimed or implemented here. Failed migrations,
   breaking upstream behavior, storage recovery, and exceptional failures may
   still need a human.

## Platform boundary

Debian major upgrades, K3s upgrades, cert-manager upgrades, major Traefik or
other platform changes, storage architecture changes, and major authentication
changes remain deliberate reviewed maintenance events. Renovate remains useful
for review-driven infrastructure dependency awareness and is not removed.

## Consequences

Routine workload maintenance can become near-zero after the future gates pass,
but the system must preserve observable rollout status, durable application
state, and a tested recovery path. The mutable AIOStreams tag improves
upstream freshness but weakens tag-based reproducibility and makes rollback
design an explicit lifecycle requirement.

## Alternatives considered

- Keep human-reviewed PRs for every application image: rejected as the target
  operating model after workload-specific health and recovery evidence exists.
- Blind always-newest runtime updates: rejected because they omit bounded risk,
  migration gates, and recovery evidence.
- Deploy Keel immediately: rejected because this milestone establishes the
  workload boundary but does not yet test updater failure and rollback paths.
