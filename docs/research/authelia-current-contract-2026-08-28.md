# Authelia current upstream contract (2026-08-28)

This note records the upstream contract needed to evaluate an Authelia
workload in this repository. It is source research only: no cluster, ingress,
certificate, login, MFA, OIDC, AIOStreams, or Remux runtime was deployed or
validated for this note. Claims are anchored to official Authelia docs/source
or first-party release/registry metadata and were checked on 2026-08-28.

## Stable reference, image, and architecture

- The latest non-prerelease Authelia release reported by the official GitHub
  release API on 2026-08-28 was `v4.39.20`, published on 2026-05-26 at
  10:26:19 UTC: [release API](https://api.github.com/repos/authelia/authelia/releases/latest),
  [release page](https://github.com/authelia/authelia/releases/tag/v4.39.20).
- The official container names are `authelia/authelia` on Docker Hub and
  `ghcr.io/authelia/authelia` on GHCR. The versioned Docker Hub tag
  `4.39.20` was pushed on 2026-05-26 and advertises runnable Linux
  `amd64`, `arm64`, and `arm/v7` variants; use a versioned reference (and,
  for a release gate, record the resolved digest) rather than `latest`:
  [Docker Hub tag metadata](https://hub.docker.com/v2/repositories/authelia/authelia/tags/4.39.20),
  [official container documentation](https://www.authelia.com/integration/deployment/docker/).
- The tagged source image has no `USER` directive to rely on for a numeric
  non-root identity. Do not claim rootless operation or force a UID/GID until
  the selected image, writable paths, and runtime security context are tested:
  [v4.39.20 Dockerfile](https://github.com/authelia/authelia/blob/v4.39.20/Dockerfile)
  (checked 2026-08-28).

## Port and health contract

- The default server address is `tcp://:9091/`; the Docker image exposes TCP
  port `9091`. The image defaults its configuration file to
  `/config/configuration.yml` through `X_AUTHELIA_CONFIG`:
  [tagged configuration template](https://github.com/authelia/authelia/blob/v4.39.20/config.template.yml),
  [tagged Dockerfile](https://github.com/authelia/authelia/blob/v4.39.20/Dockerfile)
  (checked 2026-08-28).
- `GET` and `HEAD /api/health` are the upstream health endpoint. The tagged
  image healthcheck invokes the packaged healthcheck against that endpoint
  every 30 seconds, with a 3-second timeout and a 1-minute start period:
  [health API source](https://github.com/authelia/authelia/blob/v4.39.20/internal/handlers/handler_health.go),
  [tagged healthcheck](https://github.com/authelia/authelia/blob/v4.39.20/healthcheck.sh),
  [tagged Dockerfile](https://github.com/authelia/authelia/blob/v4.39.20/Dockerfile)
  (checked 2026-08-28).
- This is an Authelia process/API health signal, not proof that the configured
  SMTP, Redis, OIDC relying party, DNS, or reverse-proxy path is usable. Those
  integrations need separate validation; no such live validation is claimed
  here (official [server endpoint documentation](https://www.authelia.com/configuration/miscellaneous/server-endpoints-authz/),
  checked 2026-08-28).

## Configuration, secrets, and persistent state

- Authelia configuration is YAML. The container convention is one primary
  `/config/configuration.yml`; configuration files can be supplied/merged in
  order, and the path can be overridden with `X_AUTHELIA_CONFIG` or the CLI
  configuration option. Keep the effective configuration and its referenced
  files under a controlled, persistent configuration boundary:
  [configuration methods](https://www.authelia.com/configuration/methods/files/),
  [tagged template](https://github.com/authelia/authelia/blob/v4.39.20/config.template.yml)
  (checked 2026-08-28).
- Values whose keys end in `key`, `secret`, `password`, `token`, or
  `certificate_chain` are security-sensitive. The native secret mechanism
  reads a value from a file named by an environment variable ending in
  `_FILE`; the direct and `_FILE` forms must not both be defined. Newline
  handling and the limitations for values inside lists are documented by
  Authelia. Prefer file-backed secrets or its template secret function and
  keep them out of Git, manifests, argv, and logs:
  [security-sensitive values](https://www.authelia.com/configuration/prologue/security-sensitive-values/),
  [secrets method](https://www.authelia.com/configuration/methods/secrets/)
  (checked 2026-08-28).
- `storage.encryption_key` protects sensitive durable state and must be set to
  a stable secret before first use. The local storage provider uses
  `storage.local.path` for SQLite3; that database and the encryption key are
  state, not disposable cache. A persistent volume is required, and a local
  SQLite database is a single-writer/single-instance design: do not scale an
  Authelia deployment using local SQLite across replicas. Use the documented
  PostgreSQL/MySQL or other supported HA design when multi-replica state is
  required:
  [storage introduction](https://www.authelia.com/configuration/storage/introduction/),
  [SQLite3](https://www.authelia.com/configuration/storage/sqlite/),
  [PostgreSQL](https://www.authelia.com/configuration/storage/postgres/)
  (checked 2026-08-28).
- A conservative single-instance layout is a persistent `/config` boundary
  containing the YAML configuration, file-backend users database, local
  SQLite file, and any file-backed secrets with permissions restricted to the
  Authelia process. The exact filenames are operator choices; this note does
  not create or prescribe secret material (official [Docker integration](https://www.authelia.com/integration/deployment/docker/),
  checked 2026-08-28).

## Sessions, cookies, and domains

- The supported session providers are `memory` and Redis/Redis Sentinel. The
  default is memory when Redis is not configured; memory sessions disappear on
  restart and cannot be shared by replicas. Redis is the documented
  stateless/shared-session option for Kubernetes or HA. `session.secret` is
  documented as encrypting session data for Redis/Redis Sentinel:
  [session introduction](https://www.authelia.com/configuration/session/introduction/),
  [session Redis](https://www.authelia.com/configuration/session/redis/)
  (checked 2026-08-28).
- Default session values are cookie name `authelia_session`, SameSite `lax`,
  5-minute inactivity, 1-hour expiration, and 1-month remember-me duration.
  Longer lifetimes increase the exposure window of a stolen session:
  [session options](https://www.authelia.com/configuration/session/introduction/)
  (checked 2026-08-28).
- Session cookies are configured as a list of domains. Each cookie `domain`
  must contain the Authelia portal, and each `authelia_url` must be an HTTPS
  fully qualified URI whose host exactly matches or is a suffix of the cookie
  domain. The URL and domain relationship is validated by browser cookie
  rules; mismatching or HTTP values are not a valid production contract:
  [session cookie domains](https://www.authelia.com/configuration/session/introduction/)
  (checked 2026-08-28).
- Keep the Authelia portal, protected application hostnames, and cookie-domain
  plan explicit. A cookie-domain entry does not itself protect an application;
  the proxy must attach ForwardAuth and the Authelia access-control rules must
  authorize it (official [proxy integration overview](https://www.authelia.com/integration/proxies/),
  checked 2026-08-28).

## First factor, file users, password hashing, and MFA

- The file authentication backend is configured with
  `authentication_backend.file.path` pointing at a YAML users database. User
  records contain a username, a password hash, and groups; plaintext passwords
  must not be placed in the users file. Argon2/Argon2id is the recommended
  password-hash family. Generate a compatible hash with
  `authelia crypto hash generate` and deliver the resulting value through a
  protected operator path, never through this repository:
  [file authentication](https://www.authelia.com/configuration/first-factor/file/),
  [CLI hash command](https://www.authelia.com/reference/cli/authelia/authelia_crypto_hash_generate/)
  (checked 2026-08-28).
- The first operator user is therefore created by adding a hashed file-backend
  user and an administrator group, then selecting an access-control rule that
  requires the intended factor level. The file backend is suitable for a small
  single-instance deployment; LDAP is the upstream production-oriented option
  when directory-managed users and offloaded state are wanted:
  [first-factor introduction](https://www.authelia.com/configuration/first-factor/introduction/),
  [file backend](https://www.authelia.com/configuration/first-factor/file/)
  (checked 2026-08-28).
- TOTP is the simplest initial second factor. Unless changed, the current
  documented defaults are SHA-1, 6 digits, 30-second periods, and skew 1;
  Authelia encrypts TOTP secrets in storage. WebAuthn is also supported and
  has its own relying-party/origin requirements. Keep the clock synchronized;
  Authelia performs NTP-related checks relevant to TOTP:
  [TOTP](https://www.authelia.com/configuration/second-factor/time-based-one-time-password/),
  [WebAuthn](https://www.authelia.com/configuration/second-factor/webauthn/),
  [NTP](https://www.authelia.com/configuration/miscellaneous/ntp/)
  (checked 2026-08-28).
- Configure notifications before relying on account recovery. Authelia
  supports exactly one notification provider at a time: SMTP for production,
  or filesystem for testing. Notifications are used by MFA enrollment and
  recovery flows; the filesystem provider is not a production delivery path:
  [notification introduction](https://www.authelia.com/configuration/notifications/introduction/),
  [SMTP](https://www.authelia.com/configuration/notifications/smtp/),
  [filesystem provider](https://www.authelia.com/configuration/notifications/file/)
  (checked 2026-08-28).

## Access control

- `access_control` is an ordered first-match rule list. Rules match domains,
  optional users/groups, and optional resource regular expressions; policies
  are `bypass`, `one_factor`, `two_factor`, or `deny`. If no rules are
  defined, Authelia applies deny to everyone. The deployment must therefore
  define explicit rules for the portal/protected hosts, with a final
  fail-closed rule where appropriate:
  [access control](https://www.authelia.com/configuration/security/access-control/)
  (checked 2026-08-28).
- Access control is proxy authorization for ordinary protected HTTP
  resources. It does not authorize OpenID Connect clients; the OIDC provider
  has a separate per-client authorization policy. Do not infer that an
  `access_control` rule grants an OIDC client access, or that an OIDC client
  policy protects arbitrary proxy routes:
  [OIDC provider](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/),
  [access control](https://www.authelia.com/configuration/security/access-control/)
  (checked 2026-08-28).

## Traefik ForwardAuth and trusted proxies

- The current Authelia authorization endpoint for Traefik ForwardAuth is
  `/api/authz/forward-auth`. The current server endpoint configuration uses
  the `ForwardAuth` implementation. The official Traefik example passes
  Authelia response headers `Remote-User`, `Remote-Groups`, `Remote-Email`,
  and `Remote-Name`, and sets Traefik's `trustForwardHeader` according to the
  proxy topology:
  [Traefik integration](https://www.authelia.com/integration/proxies/traefik/),
  [authz endpoint configuration](https://www.authelia.com/configuration/miscellaneous/server-endpoints-authz/)
  (checked 2026-08-28).
- `trustForwardHeader` is not permission to accept arbitrary client-supplied
  forwarding headers. The tagged v4.39.20 `server` schema does not expose the
  newer `server.trusted_proxies` option, so this workload does not add an
  unsupported field. Keep the direct Traefik path and edge header behavior
  explicit, do not enable an unverified Cloudflare proxy path, and validate
  forwarded host/protocol behavior through the live TLS route:
  [forwarded headers](https://www.authelia.com/integration/proxies/forwarded-headers/),
  [tagged server schema](https://github.com/authelia/authelia/blob/v4.39.20/internal/configuration/schema/server.go)
  (checked 2026-08-28).
- A ForwardAuth middleware should be attached only to routes whose upstream
  application is designed for browser authentication. It must not be applied
  blanket-wide to machine APIs, callback endpoints, health probes, WebSockets,
  or Stremio installation URLs unless the upstream contract explicitly
  supports that behavior. This is an integration safety boundary, not a claim
  that Authelia itself protects those routes automatically (official
  [Traefik integration](https://www.authelia.com/integration/proxies/traefik/),
  checked 2026-08-28).

## Authelia as the OIDC provider

- Authelia's OpenID Connect provider is documented as open beta while also
  being OpenID certified. Treat that maturity boundary as part of the risk
  decision and pin the tested release:
  [provider introduction/configuration](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/),
  [OIDC integration introduction](https://www.authelia.com/integration/openid-connect/introduction/)
  (checked 2026-08-28).
- Provider discovery is served at
  `https://<auth-host>/.well-known/openid-configuration`. The issuer URL must
  be stable and reachable with valid TLS by both the browser and the OIDC
  client. Provider metadata exposes the authorization/token/userinfo/JWKS
  contract; the relying party must use the issuer's discovered endpoints rather
  than inventing endpoint paths:
  [OIDC integration](https://www.authelia.com/integration/openid-connect/introduction/),
  [provider configuration](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/)
  (checked 2026-08-28).
- The provider requires `identity_providers.oidc.hmac_secret` and `jwks`.
  Configure at least one RSA private signing key using RS256 with a minimum
  2048-bit key; keep the HMAC secret and private JWKS material outside the
  repository, preferably through Authelia's file-backed secret/template
  mechanisms. The provider's public JWKS is used by clients to verify signed
  ID tokens:
  [provider options](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/),
  [security-sensitive values](https://www.authelia.com/configuration/prologue/security-sensitive-values/)
  (checked 2026-08-28).
- Register an OIDC client under `identity_providers.oidc.clients` with an
  exact client ID, a client secret, redirect URI list, and an explicit
  authorization policy. Authelia recommends storing a supported hash for the
  client secret; the relying party uses the corresponding plaintext secret.
  Plaintext client secrets in Authelia configuration are deprecated. Redirect
  URIs are exact and case-sensitive, so a path, scheme, host, or trailing slash
  mismatch is a failed integration rather than a harmless variation:
  [OIDC clients](https://www.authelia.com/configuration/identity-providers/openid-connect/clients/),
  [OIDC FAQ](https://www.authelia.com/integration/openid-connect/frequently-asked-questions/)
  (checked 2026-08-28).

## AIOStreams native OIDC contract

- On 2026-08-28 the current AIOStreams `main` source was commit
  [`39c62815f03e6a84811bef05e9f065de561265b3`](https://github.com/Viren070/AIOStreams/commit/39c62815f03e6a84811bef05e9f065de561265b3).
  The latest GitHub release was `v2.33.2`, published on 2026-08-11; OIDC
  support is present in the current source and the release line:
  [release API](https://api.github.com/repos/Viren070/AIOStreams/releases/latest),
  [OIDC schema at current main](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/config/schema/oidc.ts),
  [OIDC schema at v2.33.2](https://github.com/Viren070/AIOStreams/blob/v2.33.2/packages/core/src/config/schema/oidc.ts)
  (checked 2026-08-28).
- AIOStreams' OIDC feature is disabled by default and governs dashboard and
  configuration-page access only; it does not replace or alter Stremio addon
  URLs. The native recovery path remains enabled by default through
  `AIOSTREAMS_OIDC_ALLOW_LOCAL_LOGIN=true`. Relevant settings include the
  issuer, client ID, client secret, scopes, username/groups claims, group
  permission map, default permissions, and the local-login switch:
  [OIDC schema](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/config/schema/oidc.ts)
  (checked 2026-08-28).
- AIOStreams discovers `{issuer}/.well-known/openid-configuration` and uses
  the authorization-code flow. Its required redirect URI is
  `<BASE_URL>/api/v1/auth/oidc/callback`; the source constructs the same URI
  for authorization and token exchange. Login binds state, nonce, and PKCE
  S256 to a short-lived state cookie, and expects an ID token. Configure this
  exact callback in Authelia's OIDC client:
  [OIDC utility](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/utils/oidc.ts),
  [OIDC routes](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/server/src/routes/api/auth/oidc.ts),
  [AIOStreams SSO guide](https://docs.aiostreams.viren070.me/guides/sso/)
  (checked 2026-08-28).
- The AIOStreams OIDC schema defaults to `preferred_username` and `groups`.
  Group permissions are explicit; an unmatched group with no default
  permissions fails closed, and an invalid permission mapping refuses the
  login. `admin` expands to all AIOStreams permissions. Keep the provider's
  groups claim and requested scope aligned with this mapping:
  [OIDC schema](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/config/schema/oidc.ts),
  [OIDC permission resolution](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/utils/oidc.ts)
  (checked 2026-08-28).
- AIOStreams' browser session cookie is HttpOnly and SameSite Strict, with
  `Secure` derived from an HTTPS `BASE_URL`; the OIDC state cookie is scoped to
  `/api/v1/auth/oidc`, SameSite Lax, and has a 10-minute lifetime. An HTTPS
  public `BASE_URL` is therefore the appropriate production contract even
  though the source validator accepts a parseable HTTP URL:
  [AIOStreams auth middleware](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/server/src/middlewares/auth.ts),
  [environment source](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/utils/env.ts),
  [environment documentation](https://docs.aiostreams.viren070.me/configuration/environment-variables)
  (checked 2026-08-28).

## Remux route and admin boundary

- On 2026-08-28 the current Remux `main` source was commit
  [`354ad11bd8534adce5b60e0e896c99a00cb67ec9`](https://github.com/lostb1t/remux/commit/354ad11bd8534adce5b60e0e896c99a00cb67ec9).
  The latest stable release was `v0.27.0`, published on 2026-08-27, tag
  commit [`02803fd1dfda0b7eb81beeb9dcbb013f5a392da1`](https://github.com/lostb1t/remux/commit/02803fd1dfda0b7eb81beeb9dcbb013f5a392da1)
  (checked 2026-08-28).
- Remux has public bootstrap routes `/health`, `/system/info/public`, and
  `/users/public`; native login is `/users/authenticatebyname`. The
  Jellyfin-compatible catalog, playback, and user routes use Remux's native
  token/session authorization. `/websocket` and `/socket` are native
  authenticated upgrade routes. `/web` and `/jellyfin` serve Jellyfin web
  client surfaces, while `/` redirects to `/web/`:
  [tagged server route construction](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/lib.rs),
  [tagged users API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/users.rs),
  [tagged playback API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/playback.rs)
  (checked 2026-08-28).
- The dashboard is separately mounted at `/admin` (`base_path = "/admin"`).
  The admin frontend verifies a native Remux administrator session, and the
  server-side `AdminSession` guard protects admin APIs. External Authelia
  ForwardAuth can therefore be considered only as an additional, narrow
  `/admin` browser gate; it does not replace Remux's native admin check:
  [tagged dashboard configuration](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-dashboard/Dioxus.toml),
  [tagged admin/server code](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/lib.rs),
  [tagged system API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/system.rs)
  (checked 2026-08-28).
- Do not blanket-protect the Remux hostname, `/web`, `/jellyfin`, Jellyfin
  APIs, playback/stream routes, or WebSockets with Authelia. That would put a
  browser-oriented redirect/authentication layer in front of protocol and
  machine routes that already have their own native contract. This boundary is
  derived from the tagged route/auth source above and is not live validation
  (checked 2026-08-28).

## AIOStreams and Remux integration semantics

- AIOStreams has two distinct credential planes: its browser dashboard/native
  or OIDC session, and its configured Stremio machine URL containing the
  per-user UUID/encrypted-password path. The configured Stremio resources are
  validated by AIOStreams' user-data middleware; they are not authenticated by
  the browser session. Public bootstrap routes and the conditional
  `/stremio/configure` browser surface are separate from configured machine
  routes:
  [AIOStreams route map](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/server/src/app.ts),
  [Stremio user-data middleware](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/server/src/middlewares/userData.ts),
  [AIOStreams manifest route](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/server/src/routes/stremio/manifest.ts)
  (checked 2026-08-28).
- Remux's addon API stores a Stremio `manifest_url` in the addon's nested
  configuration. The current source exposes addon create/update/list routes
  under `/addons`; addon administration uses the native Remux admin session:
  [tagged addon API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/addons.rs),
  [tagged addon request types](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-sdks/src/remux/mod.rs)
  (checked 2026-08-28).
- When the stored AIOStreams manifest is cluster-local, Remux must use the
  addon option `httpRedirectStream=false`. The tagged playback implementation
  redirects only when that per-addon setting permits direct-play HTTP
  redirection; disabling it makes Remux proxy the source instead. A client
  seeing a `Location` containing a cluster-local service name is a hard
  integration failure. This is source-derived and has not been live-tested:
  [tagged playback implementation](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/playback.rs),
  [tagged addon API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/addons.rs)
  (checked 2026-08-28).
- Consequently, Authelia should not be put in front of the AIOStreams
  `/stremio` machine route or the Remux-to-AIOStreams manifest/stream path.
  Use AIOStreams native OIDC/local login for its dashboard/configuration
  surface, and reserve any external Authelia middleware for the narrow human
  admin route being protected. The AIOStreams machine credential remains
  operator-managed and is intentionally absent from this note (checked
  2026-08-28).

## Validation, upgrades, and acceptance boundary

- Validate the rendered configuration with the tagged CLI before starting the
  workload, for example `authelia config validate --config
  /config/configuration.yml`. The command validates syntax/configuration but
  cannot prove network reachability, SMTP delivery, proxy header behavior,
  browser cookie behavior, OIDC discovery, or a relying-party callback:
  [config validate reference](https://www.authelia.com/reference/cli/authelia/authelia_config_validate/)
  (checked 2026-08-28).
- Startup performs configuration and dependency initialization checks. Storage
  migrations run automatically on startup; configuration migrations are
  automatic in memory from v4.36, while major-version configuration migrations
  are disabled. Take a fresh application-consistent backup of the persistent
  Authelia state, rehearse restore separately, read the release migration
  notes, validate the new configuration, and keep a one-replica SQLite
  instance stopped/serialized during upgrade:
  [configuration migration](https://www.authelia.com/configuration/prologue/migration/),
  [storage migrations](https://www.authelia.com/configuration/storage/migrations/)
  (checked 2026-08-28).
- Required evidence remains separate: source/static contract, rendered config
  validation, container health, Traefik ForwardAuth responses, browser login,
  first-factor login, MFA enrollment/recovery, OIDC discovery/callback, and
  AIOStreams/Remux machine-route behavior are different verification lanes.
  This note records none of the live lanes.

## Primary sources

- Authelia [repository](https://github.com/authelia/authelia), [v4.39.20 release](https://github.com/authelia/authelia/releases/tag/v4.39.20),
  [release API](https://api.github.com/repos/authelia/authelia/releases/latest),
  [Docker Hub tag metadata](https://hub.docker.com/v2/repositories/authelia/authelia/tags/4.39.20),
  and [v4.39.20 Dockerfile](https://github.com/authelia/authelia/blob/v4.39.20/Dockerfile)
  (release/registry checked 2026-08-28).
- Authelia [configuration methods](https://www.authelia.com/configuration/methods/introduction/),
  [security-sensitive values](https://www.authelia.com/configuration/prologue/security-sensitive-values/),
  [file authentication](https://www.authelia.com/configuration/first-factor/file/),
  [access control](https://www.authelia.com/configuration/security/access-control/),
  [sessions](https://www.authelia.com/configuration/session/introduction/),
  [SQLite](https://www.authelia.com/configuration/storage/sqlite/),
  [notifications](https://www.authelia.com/configuration/notifications/introduction/),
  [Traefik](https://www.authelia.com/integration/proxies/traefik/),
  [Forwarded Headers](https://www.authelia.com/integration/proxies/forwarded-headers/),
  [OIDC provider](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/),
  [OIDC clients](https://www.authelia.com/configuration/identity-providers/openid-connect/clients/),
  and [validation CLI](https://www.authelia.com/reference/cli/authelia/authelia_config_validate/)
  (docs checked 2026-08-28).
- AIOStreams [repository](https://github.com/Viren070/AIOStreams), [latest release API](https://api.github.com/repos/Viren070/AIOStreams/releases/latest),
  [OIDC schema](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/config/schema/oidc.ts),
  [OIDC utility](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/core/src/utils/oidc.ts),
  [OIDC routes](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/server/src/routes/api/auth/oidc.ts),
  [route map](https://github.com/Viren070/AIOStreams/blob/39c62815f03e6a84811bef05e9f065de561265b3/packages/server/src/app.ts),
  and [SSO guide](https://docs.aiostreams.viren070.me/guides/sso/)
  (source/docs checked 2026-08-28).
- Remux [repository](https://github.com/lostb1t/remux), [v0.27.0 release](https://github.com/lostb1t/remux/releases/tag/v0.27.0),
  [server route construction](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/lib.rs),
  [users API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/users.rs),
  [system API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/system.rs),
  [playback API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/playback.rs),
  [addon API](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/addons.rs),
  and [dashboard configuration](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-dashboard/Dioxus.toml)
  (source/release checked 2026-08-28).
