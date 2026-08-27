# AIOStreams current upstream contract

Research date: **2026-08-27**. This is a source and registry investigation,
not a deployment or runtime validation record. It uses the upstream GitHub
repository, its first-party documentation and workflow, and public GHCR OCI
metadata. No deployment-specific hostname, address, credential, token, cookie,
or private value is included.

## Reference points

The upstream default branch was at [`main` commit
`6c7c2daa08c3695e521e5ba1eb279634d1923298`](https://api.github.com/repos/Viren070/AIOStreams/commits/main).
The latest non-prerelease GitHub release was [`v2.33.2`](https://api.github.com/repos/Viren070/AIOStreams/releases/latest),
pointing at commit `f36d0f93ff088280526ebca1fe3c93e2740b6987`.

The effective published image was checked through the [official GHCR package
page](https://github.com/Viren070/AIOStreams/pkgs/container/aiostreams) and
the [GHCR OCI manifest endpoint](https://ghcr.io/v2/viren070/aiostreams/manifests/latest):

| Reference | Observed result |
| --- | --- |
| `ghcr.io/viren070/aiostreams:latest` | OCI index digest `sha256:b169ccfb2b6f351f1bc5a8a460e4e102db77a11fb4fc58222e411d96b3adb85b` |
| `ghcr.io/viren070/aiostreams:v2.33.2` | The same OCI index digest as `latest` |
| Platform manifests | `linux/amd64`: `sha256:29f09b02dcc78f9a387d83b37df47c0b7a67e4d0a878b7a518e54d6f0cc07565`; `linux/arm64`: `sha256:e67bf72196b48a026962e7f17c615f30eeb7338d02ff0e5073ebac2101ad5f18` |
| Additional index entries | Two `unknown/unknown` attestation manifests, not runnable platforms |

The release commit is not the current `main` commit: the [official GitHub
compare API](https://api.github.com/repos/Viren070/AIOStreams/compare/f36d0f93ff088280526ebca1fe3c93e2740b6987...6c7c2daa08c3695e521e5ba1eb279634d1923298)
reports `main` ahead by 66 commits. Therefore `latest` is a stable-release
alias, not a continuously rebuilt pointer to every commit on `main`.

## Image, release, and runtime contract

The official [`deploy-docker.yml`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.github/workflows/deploy-docker.yml#L27-L59)
accepts a ref manually. For a `vX.Y.Z` ref it always publishes the version
tag; it adds `latest`, the major/minor tag, and the major tag only when that
release ref resolves to the workflow checkout's `origin/main` commit. The
workflow labels that build channel `stable`. It builds separate
[`linux/amd64` and `linux/arm64` jobs](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.github/workflows/deploy-docker.yml#L61-L76)
and combines their digests into the GHCR manifest list/index
([merge step](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.github/workflows/deploy-docker.yml#L129-L170)).

The current milestone image contract is consequently:

- image: `ghcr.io/viren070/aiostreams:latest`;
- default/listening port: `3000` (`PORT` can override it); and
- working directory: `/app`.

The [upstream Dockerfile](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/Dockerfile#L98-L118)
sets the final image work directory to `/app`, exposes `${PORT:-3000}`, and
starts `/app/packages/server/dist/server.js`. The GHCR amd64 and arm64 image
configs independently report `ExposedPorts: {"3000/tcp": {}}`, `WorkingDir:
"/app"`, entrypoint `/nodejs/bin/node`, and the same server command. Their
config records report `User: "0"` (root); the Dockerfile does not add a
`USER` directive. The [amd64 image config blob](https://ghcr.io/v2/viren070/aiostreams/blobs/sha256:bb201c6e37db28caa7c96c8d5ad2977147109737f5f1446db66cf9177b70f4ee)
is the registry evidence for that identity. Do not claim that the upstream
image is rootless or force `runAsNonRoot` based on an assumption.

## Bootstrap variables, data, SQLite, and writable paths

The official [environment-variable documentation](https://docs.aiostreams.viren070.me/configuration/environment-variables)
and [`.env.sample`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.env.sample#L4-L55)
separate environment-only bootstrap values from database-backed runtime
settings. Bootstrap values are read before the database is available; runtime
settings can be managed in the dashboard unless an environment override locks
them.

### `BASE_URL`

`BASE_URL` is required in the normal production environment; the upstream
documentation says to provide a URL with protocol and hostname. The source
validator requires a non-empty URL-parsable value, does not enforce HTTPS (HTTP
can pass), and removes one trailing slash
([`env.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/env.ts#L70-L84);
[`BASE_URL` schema](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/env.ts#L209-L213)).
The upstream contract does **not** itself require the scheme to be HTTPS;
HTTPS is the appropriate production ingress policy. AIOStreams uses this value
for installation URLs, self-scraping detection, genre links, and built-in addon
stream URLs ([`.env.sample`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.env.sample#L31-L35)).

### `SECRET_KEY`

`SECRET_KEY` is a required 64-character hexadecimal value. The source uses it
for session/encryption key derivation and explicitly says it cannot change
after first run because existing encrypted configurations would then be
undecryptable ([`env.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/env.ts#L52-L57)
and [`.env.sample`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.env.sample#L37-L44)).
It is durable application recovery material and must stay outside public
configuration.

### SQLite and `/app/data`

The default `DATABASE_URI` is `sqlite://./data/db.sqlite`; PostgreSQL is also
supported ([`.env.sample`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.env.sample#L46-L50)).
With the image work directory `/app`, the relative SQLite URI resolves to
`/app/data/db.sqlite`: the [data-folder resolver](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/general.ts#L9-L19)
uses the SQLite filename's parent directory, and the [driver](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/db/connect.ts#L12-L45)
creates that parent directory before opening it.

The SQLite driver uses `better-sqlite3`, WAL journal mode, normal synchronous
operation, a 5-second busy timeout, and foreign keys
([driver initialization](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/db/driver/sqlite.ts#L61-L72)).
The durable mount must therefore permit the database and its SQLite WAL
sidecars to be created and updated.

`DISK_CACHE_DIR` is optional. If unset, disk-backed caches use
`<data-folder>/cache`, so the default is `/app/data/cache`; an explicit value
is resolved as an alternate path
([`.env.sample`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.env.sample#L52-L55)
and [cache-folder resolver](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/general.ts#L21-L31)).
The disk cache is a namespaced, byte-bounded LRU with an index and files; its
load/write failures are treated as best-effort and can fall back to
memory-only operation ([implementation](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/disk-backed-cache.ts#L98-L108)
and [load behavior](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/disk-backed-cache.ts#L177-L219)).

`/app/data` is broader than just the SQLite file. The source also persists the
instance identity there and places optional downloaded datasets below that
root, including SeaDex, anime-database, scene-mappings, and id-mappings
([instance identity](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/stream-sessions/instance-id.ts#L9-L35),
[SeaDex path](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/builtins/seadex/dataset.ts#L61-L78),
[anime path](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/anime-database/storage/paths.ts#L1-L12),
[scene path](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/metadata/scene-mappings.ts#L35-L49),
and [ID-mapping path](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/metadata/id-mappings.ts#L76-L91)).
The initial contract should mount `/app/data` as the writable persistent root;
separating the disposable cache is optional rather than required.

Redis is optional and the upstream sample recommends leaving it unset for a
standard single-container deployment; it is aimed at scaled deployments
([`.env.sample`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.env.sample#L76-L90)).

## Startup, migrations, and health

Startup is database-first. `initDb()` creates the selected driver, pings it,
runs migrations, and asserts the schema version
([`db.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/db/db.ts#L1-L55)).
The migration runner creates `_migrations`, applies pending migrations in
transactions, detects and baselines a pre-existing v2 `users` schema, and
fails if the database is newer than the running code
([runner](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/db/migrations/runner.ts#L105-L165)).
The server then initializes database-backed configuration and other services,
ensures the configuration access key/auth state, and only calls `listen()`
after those steps ([startup order](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/server.ts#L279-L324)).
Migrations are intended to be idempotent on each boot, but an unknown newer
schema is a deliberate startup failure rather than an automatic downgrade.

There are two relevant health contracts:

1. `GET /api/v1/health` is an explicit DB-backed route. It calls
   `UserRepository.getUserCount()` and returns HTTP 200 with success only when
   that database operation succeeds ([health route](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/api/health.ts#L12-L22)).
2. The image-level Docker `HEALTHCHECK` runs
   `/app/scripts/healthcheck.js`; that script requests `GET /api/v1/status` on
   localhost and requires HTTP 200. The Dockerfile declares 30-second
   interval, 5-second timeout, 5-second start period, and three retries
   ([Dockerfile](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/Dockerfile#L114-L118)
   and [healthcheck script](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/scripts/healthcheck.js#L1-L36)).

The existing repository note names `/api/v1/health`, which remains the clearer
DB-backed application probe, but it omits that the upstream image's own
container healthcheck uses `/api/v1/status`. These routes should not be
treated as interchangeable without testing the chosen probe.

## Native authentication and configuration behavior

`AIOSTREAMS_AUTH` accepts comma-separated `username:password` pairs. The
credentials are bootstrap data and are checked in constant time. The current
first-party documentation and source support `AIOSTREAMS_AUTH_PERMISSIONS`:
`admin` is a superset, while `proxy`, `service`, `sabnzbd`, `createConfig`,
and `none` have narrower meanings ([environment reference](https://docs.aiostreams.viren070.me/configuration/environment-variables)
and [credential/permission resolution](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/auth.ts#L72-L164)).
Users not explicitly listed in the permission map retain the documented
admin-by-default behavior.

The browser login is native: `POST /api/v1/auth/login` validates the
`AIOSTREAMS_AUTH` pair and issues an HMAC-signed session; `GET /api/v1/auth/me`
reports the current session and logout clears it
([auth routes](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/api/auth/index.ts#L23-L105)).
The session is HttpOnly and SameSite-Strict; its Secure attribute follows
whether `BASE_URL` starts with `https://`
([session middleware](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/auth.ts#L16-L53)).

`AIOSTREAMS_AUTH_REQUIRED` is a runtime setting whose default is false. When
true, `/stremio/configure` requires a valid native login session. The same
setting activates the configuration-write gate: `CONFIG_ACCESS_KEY` is checked
on configuration create/update/serve; if no key is supplied while auth is
required, AIOStreams generates and persists one, and rotating it invalidates
existing configurations ([API schema](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/config/schema/api.ts#L63-L93)
and [access-key implementation](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/auth.ts#L352-L424)).
An authenticated session injects the current key for authorized configuration
writes; users with an explicit permission set need `createConfig` (or `admin`)
to create new configurations ([middleware](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/auth.ts#L137-L154)
and [user create route](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/api/user.ts#L136-L188)).
The dashboard router is independently admin-only
([dashboard guard](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/api/dashboard/index.ts#L23-L40)).

OIDC support exists as a separate, disabled-by-default operator login option;
the upstream schema says it governs dashboard/config-page access and does not
alter Stremio addon URLs
([OIDC schema](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/config/schema/oidc.ts#L89-L108)).
It is not required for the native-auth contract.

## Stremio routes and machine authentication

The current Express route map is:

| Route | Current behavior |
| --- | --- |
| `GET /stremio/manifest.json` | Public. Without a user configuration, returns a configurable manifest with `configurationRequired: true`. |
| `GET /stremio/stream/:type/:id.json` | Public. Without user data, returns HTTP 200 with a Stremio configuration-required dynamic error; it does not expose a configured user's streams. |
| `GET /stremio/configure` | Public when `AIOSTREAMS_AUTH_REQUIRED=false`; requires a native browser session when true. |
| `/stremio/u/<alias>/...` | If an instance-wide alias is configured, redirects to the corresponding configured UUID/encrypted-password path while preserving the query string. |
| `/stremio/<uuid>/<encrypted-password>/manifest.json` | Configured machine manifest; the middleware validates the identity and decrypts the URL credential. The returned manifest sets `configurationRequired: false`. |
| `/stremio/<uuid>/<encrypted-password>/stream/:type/:id.json` | Configured machine stream endpoint; uses the persisted per-user configuration. |
| `/stremio/<uuid>/<encrypted-password>/meta/...`, `/catalog/...`, `/subtitles/...`, `/addon_catalog/...` | Configured Stremio resources, protected by the same URL identity. |

The route mounts and public/protected split are in [`app.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/app.ts#L199-L232).
The alias redirect is implemented in [`alias.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/stremio/alias.ts#L11-L32).
The manifest behavior is implemented in [`manifest.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/stremio/manifest.ts#L18-L82),
and the no-configuration stream response is in [`stream.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/stremio/stream.ts#L24-L40).

The configured URL's `<uuid>/<encrypted-password>` is a machine credential
path, not the browser administrator session. `userDataMiddleware` validates
the UUID or alias, decrypts the encrypted password using application crypto,
loads the user configuration, and validates it before resource handlers run
([middleware](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/userData.ts#L42-L129)
and [validation/attachment](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/userData.ts#L171-L202)).
This is why a blanket external ForwardAuth would break the intended machine
path and is not part of the upstream contract.

## Trusted proxy and client-IP behavior

The runtime `TRUSTED_IPS` default is
`172.17.0.0/16,127.0.0.1/32,::1/128`, inherited from the application schema
([schema](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/config/schema/api.ts#L164-L173)).
That is a Docker-oriented default, not evidence of the source range used by a
Kubernetes reverse-proxy path. It must be replaced with the narrowly observed
Traefik-to-application source range for the actual topology.

The implementation has two distinct behaviors
([`ip.ts`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/ip.ts#L44-L75)):

- `requestIp` uses `X-Forwarded-For` (first value), then `CF-Connecting-IP`,
  only when the immediate `req.ip` is in `TRUSTED_IPS`; otherwise it uses the
  immediate address and ignores those forwarded values.
- `userIp` considers several user-supplied headers, including
  `X-AIOStreams-User-IP`, `X-Client-IP`, `X-Forwarded-For`, `X-Real-IP`, and
  `CF-Connecting-IP`, regardless of `TRUSTED_IPS`, but discards invalid and
  private values. The upstream schema explicitly documents that user IP is
  always trusted via headers. Thus `TRUSTED_IPS` does not protect every
  header-derived IP decision; it primarily gates the `requestIp` path.

The CIDR helper converts dotted IPv4 addresses; its CIDR branch is not a full
IPv6 CIDR implementation even though individual IP validation accepts IPv6.
Use and test a precise IPv4 proxy range for the common K3s path, and do not
trust arbitrary forwarded headers by setting a broad range.

## Material deviations from the repository's existing note

Compared with [`k8s/aiostreams/README.md`](../../k8s/aiostreams/README.md), the
following are material clarifications or corrections:

1. **`latest` timing:** the note's description that `latest` is a stable tag
   whose commit is `main` needs the workflow-time qualifier. Today `main` is 66
   commits ahead of the released `v2.33.2`, while `latest` and `v2.33.2` point
   to the same GHCR digest.
2. **Runtime identity:** the current GHCR amd64/arm64 configs declare user
   `0` (root). The note correctly avoids forcing a numeric Kubernetes user, but
   the current upstream image must not be described as rootless.
3. **HTTPS wording:** upstream requires a valid `BASE_URL`; the source does
   not enforce HTTPS. HTTPS remains the production reverse-proxy requirement,
   not an intrinsic validator requirement.
4. **Health:** `/api/v1/health` is the explicit database-backed route, but the
   Dockerfile healthcheck actually calls `/api/v1/status` with its own timings.
5. **Configuration gate:** `AIOSTREAMS_AUTH_REQUIRED` now includes the
   `CONFIG_ACCESS_KEY` write/serve gate, automatic key persistence when absent,
   and the `createConfig` permission. `AIOSTREAMS_AUTH` also supports multiple
   credential pairs and a fuller permission model.
6. **IP trust:** `TRUSTED_IPS` gates `requestIp` forwarded-header use, but the
   separate `userIp` path accepts valid public values from several headers
   without that gate; the note's shorter description is incomplete.
7. **Persistent scope:** `/app/data` contains SQLite plus cache and optional
   dataset/identity files. A cache-only description understates the writable
   application state.

The existing note's core conclusions remain supported: the official image is
the GHCR `latest` image, the default port is 3000, the default SQLite file is
under `/app/data`, the durable `SECRET_KEY` must not change, configured Stremio
URLs are independent machine credentials, and a one-replica SQLite deployment
does not require Redis or PostgreSQL.

## Contract implications for this milestone

For a Kubernetes consumer of the current upstream contract:

- keep `ghcr.io/viren070/aiostreams:latest` if the project intentionally
  chooses the mutable stable alias, set `imagePullPolicy: Always` as the
  project-side Kubernetes policy, and treat the captured digest as evidence,
  not as a replacement manifest tag; upstream itself does not define a
  Kubernetes pull policy;
- use one replica with a writable persistent `/app/data` mount for SQLite and
  application state;
- supply `BASE_URL`, the unchanged `SECRET_KEY`, and native auth through a
  protected mechanism; enable `AIOSTREAMS_AUTH_REQUIRED` for a non-anonymous
  configuration surface and account for `CONFIG_ACCESS_KEY`;
- use a DB-backed application probe at `/api/v1/health` or deliberately mirror
  the upstream container probe at `/api/v1/status`, documenting which one is
  selected;
- do not force a rootless security context until the image is rebuilt or
  otherwise verified with compatible writable paths; and
- configure `TRUSTED_IPS` narrowly from observed proxy source addressing while
  leaving Stremio machine routes free of a blanket browser-auth gate.

This report is the only new repository artifact for this research request. It
does not claim that any live workload, certificate, DNS record, or deployment
has been changed or validated.

## Primary sources

- [AIOStreams repository](https://github.com/Viren070/AIOStreams), [current `main` commit API](https://api.github.com/repos/Viren070/AIOStreams/commits/main), [latest release API](https://api.github.com/repos/Viren070/AIOStreams/releases/latest), and [release-to-main compare API](https://api.github.com/repos/Viren070/AIOStreams/compare/f36d0f93ff088280526ebca1fe3c93e2740b6987...6c7c2daa08c3695e521e5ba1eb279634d1923298)
- [Official environment-variable documentation](https://docs.aiostreams.viren070.me/configuration/environment-variables)
- [`.env.sample`](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.env.sample), [Dockerfile](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/Dockerfile), and [stable image workflow](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/.github/workflows/deploy-docker.yml)
- [GHCR package page](https://github.com/Viren070/AIOStreams/pkgs/container/aiostreams), [OCI `latest` index](https://ghcr.io/v2/viren070/aiostreams/manifests/latest), and [observed amd64 config blob](https://ghcr.io/v2/viren070/aiostreams/blobs/sha256:bb201c6e37db28caa7c96c8d5ad2977147109737f5f1446db66cf9177b70f4ee)
- [Configuration/environment source](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/env.ts), [API schema](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/config/schema/api.ts), and [OIDC schema](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/config/schema/oidc.ts)
- [Application route map](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/app.ts), [Stremio alias route](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/stremio/alias.ts), [native auth routes](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/api/auth/index.ts), [auth middleware](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/auth.ts), [user-data middleware](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/userData.ts), and [IP middleware](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/middlewares/ip.ts)
- [Stremio manifest route](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/stremio/manifest.ts), [stream route](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/stremio/stream.ts), [health route](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/routes/api/health.ts), and [container healthcheck](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/scripts/healthcheck.js)
- [Database initialization](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/db/db.ts), [SQLite driver](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/db/driver/sqlite.ts), [migration runner](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/db/migrations/runner.ts), and [server startup](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/server/src/server.ts)
- [Data/cache path resolver](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/general.ts), [disk cache](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/utils/disk-backed-cache.ts), and [persistent dataset paths](https://github.com/Viren070/AIOStreams/blob/6c7c2daa08c3695e521e5ba1eb279634d1923298/packages/core/src/builtins/seadex/dataset.ts)
