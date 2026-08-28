# Cloudflare DNS and TLS

Cloudflare is the DNS provider for the deployment. It is not assumed to be the
video proxy, application authentication layer, or secret store. The current
AIOStreams record is configured DNS-only to select direct-origin semantics;
that setting and the certificate do not by themselves prove public Internet
reachability for every deployment. The selected live route was externally
validated after the operator supplied its NAT rule. Hostname and address are
operator data, not repository data.

The public service port is separate from DNS and Kubernetes. The operator may
use standard direct HTTPS (`WAN TCP/443 -> Traefik TCP/443`) or alternate direct
HTTPS (`WAN TCP/8443 -> Traefik TCP/443`). The selected port belongs in
AIOStreams `BASE_URL`, while the DNS record contains only the hostname. Traefik
continues to use its internal `websecure` entrypoint on 443.

## DNS-01 certificate flow

cert-manager will use ACME DNS-01 to prove control of the zone. This avoids requiring an HTTP challenge to reach the cluster and works whether an application hostname is DNS-only or proxied. The DNS TXT challenge and the resulting certificate for `stream.example.com` are independent of whether clients later connect to port 443 or 8443. Do not add HTTP-01 or require WAN port 80 for the alternate public port.

Create a dedicated Cloudflare API token using the [Cloudflare token workflow](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/). Scope it to the one deployment zone and grant only the permissions required by the [cert-manager Cloudflare DNS-01 integration](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/): zone read and DNS record edit. Do not use a global API key.

The token is created and delivered out of band. A Kubernetes Secret may exist in the target cluster, but its value must never appear in Git, shell history, pull requests, or this documentation. The public repository uses no real domain; `stream.example.com` is an example only.

The certificate lifecycle is:

1. Create a staging ClusterIssuer and request a staging certificate.
2. Confirm DNS-01 records are created and removed correctly.
3. Confirm Traefik serves the staging certificate and clients reach the intended hostnames.
4. Only after the application and renewal path are proven, create the production issuer and certificate.
5. Monitor renewal and retain a rollback path to the previous working ingress configuration.

## Proxy decision

The initial default is DNS-only while the stack is brought up. This makes the
network path and redirect behavior observable and avoids sending streaming
traffic through Cloudflare by assumption. The operator has intentionally
disabled the current WAN streaming forward while the stack is under
construction; this is not a workload failure and does not block local/LAN
validation. Orange-cloud HTTP proxying is not part of this milestone.

Cloudflare proxying is an explicit per-hostname decision. Before enabling it,
verify the applicable Cloudflare product limits and terms, confirm that the
application protocol is supported, and test authentication, forwarded client
information, WebSocket behavior if required by the verified upstream contract,
and Remux redirects. A Remux redirect is useful only for an externally
reachable upstream URL; the internal AIOStreams Service must remain proxied by
Remux with its addon redirect flag disabled.

If proxying is enabled:

- Configure Traefik's trusted proxy handling to accept forwarded headers only from Cloudflare's current published network ranges, available at [cloudflare.com/ips](https://www.cloudflare.com/ips/).
- Keep the trusted ranges in deployment-managed configuration and review them when Cloudflare changes its list.
- Do not trust `X-Forwarded-For`, `X-Forwarded-Proto`, or similar headers from arbitrary source addresses.
- Treat Cloudflare's edge as an HTTP(S) boundary, not as a path for direct upstream media after a successful redirect.

## DNS records

Create only the application records that are required, using deployment-specific values outside Git. The configured application record is a single DNS-only A record intended for a publicly reachable Traefik origin. Keep the public repository limited to example names and omit real addresses. DNS contains no port: a public 8443 choice is expressed only by the client URL and the router/NAT rule. A DNS record does not by itself expose a Kubernetes Service; Traefik ingress and any external firewall/NAT remain separate controls.

The record was created out of band with the scoped cert-manager operator token.
The private origin value was corrected through the existing scoped operator
path to the observed public origin, and authoritative/public DNS now returns a
non-private answer. The record remains DNS-only. Historically, the operator
supplied a TCP-only WAN 8443 -> Traefik TCP/443 forward and an independent
external vantage validated the AIOStreams DNS, TCP, TLS, and application path;
that evidence remains valid for its original run. The forward is now
intentionally disabled while Remux is under construction. This repository does
not change NAT, firewall, or router state.

## Operational checks

- Confirm authoritative DNS answers before certificate issuance.
- Confirm the ACME solver can create and clean up its TXT records.
- Confirm certificates renew before their expiry window.
- Confirm the certificate secret is not tracked by Git or included in support bundles.
- Confirm the DNS-only origin and production certificate after a node reboot;
  the AIOStreams application verifier and redacted historical evidence are
  recorded in [`docs/validation/aiostreams-2026-08-27.md`](validation/aiostreams-2026-08-27.md).
- Validate the Remux host locally/LAN-side with `curl --resolve` or an
  equivalent Host/SNI-preserving request; WAN forwarding is not required.
- If proxying is enabled, confirm the observed client IP and scheme are derived only from trusted Cloudflare sources.
- Confirm Internet reachability from an independent external vantage point;
  internal DNS, certificate, and Traefik checks are not a substitute.
