# AIOStreams validation evidence

Date: 2026-08-27

This is a redacted operator report. It intentionally omits the deployment
hostname, node and origin addresses, credentials, cookies, kubeconfig data, and
private backup paths.

## Resource and topology gates

- The updated `scripts/verify/aiostreams.sh` passed all 16 workload/TLS gates
  after the final controlled node reboot.
- K3s is active and enabled with one Ready node.
- Traefik is the present IngressClass and Service; the AIOStreams Service has
  a ready endpoint.
- The `streaming` namespace is Active. The Deployment has one ready replica and
  `Recreate` strategy; the image is `:latest` with `Always` pull policy.
- The PVC is Bound on `local-path`.
- The bound local-path PV uses its node-local `.spec.local.path`; the backing
  directory existed during the final check and contained 124,422,873 bytes.
- The bootstrap Secret contains all required keys; values were withheld.
- The AIOStreams Certificate is Ready.
- Metrics-server reported AIOStreams at `1m/333Mi` and the node at
  `155m/1932Mi` during the final check.
- The configured trusted-proxy range matches the observed node PodCIDR; neither
  value is published here.
- The running image digest was observed as
  `sha256:b169ccfb2b6f351f1bc5a8a460e4e102db77a11fb4fc58222e411d96b3adb85b`.

## HTTPS and authentication

The application DNS record is DNS-only and was created out of band. Normal
DNS returned an answer, while direct HTTPS from the validating LAN was blocked
by the local hairpin path. An ephemeral operator-side origin mapping then
validated the actual Traefik route without persisting the mapping:

| Path | Normal resolver | Cloudflare DoH |
| --- | ---: | ---: |
| `/api/v1/health` | 200 | 200 |
| `/stremio/manifest.json` | 200 | 200 |
| unauthenticated `/stremio/configure` | 302 | 302 |

With the same ephemeral mapping and temporary cookie jar:

| Native path | Status |
| --- | ---: |
| `POST /api/v1/auth/login` | 200 |
| authenticated `GET /api/v1/auth/me` | 200 |
| authenticated `GET /stremio/configure` | 200 |

The unauthenticated `GET /api/v1/user` probe returned 400 because the route
requires Basic auth; it is not an acceptance gate.

The current `v2.33.2` release requires `sortCriteria.global`, a valid
`formatter.id`, and a `presets` array even when no providers are configured.
Using the source-backed provider-free payload
`{"sortCriteria":{"global":[]},"formatter":{"id":"torrentio"},"presets":[]}`
with a transient native admin session produced one user configuration:

| Operation | Status/result |
| --- | ---: |
| `POST /api/v1/user` | 201 |
| generated configured manifest | 200, `configurationRequired=false` |
| same user/manifest after Pod recreation | 200, `configurationRequired=false` |
| same user/manifest after controlled VM reboot | 200, `configurationRequired=false` |

The user retrieval checks used Basic auth with the generated UUID and the
transient configuration password. No provider or debrid credentials were
used.

## Recovery evidence

- The first post-reboot verifier attempt was a timing race: it ran before K3s
  became active and reported the namespace as absent. The K3s database and WAL
  were subsequently confirmed present under `server/db/`; no application data
  loss occurred.
- The verifier waits for the target namespace and then the Deployment's
  `Available` condition for up to `WAIT_SECONDS` before evaluating dependent
  resources, while still failing closed on timeout. This avoids accepting a
  stale Deployment status during K3s reboot replay.
- In the final controlled reboot proof, QEMU Guest Agent recovered in 8.9
  seconds. The workload verifier completed after the K3s/API readiness wait and
  passed all 16 gates. The PVC and runtime image digest remained valid.
- Pod recreation and post-recreation persistence passed before the final reboot
  proof; after the reboot, the verifier waited for actual Deployment
  availability before repeating the user/manifest check. The application data
  remains node-local and is not a backup.

## Explicit gaps

Provider-backed playback, Remux, Authelia, automatic image updates, HA, and
remote application-data backup/restore remain future gates. The mutable
`latest` tag has no automatic rollback claim; a future updater must retain a
known immutable recovery image before it is enabled.
