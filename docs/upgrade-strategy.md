# Upgrade strategy

The current AIOStreams workload deliberately follows the upstream stable
`latest` tag with `imagePullPolicy: Always`. Runtime auto-update agents are not
deployed yet; future automation must be digest-aware and health-gated.

```text
upstream release -> Renovate detects reference -> GitHub PR -> review and proof -> merge -> rollout
```

## Renovate policy

[`renovate.json`](../renovate.json) enables the Kubernetes manager for files beneath `k8s/`, uses Renovate's recommended baseline, and disables automerge. The AIOStreams reference is intentionally mutable, so Renovate is not treated as the runtime updater for that image; platform and future immutable references remain reviewable.

When manifests land:

- Prefer an immutable versioned tag or digest that the upstream project documents. AIOStreams `latest` is the explicit current exception.
- Keep image references easy for Renovate's Kubernetes manager to identify.
- Keep AIOStreams and Remux updates reviewable separately when their compatibility risk differs.
- Do not merge an image update solely because it is available; inspect release notes and run the relevant smoke checks.

## Review gates

Every workload update should answer:

- Does the new image exist and match the intended architecture?
- Did the upstream change ports, environment variables, authentication, storage, or health behavior?
- Does the image still run without Docker socket or privileged access?
- Does the persistent data format migrate safely, and is a backup available?
- Does ingress, TLS, authentication, and the Remux redirect path still work?
- Is rollback to the previous tag or digest documented and possible?

For AIOStreams specifically, record the observed runtime digest, verify the
DB-backed health endpoint and native authentication, confirm the local-path
data boundary, and retain a known immutable previous image before enabling any
automatic updater. A Deployment rollback alone is insufficient when `latest`
has moved.

Remux is early-stage software and receives an explicit compatibility review even for apparently small updates. Automerge remains disabled, especially for Remux. Keel is only a future candidate; it is not installed or authorized by this milestone.

## K3s and certificate upgrades

K3s and cert-manager upgrades are planned changes, not image-only dependency bumps. Record the current version, read the upstream release notes, back up local application data, and upgrade one layer at a time. Validate node health, Traefik routing, certificate issuance/renewal, application persistence, and rollback before proceeding.

The single-node design means an upgrade is a maintenance event. A snapshot may help recover the VM, but it does not replace an application-aware backup or a tested restore procedure.
