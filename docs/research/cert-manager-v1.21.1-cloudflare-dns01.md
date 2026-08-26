# cert-manager and Cloudflare DNS-01 findings

Research date: 2026-08-26. Scope: the pinned cert-manager installation contract, the Cloudflare DNS-01 solver, least-privilege token access, and Let's Encrypt ACME endpoints. All external sources below are official project documentation or first-party APIs.

## Findings

### Supported release and installation artifact

- The cert-manager support page lists release branches **1.21** and **1.20** as supported and says only the last patch release of each branch is supported. The official `releases/latest` API resolves to **v1.21.1**, so that is the exact release to pin at this research date. ([supported releases](https://cert-manager.io/docs/releases/); [latest release API](https://api.github.com/repos/cert-manager/cert-manager/releases/latest); accessed 2026-08-26.)
- Release URL: [cert-manager v1.21.1](https://github.com/cert-manager/cert-manager/releases/tag/v1.21.1). The official default static-install documentation uses the single release manifest [cert-manager.yaml](https://github.com/cert-manager/cert-manager/releases/download/v1.21.1/cert-manager.yaml); the kubectl documentation says it contains the CRDs and cert-manager, cainjector, and webhook components. ([installation](https://cert-manager.io/docs/installation/); [kubectl/static install](https://cert-manager.io/docs/installation/kubectl/); accessed 2026-08-26.)
- Upstream's release API exposes this asset checksum: **SHA-256 `5f6a499b8c1857d57f560f536e0dcc830914b45c420899fe7ad0692c8624e408`** for `cert-manager.yaml`. ([v1.21.1 release API](https://api.github.com/repos/cert-manager/cert-manager/releases/tags/v1.21.1); accessed 2026-08-26.)

### Cloudflare DNS-01 solver and token

- Use a Cloudflare **API Token**, not the global API Key. The cert-manager solver reference requires a Kubernetes Secret containing the token under key `api-token`, referenced by `dns01.cloudflare.apiTokenSecretRef.name` and `.key`. ([cert-manager Cloudflare solver](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/); accessed 2026-08-26.)
- The minimum documented token permission set is the target zone's DNS write plus zone read: cert-manager labels these `Zone - DNS - Edit` and `Zone - Zone - Read`; Cloudflare's current permission catalog lists the zone groups as `DNS Write` and `Zone Read`. Zone read is needed for the solver's zone discovery (`/zones?name=...`), while DNS write is needed to present and clean up the ACME TXT record. ([cert-manager Cloudflare solver](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/); [Cloudflare API-token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/); accessed 2026-08-26.)
- Restrict **Zone Resources** to the one deployment zone. cert-manager's example says `Include - All Zones` for convenience, but Cloudflare documents selecting a specific zone and states that other zones and other operations are rejected. Do not grant unrelated account or user permissions. ([cert-manager Cloudflare solver](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/); [Cloudflare token creation and resource scoping](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/); accessed 2026-08-26.)

### Let's Encrypt ACME directories

Use ACME v2 and validate against staging before production:

| Environment | Directory URL |
| --- | --- |
| Staging | `https://acme-staging-v02.api.letsencrypt.org/directory` |
| Production | `https://acme-v02.api.letsencrypt.org/directory` |

Let's Encrypt identifies these as its ACME v2 endpoints. The staging environment is for testing and issues certificates chaining to untrusted roots, so its certificate must not be treated as production trust material. ([ACME protocol endpoints](https://letsencrypt.org/docs/acme-protocol-updates/); [staging environment](https://letsencrypt.org/docs/staging-environment/); accessed 2026-08-26.)

## Milestone decision

Pin the official `v1.21.1` static manifest and verify its published asset digest before installation. Create the Cloudflare token and Kubernetes Secret out of band, scoped to the single deployment zone with only DNS write and zone read, then use the Let's Encrypt staging directory for validation before introducing production ACME resources.

## Primary sources

- [cert-manager supported releases](https://cert-manager.io/docs/releases/)
- [cert-manager installation](https://cert-manager.io/docs/installation/) and [kubectl/static install](https://cert-manager.io/docs/installation/kubectl/)
- [cert-manager v1.21.1 release](https://github.com/cert-manager/cert-manager/releases/tag/v1.21.1) and [release API](https://api.github.com/repos/cert-manager/cert-manager/releases/tags/v1.21.1)
- [cert-manager Cloudflare DNS-01 solver](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [Cloudflare API-token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/) and [token creation/resource scoping](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Let's Encrypt ACME protocol endpoints](https://letsencrypt.org/docs/acme-protocol-updates/) and [staging environment](https://letsencrypt.org/docs/staging-environment/)

