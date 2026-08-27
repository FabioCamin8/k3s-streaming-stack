# AIOStreams validation evidence

Date: 2026-08-27

This is a redacted operator report. It intentionally omits the deployment
hostname, node and origin addresses, credentials, cookies, kubeconfig data, and
private backup paths.

## Deployment and manifest gates

- The current `scripts/verify/aiostreams.sh` passed all 19 gates after the
  final controlled VM reboot, using a bounded 30-second readiness wait.
- The rendered manifests passed a remote Kubernetes server-side dry-run. The
  subsequent apply was scoped to the AIOStreams bundle: Namespace, Service,
  PVC, Deployment, and Ingress were unchanged; the bootstrap Secret was
  configured from protected operator values.
- K3s was active with one Ready node. The `streaming` namespace was Active.
- The Deployment had one ready replica and `Recreate` strategy; the image was
  `ghcr.io/viren070/aiostreams:latest` with `Always` pull policy.
- The Service was `ClusterIP` port 80 to the named HTTP container port and had
  a ready endpoint.
- The PVC was Bound on `local-path`. Its node-local backing directory existed
  during validation; this is application state, not a remote backup.
- The bootstrap Secret contained `BASE_URL`, `SECRET_KEY`, `DATABASE_URI`,
  `AIOSTREAMS_AUTH`, `AIOSTREAMS_AUTH_REQUIRED`, and `TRUSTED_IPS`; values were
  withheld.
- The Traefik Ingress and production Certificate were present; the
  Certificate was Ready.
- The running image digest was observed as
  `sha256:b169ccfb2b6f351f1bc5a8a460e4e102db77a11fb4fc58222e411d96b3adb85b`.

## HTTPS, authentication, and application behavior

The AIOStreams record is configured DNS-only and was created out of band. The
actual Traefik HTTPS route was validated internally using a temporary
operator-side resolve mapping. No mapping or private address was persisted.

| Check | Result |
| --- | ---: |
| DB-backed `GET /api/v1/health` | 200 |
| unauthenticated `GET /stremio/manifest.json` | 200 |
| unauthenticated `GET /stremio/configure` | 302 |
| native login | 200 |
| authenticated session lookup | 200 |
| authenticated configure page | 200 |
| provider-free user creation | 201 |
| generated configured manifest | 200, `configurationRequired=false` |
| authenticated user retrieval | 200 |

The provider-free payload was:

```json
{"sortCriteria":{"global":[]},"formatter":{"id":"torrentio"},"presets":[]}
```

User retrieval used Basic auth with the generated UUID and transient
configuration password. No provider or debrid credentials were used, and
provider-backed playback is not claimed.

## Persistence and reboot proof

- The exact current AIOStreams Pod was deleted. The replacement Pod had a
  different UID, and the same user and configured manifest survived with
  `configurationRequired=false`.
- A controlled VM reboot completed. SSH access recovered in 28 seconds.
- The first post-reboot API check encountered a transient readiness race; a
  bounded retry waited for K3s/API availability and then all focused checks
  passed: health, base manifest, unauthenticated configure redirect, native
  login/session/configure, user retrieval, and configured manifest.
- The repository verifier was rerun after reboot with `WAIT_SECONDS=30` and
  passed all 19 gates. PVC state, the running image digest, and the
  application configuration remained valid.
- After reboot, metrics-server reported AIOStreams at `1m/333Mi` and the node
  at `123m/1972Mi`.

K3s datastore backup does not include local-path PVC files. Recovery therefore
requires the AIOStreams application data and the same durable `SECRET_KEY`; a
Deployment rollback alone is not reliable while `latest` is mutable.

## Trusted proxy proof

Live topology inspection confirmed that Traefik runs as a Deployment Pod rather
than host-networked, and its Pod address is within the node PodCIDR. The
configured `TRUSTED_IPS` contains that exact PodCIDR; the private values are
not published. The Service uses `externalTrafficPolicy=Cluster`.

Through the real HTTPS Traefik route, reserved test `X-Forwarded-For` values
produced one shared rate-limit bucket (`4 -> 3 -> 2`) rather than independent
identities. This is bounded evidence for the tested path that arbitrary
client-supplied forwarded headers did not create separate rate-limit buckets;
it is not a claim that every application header-derived IP behavior is
protected by `TRUSTED_IPS`.

## DNS and external reachability limitation

Cloudflare authoritative DNS-over-HTTPS currently returns one A record that is
classified as RFC1918/private. An external AWS vantage point timed out with
HTTP `000`, while the internal K3s route works. The production certificate,
Traefik route, and application checks therefore prove the internally reachable
HTTPS path only; Internet reachability is not currently verified.

This PR does not change DNS, NAT, firewall, router, or origin-address state.
The limitation remains an operator follow-up gate and must be resolved before
claiming public Internet availability.

## Explicit gaps

Provider-backed playback, Remux, selective Authelia, automatic image updates,
HA, external application-data backup/restore, and mutable-tag rollback drills
remain future gates. Keel is only a future candidate; no updater or automatic
rollback is deployed.
