# Living project plan

This is the concise roadmap for the low-maintenance Kubernetes-native stack.
It separates desired future architecture from the state actually validated.

## Validated foundation

### Phase 0 - reproducible VM — COMPLETE / validated

Debian 13 full-clone VM from the pinned Cloud-Init template, with QEMU Guest
Agent and the documented Proxmox boundary.

### Phase 1 - K3s platform — COMPLETE / validated

Single-node K3s with bundled containerd, Traefik, CoreDNS, ServiceLB,
local-path, metrics-server, embedded SQLite, encrypted Secrets, and reboot
recovery. Multi-node operation is not implied.

### Phase 2 - TLS / DNS-01 platform — COMPLETE / validated where current live checks prove it

cert-manager DNS-01 through Cloudflare, staging before production, host
certificate validation, renewal proof, DNS-only streaming origin, and reboot
recovery. `external-dns` remains optional future work.

## Current milestone

### Phase 3 - AIOStreams — THIS PR / implemented and live-validated

One `latest` replica with `imagePullPolicy: Always`, SQLite, `/app/data`
local-path PVC, public Traefik HTTPS ingress, native auth, DB-backed health,
trusted-proxy validation, Pod recreation, controlled reboot, and a real
Stremio manifest check. Its public HTTPS port is an explicit operator input:
443 is the standard/template default and 8443 is the supported alternate,
both mapping to Traefik's internal 443. The direct-origin mode remains
DNS-only; DNS-01 does not depend on the application public port. Independent
public reachability is a separate gate and remains unresolved when the origin
or NAT path is not publicly reachable. Direct provider-backed playback is only
claimed when its credentials and test are available.

## Future milestones

### Phase 3.1 - edge / reverse-proxy consolidation — future, not implemented

Allow several self-hosted services to share WAN 443 by hostname while
preserving client protocol compatibility, avoiding unnecessary extra public
ports, and retaining a simple TLS lifecycle. Inspect existing services such as
MediaFlow and choose deliberately between TLS termination, SNI passthrough, a
K3s Traefik consolidation point, or a minimal existing external edge. Do not
introduce a new reverse-proxy product in the AIOStreams milestone.

### Phase 4 - Remux — planned

Jellyfin-compatible client endpoint, `/data` persistence, AIOStreams
integration, per-addon proxy versus HTTP 302 redirect, Infuse/Swiftfin live
validation, migration/reboot/recovery checks, and an explicit invariant that
no redirect may expose `*.svc.cluster.local` or any other client-unreachable
internal AIOStreams URL when AIOStreams becomes internal-only.

### Phase 5 - selective Authelia — planned

Protect human/admin/configuration surfaces without blanket-protecting Stremio,
Jellyfin, or other machine protocol endpoints. Prefer AIOStreams native OIDC
where upstream supports it; evaluate Remux admin paths separately and retain
application-native protocol authentication.

### Phase 6 - automatic application lifecycle — planned

Evaluate and, if evidence supports it, implement Keel for AIOStreams mutable
`latest` digest tracking. Establish health gates, failure drills, a reliable
previous-image recovery mechanism, and a conservative Remux policy before
enabling automation. Failed migrations or breaking upstream changes may still
require a human. The target is low-maintenance / near-zero routine maintenance,
not zero maintenance.

### Phase 7 - optional DNS automation — planned

Evaluate `external-dns` only if the number and dynamism of records justify its
additional permissions and controller lifecycle.

### Phase 8 - operational polish — planned

Application-data backup/restore, update failure drills, documented restore, and
periodic major-version review.

## Desired end state

The platform remains one understandable K3s node with no unnecessary control
planes, dashboards, GitOps stack, service mesh, or duplicate ingress. Stable
application releases should normally be detected and rolled out automatically
with bounded health/recovery risk. Debian major upgrades, K3s, cert-manager,
major Traefik/platform changes, storage architecture, and major authentication
changes remain deliberate reviewed maintenance events unless a later ADR says
otherwise.
