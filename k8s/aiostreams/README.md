# AIOStreams workload

This directory contains the public-safe Kubernetes contract for one
AIOStreams replica. The workload is deliberately small: the bundled K3s
Traefik handles HTTPS, SQLite is stored on one local-path PVC, and native
AIOStreams authentication protects human-facing configuration and admin
surfaces. Remux, Authelia, Redis, PostgreSQL, and an image updater are not part
of this workload.

## Current upstream contract

Checked against the current `main` branch and GHCR metadata on 2026-08-27:

| Property | Verified contract |
| --- | --- |
| Image | `ghcr.io/viren070/aiostreams:latest` |
| `latest` | Published by the upstream release workflow for a stable semver release when that release ref resolves to upstream `main`; it is intentionally mutable. On 2026-08-27, `latest` and `v2.33.2` shared the observed digest while upstream `main` was already ahead. |
| Architectures | `linux/amd64` and `linux/arm64` image index |
| Release observed | v2.33.2 |
| Container port | 3000 |
| Working directory | `/app` |
| Durable data | SQLite at `/app/data/db.sqlite` from `DATABASE_URI=sqlite://./data/db.sqlite` |
| Cache | Defaults under the data directory; no separate cache volume is needed initially |
| Health | `GET /api/v1/health`, which queries the database before returning 200 |
| Base URL | Required valid URL, used for generated addon/configuration URLs; production ingress uses HTTPS |
| Durable key | `SECRET_KEY`, exactly 64 hex characters; changing it makes stored encrypted configurations unreadable |
| Native auth | `AIOSTREAMS_AUTH=user:password`, with `AIOSTREAMS_AUTH_REQUIRED=true` for `/stremio/configure` |
| Machine paths | Public `/stremio/manifest.json` and `/stremio/stream`; configured machine URLs use `/stremio/<uuid>/<encrypted-password>/...` |
| Proxy/IP | `TRUSTED_IPS` narrowly gates forwarded `requestIp` headers; the upstream Docker default is not used |
| Startup | Database connection and migrations complete before the server listens |
| Runtime user | No `runAsUser` is forced; the image identity is observed live before making that assumption |

Primary sources: the upstream [Dockerfile](https://github.com/Viren070/AIOStreams/blob/main/Dockerfile), [environment sample](https://github.com/Viren070/AIOStreams/blob/main/.env.sample), [health route](https://github.com/Viren070/AIOStreams/blob/main/packages/server/src/routes/api/health.ts), [app routes](https://github.com/Viren070/AIOStreams/blob/main/packages/server/src/app.ts), [IP middleware](https://github.com/Viren070/AIOStreams/blob/main/packages/server/src/middlewares/ip.ts), and [release workflow](https://github.com/Viren070/AIOStreams/blob/main/.github/workflows/deploy-docker.yml).

The current GHCR index digest is captured as live evidence, not copied into
the manifest. The manifest must remain `:latest` with `imagePullPolicy: Always`
by project decision.

## Files and ownership

- `deployment.yaml`: one replica, `Recreate` strategy, probes, hardening that
  does not assume a numeric image user, and the `/app/data` mount.
- `service.yaml`: internal `ClusterIP` on port 80.
- `pvc.yaml`: 10Gi `ReadWriteOnce` local-path storage. This is a starting
  capacity, not a backup.
- `ingress.yaml`: Traefik `websecure` route and production cert-manager issuer.
- `bootstrap.yaml`: placeholder-only Secret template. It is never applied
  directly.
- `render.sh`: substitutes private operator values into a new directory
  outside the checkout.

## Operator configuration

Copy `operator.env.example` to a protected location outside Git, then replace
all values. The real file contains the hostname, the durable key, and native
auth credentials:

```sh
cp k8s/aiostreams/operator.env.example /secure/operator-secrets/aiostreams.env
chmod 600 /secure/operator-secrets/aiostreams.env
openssl rand -hex 32       # AIOSTREAMS_SECRET_KEY
openssl rand -hex 24       # password material for AIOSTREAMS_AUTH
```

Set `AIOSTREAMS_PUBLIC_HTTPS_PORT` to the operator's public TCP port. Use `443`
for the standard URL or `8443` when the router preserves WAN 443 for another
service. The public port is an external/NAT concern: Traefik still terminates
TLS on its normal internal `websecure` entrypoint at 443, the Ingress hostname
contains no port, and DNS records never contain a port.

Rendering produces these URL forms:

| Public mode | `BASE_URL` |
| --- | --- |
| WAN 443 -> Traefik 443 | `https://stream.example.com` |
| WAN 8443 -> Traefik 443 | `https://stream.example.com:8443` |

The DNS-01 certificate flow is independent of this choice. Cloudflare carries
the DNS TXT challenge for `stream.example.com`; Let's Encrypt issues the host
certificate; clients later use either public URL. No HTTP-01 challenge or WAN
port 80 is required.

Set `AIOSTREAMS_TRUSTED_IPS` to the exact source range observed between
Traefik and the AIOStreams Pod. On the current single-node cluster the node
PodCIDR is an operator-specific value and is kept only in the private file.
Do not use the upstream Docker `172.17.0.0/16` default without checking the
K3s path.

Render into a new temporary directory and inspect it without publishing it:

```sh
AIOSTREAMS_CONFIG_FILE=/secure/operator-secrets/aiostreams.env \
  ./k8s/aiostreams/render.sh /tmp/k3s-aiostreams-manifests
kubectl kustomize /tmp/k3s-aiostreams-manifests
kubectl apply -k /tmp/k3s-aiostreams-manifests
```

Run the static contract checks with:

```sh
./scripts/verify/aiostreams-render.sh
```

The rendered directory contains the Secret and is secret material. Remove it
after the apply/validation session and never commit it.

## Authentication and request paths

Native authentication is the application boundary for this milestone. The
operator credential is supplied through `AIOSTREAMS_AUTH`; the config page is
gated by `AIOSTREAMS_AUTH_REQUIRED=true`, and the dashboard/API session is
created through AIOStreams' own login endpoint. With auth required and no
`CONFIG_ACCESS_KEY` environment value, the current release generates and
persists its config-write key in the application settings store; an
authenticated native session injects that key for authorized config writes.
A blanket Traefik ForwardAuth is intentionally absent so Stremio machine paths
remain usable.

The public base manifest is useful for discovery and returns a configuration
required response until a safe per-user configuration exists. A configured
Stremio URL carries the upstream-generated user identity/password path; it is
not the browser's admin session. On the current `v2.33.2` release, the
smallest provider-free configuration accepted by the user API is:

```json
{"sortCriteria":{"global":[]},"formatter":{"id":"torrentio"},"presets":[]}
```

Create it with `POST /api/v1/user` using the native admin session and a
separate configuration password. `GET /api/v1/user` requires Basic auth in
the generated `uuid:password` form; an unauthenticated request returning 400
is expected. Do not put provider or debrid credentials in this repository or
in a smoke test.

## Persistence and recovery

The local-path PVC protects `/app/data` across Pod recreation on this single
node. It does not provide HA or remote backup. K3s datastore backup protects
Kubernetes objects and Secrets, but it does not back up local-path PVC files.
Recovery therefore requires both the AIOStreams application data and the same
`SECRET_KEY`. A Deployment rollback alone is not a reliable rollback for a
mutable tag: a recreated Pod may pull newer bytes for `latest`. A future
automatic updater must retain a known previous immutable digest or another
proven recovery mechanism before it is enabled.

## Validation

Use [`scripts/verify/aiostreams.sh`](../../scripts/verify/aiostreams.sh) after
the rollout. The milestone validation must cover the Ready node, Bound PVC,
Deployment, Service endpoints, production certificate, DB-backed health,
native login/config protection, public Stremio manifest, Pod recreation,
controlled node reboot, actual image digest, and the observed trusted-proxy
source. The redacted results are recorded in
[`docs/validation/aiostreams-2026-08-27.md`](../../docs/validation/aiostreams-2026-08-27.md).
Provider-backed playback is a separate gate when real provider credentials are
deliberately unavailable.
