# Architecture

## Platform boundary

The deployment target is one Debian 13 VM on Proxmox VE. The VM is the Kubernetes node and owns the guest kernel, cgroups, network namespace, and storage boundary. K3s runs as the node distribution and supplies its bundled containerd, CoreDNS, Traefik v3, ServiceLB, and local-path provisioner.

There is no Docker or Podman dependency. There is no second ingress controller. There is no claim of high availability: loss of the VM takes the cluster and its local data offline.

## Request and data paths

1. A client resolves an application hostname through Cloudflare DNS.
2. DNS traffic may be DNS-only or HTTP may be proxied by Cloudflare, according to the deliberate choice recorded in [`docs/cloudflare.md`](cloudflare.md).
3. Traefik receives HTTP(S) traffic through the K3s networking path and routes by hostname to the selected Kubernetes Service.
4. AIOStreams handles stream aggregation and keeps its application data under persistent `/app/data`.
5. Remux presents the intended Jellyfin-compatible API/catalog/search surface and keeps its application data under persistent `/data`.
6. Remux may call AIOStreams. When it can return an HTTP redirect to an upstream or debrid URL, the client follows that redirect and video bytes bypass the K3s host.

The persistence paths and workload relationships are architectural decisions from the project brief. They must still be checked against the current upstream images before a manifest encodes them.

## Kubernetes ownership

The planned Kubernetes layout is intentionally small:

- `k8s/infrastructure/`: cluster-level configuration that is proven necessary, such as supported Traefik and certificate integration.
- `k8s/aiostreams/`: AIOStreams Deployment, Service, persistent storage, and only verified configuration.
- `k8s/remux/`: Remux Deployment, Service, persistent storage, and only verified configuration.

The directories currently contain documentation rather than guessed YAML. A file belongs in them only after its image, port, probe, storage, security, and configuration assumptions have a primary-source basis.

## Trust boundaries

- The VM is the infrastructure boundary; Proxmox and the guest are separate administration domains.
- Traefik is the only public ingress boundary.
- Cloudflare DNS-01 is an external certificate-validation dependency, not an application secret store.
- The Cloudflare API token is a deployment secret scoped to one zone and DNS operations only.
- Local-path volumes are node-local state and must be backed up independently.
- A redirect target is external and untrusted input. Remux behavior must be tested for safe redirect handling before production use.

## Failure and recovery invariants

- A failed certificate issuance must not cause production credentials to be committed or copied into manifests.
- Staging ACME validation precedes production issuance.
- An image update is not complete until the workload is healthy and the previous version remains recoverable.
- A VM snapshot or application backup is not assumed to be a substitute for both; the recovery procedure must identify which state each protects.
- A one-replica workload is an explicit availability tradeoff, not an accidental default hidden by a controller.
