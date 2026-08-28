# Remux upstream contract (2026-08-28)

This note records the upstream contract used by the Remux Kubernetes workload.
The deployment is intentionally pinned to the stable release below; facts from
the newer `main` branch are used only to identify drift and are not attributed
to the deployed image.

## Release and image

- Stable release: `v0.27.0`, tag commit
  [`02803fd1dfda0b7eb81beeb9dcbb013f5a392da1`](https://github.com/lostb1t/remux/commit/02803fd1dfda0b7eb81beeb9dcbb013f5a392da1).
- Upstream `main` at the research time was
  [`354ad11bd8534adce5b60e0e896c99a00cb67ec9`](https://github.com/lostb1t/remux/commit/354ad11bd8534adce5b60e0e896c99a00cb67ec9),
  ahead of the stable tag. `latest` is mutable and is not the initial
  deployment reference.
- Image: `ghcr.io/lostb1t/remux:0.27.0`.
- The source release tag includes the `v` (`v0.27.0`), but the GHCR
  container tag does not. An authorized registry lookup on 2026-08-28 returned
  `404` for `v0.27.0` and `200` for `0.27.0`; the Kubernetes image reference
  follows the published container tag.
- The release workflow publishes the container for `linux/amd64` and
  `linux/arm64`; the image metadata is also described by the tagged
  [`Dockerfile`](https://github.com/lostb1t/remux/blob/v0.27.0/docker/Dockerfile)
  and [release workflow](https://github.com/lostb1t/remux/blob/main/.github/workflows/release.yml).
- The Dockerfile declares no `USER`. The Kubernetes manifest therefore does
  not invent a numeric UID/GID or force a user that the image does not provide.

## Runtime and persistence

The tagged Dockerfile and server configuration establish:

| Concern | Verified contract | Deployment choice |
| --- | --- | --- |
| HTTP | Port `3000` | Named container port and ClusterIP Service |
| Data root | `DATA_DIR=/data` | Entire `/data` mounted on one local-path PVC |
| Database | `sqlite:///data/db.sqlite?mode=rwc` when explicitly configured; the server derives the same path from `DATA_DIR` otherwise | Explicit `DATABASE_URL`; SQLite WAL and migrations are application-managed |
| Torrent state | `TORRENT_DATA_DIR=/data/torrents`; cache is derived under `/data/cache` | Kept on the same PVC; no torrent Service is exposed |
| Transcoding | `FFMPEG_PATH=/usr/lib/jellyfin-ffmpeg/ffmpeg`; `FFPROBE_PATH=/usr/lib/jellyfin-ffmpeg/ffprobe` | Uses image-provided binaries; no host device is granted |
| Web assets | `WEB_PATH=/app/jellyfin-web`; `DASHBOARD_PATH=/app/dashboard` | Points at image-provided assets rather than placing them in the data PVC |
| Health | `GET /health` returns static HTTP 200 | Used as startup/readiness/liveness signal; it is not DB-backed readiness |

The server opens the database, applies migrations, and initializes services
before it starts accepting HTTP traffic. The migration code and database layer
are in the tagged [`server library`](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/lib.rs),
[`database module`](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/db/mod.rs),
and [`startup path`](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/main.rs).
First startup and upgrades must not be interrupted during migration. A local
PVC is persistence, not an off-node backup.

`LOG_FILE` appears in the tagged Docker metadata, but the server startup path
calls `setup_logging(None)` and does not load that variable into persistent
file logging. The workload does not set it; container stdout/stderr is the
logging boundary.

## Public URL, authentication, and routes

Remux has no `BASE_URL` environment variable in the tagged server config. URL
generation relies on the forwarded host/protocol request context. Traefik is
therefore configured as the only public edge, and the Remux Ingress preserves
the original HTTPS host.

The Jellyfin-compatible API includes public bootstrap endpoints such as
`/health`, `/system/info/public`, and `/users/public`; user authentication and
session tokens use the native Jellyfin-compatible routes and token headers.
Authenticated catalog, item, playback, stream, and session routes are served
under the paths in the tagged [`API modules`](https://github.com/lostb1t/remux/tree/v0.27.0/crates/remux-server/src/api).
The bundled browser/admin assets are served under the admin/web paths. The
authenticated `/websocket` and `/socket` routes use the normal HTTP upgrade,
which Traefik preserves without a special middleware.

No blanket external ForwardAuth is appropriate: it would break machine
bootstrap, Jellyfin protocol, streaming, or WebSocket behavior. Human/admin
protection is a later selective-Authelia decision.

## Stremio addon integration

The tagged API uses:

- `POST /addons` with a `CreateAddonRequest` containing a `preset` whose kind
  is `stremio` and whose nested config contains `manifest_url`.
- `POST /addons/{id}` with an `UpdateAddonRequest` for existing instances.
  The JSON field names are camelCase: `config`, `isDefault`,
  `httpRedirectStream`, and `serviceFilter`.
- Addon list/get routes are `/addons` and `/addons/{id}` and require the native
  admin session. Create returns 201; update returns 200.

The workload helper supplies the AIOStreams manifest through
`http://aiostreams.streaming.svc.cluster.local/.../manifest.json`, then verifies
the stored addon has `httpRedirectStream=false` and is enabled. The private
AIOStreams user path and Remux token are operator inputs and never enter Git.

## Proxy versus redirect

The tagged playback implementation checks the producing addon's
`http_redirect_stream` setting per request. Only an HTTP direct-play source is
redirected, using a temporary HTTP 302; transcoding remains served through
Remux. When the flag is false, Remux serves/proxies the source through its
stream path. See the tagged [`playback implementation`](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/playback.rs)
and [`addon API`](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/api/addons.rs).

Because AIOStreams is addressed by a cluster-local URL, its addon redirect
flag must stay false. A client-facing `Location` header containing
`*.svc.cluster.local` is a hard failure. An external addon may use the per-addon
redirect option only when its returned source URL is externally reachable.

## Resource and compatibility implications

The image packages Jellyfin FFmpeg, yt-dlp support, torrent support, and
hardware-acceleration libraries. Direct play is primarily network/storage
work; codec, subtitle, bitrate, or client-profile conversion can invoke FFmpeg
and materially increase CPU and temporary storage. The initial Deployment does
not set resource limits from idle observations and does not grant host GPU
devices. Actual CPU/RAM and playback observations belong in redacted live
validation evidence, not in this source-contract note.

## Sources

All behavior above was checked against the tagged source and image metadata,
with the current `main` ref used only for release-drift comparison:

- [Remux repository](https://github.com/lostb1t/remux)
- [v0.27.0 Dockerfile](https://github.com/lostb1t/remux/blob/v0.27.0/docker/Dockerfile)
- [server configuration and startup](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/lib.rs)
- [database layer](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-server/src/db/mod.rs)
- [Jellyfin-compatible API](https://github.com/lostb1t/remux/tree/v0.27.0/crates/remux-server/src/api)
- [addon request/response types](https://github.com/lostb1t/remux/blob/v0.27.0/crates/remux-sdks/src/remux/mod.rs)
- [release workflow](https://github.com/lostb1t/remux/blob/main/.github/workflows/release.yml)
