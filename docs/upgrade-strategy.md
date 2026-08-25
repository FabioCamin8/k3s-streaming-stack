# Upgrade strategy

Updates are proposed in Git and applied through a reviewed Kubernetes rollout. Runtime auto-update agents are intentionally not used.

```text
upstream release -> Renovate detects reference -> GitHub PR -> review and proof -> merge -> rollout
```

## Renovate policy

[`renovate.json`](../renovate.json) enables the Kubernetes manager for files beneath `k8s/`, uses Renovate's recommended baseline, and disables automerge. The initial repository has no workload image references yet, so no image PR should be expected until verified manifests are added.

When manifests land:

- Prefer an immutable versioned tag or digest that the upstream project documents.
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

Remux is early-stage software and receives an explicit compatibility review even for apparently small updates. Automerge remains disabled, especially for Remux.

## K3s and certificate upgrades

K3s and cert-manager upgrades are planned changes, not image-only dependency bumps. Record the current version, read the upstream release notes, back up local application data, and upgrade one layer at a time. Validate node health, Traefik routing, certificate issuance/renewal, application persistence, and rollback before proceeding.

The single-node design means an upgrade is a maintenance event. A snapshot may help recover the VM, but it does not replace an application-aware backup or a tested restore procedure.
