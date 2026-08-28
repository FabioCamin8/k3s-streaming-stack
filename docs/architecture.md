# Architecture

## Platform boundary

The deployment target is one Debian 13 VM on Proxmox VE. The reproducible
Cloud-Init template, full-clone Debian baseline, pinned K3s node, and
cert-manager DNS-01/TLS platform have been executed and validated. K3s
supplies its bundled containerd, CoreDNS, Traefik v3, ServiceLB, local-path
provisioner, and metrics-server. AIOStreams is the current one-replica
application workload; Remux remains future work.

There is no Docker or Podman dependency. There is no second ingress controller. There is no claim of high availability: loss of the VM takes the cluster and its local data offline.

## Proxmox and Debian bootstrap

The reproducible infrastructure path is:

```text
official Debian 13 genericcloud image
    -> debian13-cloud reusable template
    -> full clone
    -> k3s01 project VM profile
    -> Cloud-Init
    -> Debian baseline verification
```

The template is generic Debian only. It does not contain K3s, Docker, Podman,
Kubernetes packages, AIOStreams, Remux, cert-manager, or application
configuration. The template's Cloud-Init configuration supplies the default
user, password, and SSH key; the clone workflow can override the user and can
override the SSH key only when explicitly requested. Proxmox-generated
Cloud-Init still supplies the per-instance hostname, DHCP networking, and DNS.
Project vendor-data supplies the small OS package baseline, SSH hardening,
QEMU guest-agent setup, and generic OS initialization. SSH password
authentication remains disabled by vendor-data.

The network underlay is MTU 9000 end to end: physical network, Proxmox
physical NIC, `vmbr`, VirtIO NIC, and Debian guest. The VM NIC declares MTU
9000 explicitly. The K3s CNI/Flannel overlay MTU is not guessed or configured
before installation. The validated single-node result observes Flannel VXLAN
with `cni0=8950`, `flannel.1=8950`, and temporary Pod `eth0=8950`; these values
are measured overlay behavior, not an assumption that the CNI should use 9000.
Multi-node overlay transport remains unvalidated.

## Request and data paths

1. A client resolves an application hostname through Cloudflare DNS. An answer and a DNS-only record do not by themselves prove Internet reachability.
2. If the origin is reachable, DNS-only traffic goes directly to the operator-selected public port. A router/NAT rule maps that port to Traefik's internal HTTPS port 443; if HTTP proxying is deliberately enabled, traffic first enters through Cloudflare's edge, according to the choice recorded in [`docs/cloudflare.md`](cloudflare.md).
3. Traefik receives HTTP(S) traffic through the reachable K3s networking path and routes by hostname to the selected Kubernetes Service.
4. Traefik routes the public AIOStreams HTTPS host to its ClusterIP Service.
5. AIOStreams handles stream aggregation and keeps its application data and default disk caches under persistent `/app/data`.
6. Remux is a future client-facing layer. It may call AIOStreams and, where supported, return an HTTP redirect to an upstream/debrid URL so video bytes bypass the K3s host.

The persistence paths and workload relationships are architectural decisions from the project brief. They must still be checked against the current upstream images before a manifest encodes them.

## External HTTPS exposure contract

The operator-facing public port is separate from the Kubernetes-facing Traefik
entrypoint. `AIOSTREAMS_PUBLIC_HTTPS_PORT` is part of the AIOStreams
configuration and therefore controls the public `BASE_URL`; it does not change
the Service, Ingress hostname, certificate hostname, or Traefik `websecure`
listener.

| Mode | Public URL | WAN listener | NAT target | Kubernetes contract |
| --- | --- | --- | --- | --- |
| Standard direct HTTPS | `https://stream.example.com` | TCP/443 | Traefik TCP/443 | Ingress host `stream.example.com`, Traefik `websecure` 443 |
| Alternate direct HTTPS | `https://stream.example.com:8443` | TCP/8443 | Traefik TCP/443 | Ingress host `stream.example.com`, Traefik `websecure` 443 |

Port 443 has the broadest client and network compatibility. Port 8443 can
preserve WAN 443 for an existing service, but unusually restrictive client
networks may block it. DNS records contain no port, and DNS-01 certificate
issuance works identically in both modes. The public NAT/firewall rule is an
operator concern; the repository does not enable UPnP, expose management ports,
or create a broad node firewall rule.

## Kubernetes ownership

The Kubernetes layout is intentionally small:

- `k8s/infrastructure/`: cluster-level configuration that is proven necessary, such as supported Traefik and certificate integration.
- `k8s/aiostreams/`: the implemented AIOStreams Deployment, Service, local-path PVC, private-rendered Secret, and Traefik Ingress.
- `k8s/remux/`: reserved for the future Remux workload after its upstream contract is verified.

Every workload file belongs here only after its image, port, probe, storage,
security, and configuration assumptions have a primary-source basis.

## Trust boundaries

- The VM is the infrastructure boundary; Proxmox and the guest are separate administration domains.
- Traefik is the intended sole ingress boundary; external reachability still depends on DNS, firewall, NAT, and routing outside Kubernetes and is not implied by an Ingress object.
- AIOStreams native authentication protects human/admin/configuration surfaces;
  public Stremio machine paths are not blanket-protected by an external
  ForwardAuth. Future Authelia integration must remain selective.
- AIOStreams accepts forwarded client IP information only when the direct
  Traefik source is in the exact private `TRUSTED_IPS` range observed for this
  K3s topology. The operator value is not committed here.
- Cloudflare DNS-01 is an external certificate-validation dependency, not an application secret store.
- The Cloudflare API token is a deployment secret scoped to one zone and DNS operations only.
- Local-path volumes are node-local state and must be backed up independently.
- A redirect target is external and untrusted input. Remux behavior must be tested for safe redirect handling before production use.

## Future edge consolidation

This is a roadmap objective only and is not deployed by the AIOStreams
milestone. A future edge could accept one public TCP/443 listener and route by
hostname, for example:

```text
Internet
   |
TCP/443
   |
front proxy / gateway
   +-- aio.example.com ------> Traefik/AIOStreams
   +-- media.example.com ----> MediaFlow or another service
   +-- remux.example.com ----> Traefik/Remux
```

The later design review must choose between TLS termination at the front,
TLS passthrough/SNI routing, K3s Traefik as the consolidation point, or an
existing external edge. This milestone introduces no HAProxy, nginx, Caddy,
additional Traefik, or Envoy component and does not imply that any front proxy
is already deployed.

## Failure and recovery invariants

- A failed certificate issuance must not cause production credentials to be committed or copied into manifests.
- Staging ACME validation precedes production issuance.
- An image update is not complete until the workload is healthy and the previous version remains recoverable.
- A mutable `latest` tag means a Deployment ReplicaSet rollback alone does not
  guarantee recovery of the previous image bytes; a future updater must retain
  a known immutable digest or another proven recovery mechanism.
- A VM snapshot or application backup is not assumed to be a substitute for both; the recovery procedure must identify which state each protects.
- A one-replica workload is an explicit availability tradeoff, not an accidental default hidden by a controller.
