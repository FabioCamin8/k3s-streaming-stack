# Bootstrap sequence

This is the intended sequence for a fresh deployment. It is documentation only; repository bootstrap work does not install K3s or modify any machine.

## Prerequisites

- A Proxmox VE VM matching [`proxmox-vm.md`](proxmox-vm.md).
- A DHCP reservation and working guest DNS.
- A Cloudflare-managed zone and a hostname plan using placeholders until deployment, for example `aiostreams.stream.example.com` and `remux.stream.example.com`.
- A private operator workstation with `kubectl`, `helm` if needed by the selected installation path, and Git.
- A backup destination for application data and a tested recovery procedure.

## Sequence

1. Build the VM and complete the guest checks in `proxmox-vm.md`.
2. Select a supported K3s release, record the exact version in private deployment notes, and install the single server using the [official K3s quick-start documentation](https://docs.k3s.io/quick-start). Do not disable the bundled Traefik installation.
3. Confirm the node, CoreDNS, Traefik, ServiceLB, and local-path components are healthy before adding workloads. Record the K3s version and rendered component versions.
4. Install cert-manager using its [official installation documentation](https://cert-manager.io/docs/installation/), selecting and recording an exact release. Do not create a production issuer before staging validation is complete.
5. Create the Cloudflare API token out of band with the permissions and zone scope in [`cloudflare.md`](cloudflare.md). Deliver it to the cluster through an operator-controlled secret workflow; never place it in this repository.
6. Apply only the verified infrastructure configuration. K3s's supported [HelmChartConfig mechanism](https://docs.k3s.io/helm) is the intended seam for bundled Traefik configuration.
7. Verify current AIOStreams and Remux upstream contracts before adding their manifests: image reference, tag/digest behavior, listening port, health endpoint, required environment, persistence path, and startup/shutdown behavior.
8. Deploy one workload at a time with one replica, local persistent storage, explicit ingress, and native application authentication/configuration protection.
9. Validate using a Let's Encrypt staging issuer, private client checks, persistence restart tests, authentication checks, and Remux redirect behavior. Only then switch to production certificates.
10. Record the observed release versions, image digests, backup location, and rollback command in private deployment notes. Promote only the redacted, reproducible parts to Git.

## Stop conditions

Stop before applying a manifest when any of these are unknown:

- The upstream image name or tag is not confirmed by the primary project.
- The container port, health behavior, or persistence path is guessed.
- A required application secret or credential has no private delivery path.
- The certificate issuer would use a production ACME endpoint before staging succeeds.
- The proposed configuration requires Docker socket access, a second runtime, or a storage system outside v0.1 scope.

## First verification pass

The first deployment pass should prove the smallest useful path: the node is healthy, Traefik routes a non-sensitive test response, staging certificates issue, each application survives a restart with its data intact, and Remux can redirect supported playback without proxying video through the node. A failed proof is a reason to stop and correct the responsible layer, not to add another component.
