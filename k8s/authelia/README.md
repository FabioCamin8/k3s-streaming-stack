# Authelia workload

This directory contains the public-safe Kubernetes contract for one Authelia
replica in the existing `streaming` namespace. It uses the bundled K3s
Traefik, a ClusterIP Service, a 2Gi local-path PVC, and the official
`ghcr.io/authelia/authelia:4.39.20` image. Automatic updates are deliberately
not enabled.

## Authentication architecture

Authelia is a selective human-authentication service, not a blanket ingress
gate:

```text
Traefik
  +-- Authelia portal and OIDC provider
  |     +-- AIOStreams native OIDC -> dashboard/configuration UI
  |     +-- Remux /admin -> ForwardAuth -> two-factor policy
  |
  +-- AIOStreams Stremio machine URLs -> native application behavior
  +-- Remux root/Jellyfin API/playback/WebSocket -> native Jellyfin auth
```

The public AIOStreams manifest and configured Stremio URLs do not require an
Authelia browser session. Remux's `/health`, public bootstrap APIs, Jellyfin
login/API, playback, and `/websocket`/`/socket` routes do not receive the
ForwardAuth middleware. Only the separate Remux `/admin` Ingress uses
`authelia-forwardauth`.

The middleware deliberately does not copy Authelia identity headers into
Remux. Remux's admin page remains authoritative through its native session,
and unauthenticated clients cannot supply trusted identity headers through
this boundary. `trustForwardHeader: false` prevents client-supplied forwarded
headers from being accepted as an upstream trust signal.

## Upstream contract

The contract was checked against the official Authelia documentation and
release metadata on 2026-08-28:

- The stable release was `v4.39.20`; the official container names include
  `ghcr.io/authelia/authelia` and `docker.io/authelia/authelia`.
- The default HTTP listener is TCP 9091 and the health endpoint is
  `GET /api/health`.
- File authentication, SQLite storage, filesystem notification, session
  cookies, TOTP, access control, ForwardAuth, and the OIDC Provider role are
  supported. Authelia is an OIDC Provider here; AIOStreams is the relying
  party.
- SQLite and the in-memory session provider are stateful and appropriate for
  this one-replica single-node deployment only. They are not an HA design.
- Authelia configuration file secrets are loaded with the official `template`
  filter from mounted files. Kubernetes Secret values never enter Git or the
  public configuration template. OIDC client secrets are stored in Authelia
  as an upstream password hash; the plaintext is supplied only to AIOStreams.

Primary sources are linked in
[`docs/research/authelia-current-contract-2026-08-28.md`](../../docs/research/authelia-current-contract-2026-08-28.md).

## Private operator inputs

Copy [`operator.env.example`](operator.env.example) to a protected path and
set the paths to private files. The users file must contain one operator user
with an Argon2id password hash and the `admins` group, for example:

```yaml
users:
  operator:
    displayname: Operator
    password: <generated-argon2id-password-hash>
    email: operator@example.invalid
    groups:
      - admins
```

Generate the password hash with the current Authelia `crypto hash generate`
command in an interactive/private context. Do not place the plaintext
password or resulting operator-specific hash in Git, shell history, or PR
evidence. Keep the users file mode 600.

The private secret directory must contain these non-empty files, all mode 600:

```text
SESSION_SECRET
STORAGE_ENCRYPTION_KEY
IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET
OIDC_HMAC_SECRET
OIDC_ISSUER_PRIVATE_KEY
AIOSTREAMS_OIDC_CLIENT_SECRET_HASH
```

Use fresh random values for the string secrets, generate an RSA private key of
at least 2048 bits for `OIDC_ISSUER_PRIVATE_KEY`, and generate the final file
with the current Authelia hash command from the same private plaintext client
secret supplied to AIOStreams. The OIDC private key, hash, TOTP registrations,
SQLite database, and filesystem notifications are all sensitive state.

Render and apply only from outside the checkout:

```sh
AUTHELIA_CONFIG_FILE=/secure/operator-secrets/authelia/operator.env \
  ./k8s/authelia/render.sh /tmp/k3s-authelia-manifests
kubectl kustomize /tmp/k3s-authelia-manifests
kubectl apply -k /tmp/k3s-authelia-manifests
```

The rendered directory contains the users file and generated Kubernetes
Secret inputs. Remove it after the apply/validation session using the
operator's normal protected cleanup procedure.

## AIOStreams and Remux configuration

The AIOStreams operator file also receives these private OIDC values:

```text
AIOSTREAMS_OIDC_ISSUER=https://auth.example.com/
AIOSTREAMS_OIDC_CLIENT_SECRET=<same-private-plaintext-used-to-create-the-hash>
```

The OIDC client ID is the fixed value `aiostreams` in both bundles.

Set `AIOSTREAMS_PUBLIC_HTTPS_PORT` to the same value used by the AIOStreams
renderer. The Authelia renderer derives the callback and default redirection
URL from that port, omitting `:443` and retaining a non-standard port such as
`:8443`.

The renderer keeps local AIOStreams authentication enabled as recovery and
does not enable automatic provider redirects. The fixed public settings map
the Authelia `admins` group to AIOStreams `admin`, use the `groups` claim, and
request `openid profile email groups`. AIOStreams' callback is exactly:

```text
https://<AIOSTREAMS_HOST>[:<AIOSTREAMS_PUBLIC_HTTPS_PORT>]/api/v1/auth/oidc/callback
```

The OIDC provider issuer, callback, cookies, and TLS host must be tested
through Traefik. Direct Pod or Service access is not a substitute for the
HTTPS/SNI path.

Remux's main Ingress remains unchanged. The Authelia bundle adds the separate
`remux-admin` Ingress for `/admin` with the middleware annotation. If the
deployed Remux version ever collapses this boundary, remove that middleware
and retain Remux-native authentication rather than protecting the whole
hostname.

## Persistence and recovery boundary

The `authelia-data` PVC stores SQLite state and filesystem notifications. The
users database, session/storage/OIDC secrets, OIDC private signing key, and
configuration are required to start the service. TOTP registration material
is encrypted in the storage database and depends on the storage encryption
key. A K3s datastore backup protects the Kubernetes objects and Secrets but
does not protect local-path PVC files; later application-data backup must
protect `authelia-data` separately.

This one-replica local SQLite/session design is intentionally not HA. A Pod
recreation should retain the database, user identity, OIDC configuration, and
MFA state. Session invalidation after a restart is acceptable if required by
the provider, but the service must start with the durable identity
configuration intact.

## Validation gates

Run [`scripts/verify/authelia-render.sh`](../../scripts/verify/authelia-render.sh)
before applying. After applying, run
[`scripts/verify/authelia.sh`](../../scripts/verify/authelia.sh) with the
operator's Kubernetes context and LAN-side `AUTHELIA_URL`.

The operator must additionally prove through Traefik/TLS:

1. `/api/health` and OIDC discovery return 200.
2. A valid password login succeeds and an invalid password is rejected.
3. TOTP enrollment, two-factor login, and the documented recovery path work.
4. AIOStreams redirects an anonymous configuration request to OIDC, completes
   the Authelia login/callback, and retains local recovery login.
5. The base/configured Stremio machine URLs do not redirect to Authelia.
6. Anonymous Remux `/admin` requires Authelia, while Jellyfin bootstrap,
   native login/API, playback-info, internal AIOStreams fetch, and websocket
   paths do not.
7. A Pod recreation restores durable identity/configuration and all applicable
   gates are repeated.

WAN forwarding remains intentionally disabled. Local/LAN validation uses
`curl --resolve`, split DNS, or another Host/SNI-preserving client through
Traefik. Do not automate browser credentials into this repository.
