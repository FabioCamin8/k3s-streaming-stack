# Cloudflare DNS and TLS

Cloudflare is the DNS provider for the deployment. It is not assumed to be the
video proxy, application authentication layer, or secret store. The current
AIOStreams record is configured DNS-only to select direct-origin semantics;
that setting, the certificate, and an internal HTTPS route check do not prove
public Internet reachability. Its hostname and address are operator data, not
repository data.

## DNS-01 certificate flow

cert-manager will use ACME DNS-01 to prove control of the zone. This avoids requiring an HTTP challenge to reach the cluster and works whether an application hostname is DNS-only or proxied.

Create a dedicated Cloudflare API token using the [Cloudflare token workflow](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/). Scope it to the one deployment zone and grant only the permissions required by the [cert-manager Cloudflare DNS-01 integration](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/): zone read and DNS record edit. Do not use a global API key.

The token is created and delivered out of band. A Kubernetes Secret may exist in the target cluster, but its value must never appear in Git, shell history, pull requests, or this documentation. The public repository uses no real domain; `stream.example.com` is an example only.

The certificate lifecycle is:

1. Create a staging ClusterIssuer and request a staging certificate.
2. Confirm DNS-01 records are created and removed correctly.
3. Confirm Traefik serves the staging certificate and clients reach the intended hostnames.
4. Only after the application and renewal path are proven, create the production issuer and certificate.
5. Monitor renewal and retain a rollback path to the previous working ingress configuration.

## Proxy decision

The initial default is DNS-only while the stack is brought up. This makes the network path and redirect behavior observable and avoids sending streaming traffic through Cloudflare by assumption.

Cloudflare proxying is an explicit per-hostname decision. Before enabling it, verify the applicable Cloudflare product limits and terms, confirm that the application protocol is supported, and test authentication, forwarded client information, WebSocket behavior if required by the verified upstream contract, and Remux redirects.

If proxying is enabled:

- Configure Traefik's trusted proxy handling to accept forwarded headers only from Cloudflare's current published network ranges, available at [cloudflare.com/ips](https://www.cloudflare.com/ips/).
- Keep the trusted ranges in deployment-managed configuration and review them when Cloudflare changes its list.
- Do not trust `X-Forwarded-For`, `X-Forwarded-Proto`, or similar headers from arbitrary source addresses.
- Treat Cloudflare's edge as an HTTP(S) boundary, not as a path for direct upstream media after a successful redirect.

## DNS records

Create only the application records that are required, using deployment-specific values outside Git. The configured application record is a single DNS-only A record intended for the Traefik origin. Keep the public repository limited to example names and omit real addresses. A DNS record does not by itself expose a Kubernetes Service; Traefik ingress and any external firewall/NAT remain separate controls.

The record was created out of band with the scoped cert-manager operator token.
Public DNS-over-HTTPS observed the record, but the authoritative answer
currently classifies the origin as private and an external vantage point timed
out. The internal route works; therefore certificate and HTTPS evidence are
currently internal validation only, not proof of public Internet reachability.
A local resolver may also serve a cached negative answer for a short time, so
DNS evidence and the HTTPS route check remain separate gates. The live internal
route was validated with an ephemeral operator-side resolve mapping, without
persisting that mapping or publishing its address. This repository does not
change DNS, NAT, firewall, or router state.

## Operational checks

- Confirm authoritative DNS answers before certificate issuance.
- Confirm the ACME solver can create and clean up its TXT records.
- Confirm certificates renew before their expiry window.
- Confirm the certificate secret is not tracked by Git or included in support bundles.
- Confirm the DNS-only origin and production certificate after a node reboot;
  the application verifier and redacted evidence are recorded in
  [`docs/validation/aiostreams-2026-08-27.md`](validation/aiostreams-2026-08-27.md).
- If proxying is enabled, confirm the observed client IP and scheme are derived only from trusted Cloudflare sources.
- Confirm Internet reachability from an independent external vantage point;
  internal DNS, certificate, and Traefik checks are not a substitute.
