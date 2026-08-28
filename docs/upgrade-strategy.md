# Upgrade strategy

The current AIOStreams workload deliberately follows the upstream stable
`latest` tag with `imagePullPolicy: Always`. Remux is pinned to the stable
versioned `v0.27.0` release with `imagePullPolicy: IfNotPresent`. No runtime
application updater is deployed or claimed by this milestone. `Always` controls
what a newly created or restarted Pod pulls; it does not detect a changed tag,
prove an update was safe, or provide a rollback image.

The current application path is operator-controlled:

```text
operator selects or restarts workload -> latest digest is pulled -> bounded verifier and smoke checks
```

The intended future path is a separate, gated controller flow:

```text
stable release -> digest change observed -> bounded AIOStreams rollout -> health and smoke gates -> retain known recovery digest
```

Remux remains on a separate reviewed update path:

```text
Remux release -> contract and migration review -> controlled rollout -> Jellyfin, stream, and recovery gates
```

## Future automatic application updates

Keel is the leading candidate for the future observer/controller, but it is
not installed or authorized here. Before enabling any updater, the project
must prove all of the following for AIOStreams:

- the release and digest are the intended architecture and compatible with
  the recorded upstream contract;
- database migrations, the `/app/data` persistence boundary, and the durable
  `SECRET_KEY` have a tested recovery procedure;
- the rollout waits for Deployment availability, DB-backed health, native
  authentication/configuration, and an unauthenticated machine manifest check;
- only the intended workload is changed, with bounded retries and an operator
  visible failure state; and
- the previous image is retained by immutable digest (or an equivalently
  proven mechanism) and can be restored after a failed migration or rollout.

The mutable `latest` tag makes a ReplicaSet rollback insufficient: a recreated
Pod can pull newer bytes under the same tag. Automatic rollback is therefore
not claimed until the previous-digest recovery drill passes. Breaking upstream
changes, failed migrations, storage recovery, and exceptional failures may
still require a human. Remux remains more conservative: its versioned tag is
not automatically advanced, and the running image digest must be captured
before an update is accepted.

## Renovate policy

[`renovate.json`](../renovate.json) enables the Kubernetes manager for files
beneath `k8s/`, uses Renovate's recommended baseline, and disables automerge.
Renovate is review-oriented dependency awareness for platform changes and
explicit immutable references; it is not the runtime updater for the mutable
AIOStreams `latest` tag. A Renovate PR is not evidence that an application
rollout is safe.

When manifests land:

- Prefer an immutable versioned tag or digest that the upstream project documents. AIOStreams `latest` is the explicit current exception.
- Keep image references easy for Renovate's Kubernetes manager to identify.
- Keep AIOStreams and Remux updates reviewable separately when their compatibility risk differs.
- Do not merge or roll out an image update solely because it is available; inspect release notes and run the relevant smoke checks.

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

Remux is early-stage software and receives an explicit compatibility review even
for apparently small updates. Review the migration, client, internal
AIOStreams, proxy/redirect, and persistence behavior before changing its pinned
tag. Automerge remains disabled, especially for Remux. Keel is only a future
candidate; it is not installed or authorized by this milestone.

## K3s and certificate upgrades

K3s and cert-manager upgrades are planned changes, not image-only dependency bumps. Record the current version, read the upstream release notes, back up local application data, and upgrade one layer at a time. Validate node health, Traefik routing, certificate issuance/renewal, application persistence, and rollback before proceeding.

The single-node design means an upgrade is a maintenance event. A snapshot may help recover the VM, but it does not replace an application-aware backup or a tested restore procedure.
