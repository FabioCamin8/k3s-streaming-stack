# ADR-0007: Selective human authentication

- Status: Accepted
- Date: 2026-08-28

## Context

The stack has two different authentication classes. AIOStreams and Remux have
browser/admin surfaces, but they also expose Stremio and Jellyfin-compatible
machine protocols whose clients must not be forced through a browser login.
The project needs stronger human authentication without breaking discovery,
playback, API, bootstrap, or WebSocket behavior.

## Decision

Use the pinned `ghcr.io/authelia/authelia:4.39.20` release as one
SQLite-backed, file-user authentication service with TOTP-capable two-factor
authentication. Keep its users file, encryption/signing material, OIDC client
hash, database, notification file, and MFA state outside Git and on a
persistent local-path volume.

Federate AIOStreams' human configuration/admin login through AIOStreams'
native OIDC client. Keep AIOStreams native login enabled as the recovery path,
disable automatic provider redirect during rollout, and map only the Authelia
`admins` group to the AIOStreams `admin` permission.

Attach Authelia ForwardAuth only to a separate Remux `/admin` Ingress. Keep the
main Remux Ingress free of ForwardAuth so Jellyfin-native login/API, health,
bootstrap, playback, internal addon requests, and WebSocket paths retain their
existing protocol authentication.

Do not change WAN forwarding as part of this decision. The provider and proxy
must be tested through the existing Traefik/TLS path before this architecture
is treated as live.

## Consequences

This preserves machine-client compatibility and gives human/admin paths a
single two-factor-capable identity boundary. The tradeoffs are a single-node,
non-HA SQLite/session design, an Authelia OIDC provider whose maturity boundary
must be reviewed on upgrades, and an additional operator secret lifecycle.
Local-path PVC persistence is not an off-node backup.

The pinned Authelia release's tagged schema does not expose the newer
`server.trusted_proxies` field; the deployment does not invent it. Forwarded
host/protocol behavior and any future edge proxying remain live validation and
configuration work.

## Alternatives considered

- Blanket ForwardAuth on AIOStreams or Remux: rejected because it would break
  machine URLs and protocol clients that cannot complete a browser flow.
- Replacing native AIOStreams OIDC with an ingress gate: rejected because the
  application already owns the correct browser/machine route distinction.
- Protecting all Remux browser paths: deferred because `/web` and `/jellyfin`
  share protocol-facing behavior; `/admin` is the narrow stable boundary.
- Redis/PostgreSQL or multiple Authelia replicas: deferred because high
  availability is outside the single-node v0.1 design.
