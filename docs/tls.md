# TLS baseline

This milestone establishes the smallest reproducible TLS foundation for the
single-node K3s platform. It does not deploy AIOStreams, Remux, Authelia,
external-dns, or a Traefik dashboard.

## Decisions

- Install the official cert-manager static manifest at the exact version in
  [`infra/cert-manager/versions.env`](../infra/cert-manager/versions.env), with
  its release-asset SHA-256 checked before `kubectl apply`.
- Use an operator-managed Cloudflare API-token Secret. This cluster is
  single-node and operator-managed, so SOPS/age would add key-management and
  bootstrap complexity without a current GitOps requirement. Application
  secrets follow the same model initially unless a later ADR changes it.
- Restrict the Cloudflare API Token to the deployment zone with `Zone - DNS -
  Edit` and `Zone - Zone - Read`. Never use the Global API Key.
- Use Let's Encrypt staging before production. Keep both issuer names and
  account-key Secrets distinct.
- Use individual host certificates, not a wildcard, until the actual
  application/admin hostname layout is known.
- Keep the DNS record DNS-only for direct Traefik origin validation.

## Operator sequence

1. Run the Debian baseline verifier and the K3s node verifier. Confirm one
   Ready node, healthy bundled components, Traefik as the default
   IngressClass, no stale test resources, and no existing cert-manager or
   unexpected Cloudflare Secret resources.
2. Run [`infra/cert-manager/install.sh`](../infra/cert-manager/install.sh).
   Stop if any cert-manager CRD, controller, cainjector, or webhook check
   fails.
3. Create the Cloudflare Secret with
   [`create-cloudflare-secret.sh`](../infra/cert-manager/create-cloudflare-secret.sh)
   from a protected file. Verify only presence and the expected key.
4. Render the operator hostname/email configuration and apply only the
   `staging` Kustomize root. Confirm CertificateRequest success, a valid
   Order, a completed Challenge, the staging Certificate, and TXT cleanup.
5. Apply the rendered `tls-validation` Kustomize root. It contains only one
   pinned `traefik/whoami` Deployment, Service, and Traefik Ingress. The
   staging chain is intentionally untrusted; use an explicit trust override
   only for this route check and inspect the issuer/hostname separately.
6. Delete the disposable Deployment, Service, and Ingress after the route
   proof. Do not retain application test resources.
7. Apply the `production` Kustomize root only after staging succeeds. Confirm
   the production issuer, certificate, Order, Challenge, TXT cleanup, correct
   SAN, and normal TLS verification for the selected host.
8. Use staging for any repeated lifecycle/reissuance test. Do not deliberately
   consume production issuance quota.
9. Re-run the cert-manager verifier and perform one controlled K3s reboot.
   Repeat the K3s verifier, cert-manager verifier, issuer/certificate checks,
   and direct TLS request. A reboot alone must not require reissuance.

## Recovery boundary

cert-manager custom resources, ACME account keys, Certificate private keys, and
certificate chains are Kubernetes objects and therefore live in the K3s
datastore included in the established recovery boundary. The Cloudflare API
token Kubernetes Secret is encrypted at rest by K3s secrets encryption, but the
private K3s backup contains that token indirectly. Protect backups as secret
material and never put their paths, contents, or certificate keys in Git or
public logs. If a backup is lost or exposed, revoke and rotate the Cloudflare
token as an operator security procedure, then recreate the Secret and verify
issuance before relying on renewal.

No token, private key, generated certificate, or real deployment hostname is
checked in by this baseline.
