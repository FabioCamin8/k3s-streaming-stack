# Bootstrap sequence

This is the intended sequence for a fresh deployment. The current repository
milestone creates no Proxmox resources automatically during review; the
commands below are the operator-run next step. K3s and applications remain
separate later milestones.

## Prerequisites

- A Proxmox VE host with one image-capable storage and one snippets-capable storage.
- A local copy of the repository on that Proxmox host.
- An operator SSH public-key file supplied out of band.
- A DHCP reservation and working guest DNS.
- A private operator workstation with Git and, later, `kubectl`/`helm` if needed by the selected installation path.

## Current milestone: Debian template and VM

1. Inspect storage and bridge choices with `pvesm status --content images`,
   `pvesm status --content snippets`, and `ip link show vmbr0`. Do not assume a
   storage name.
2. Run the template builder from [`infra/proxmox/README.md`](../infra/proxmox/README.md)
   with explicit image and snippet storage IDs. The builder verifies the
   dated Debian image checksum, configures the generic `debian13-cloud`
   template, and refuses collisions.
3. Run the clone builder with an explicit `SSH_PUBLIC_KEY_FILE`. It creates a
   full `k3s01` clone, applies `ip=dhcp`, declares the VM NIC MTU as 9000, and
   starts the VM unless `--no-start` is selected.
4. From the guest, run `cloud-init status --wait` before considering it ready.
5. Copy and run `scripts/verify/debian-node.sh`. Investigate any failure using
   `cloud-init status --long`, `/var/log/cloud-init.log`, and
   `/var/log/cloud-init-output.log`.
6. Perform the explicit OS patching gate before K3s. Keep
   `package_upgrade: false` in vendor-data, then run `apt-get update`,
   `apt-get full-upgrade`, reboot if `/var/run/reboot-required` exists, and
   rerun the Debian verifier.
7. Stop here. Do not install K3s until the post-upgrade Debian verification is
   passing and the template/clone result has been reviewed.

## Sequence

1. After the Debian baseline passes, select a supported K3s release, record the exact version in private deployment notes, and install the single server using the [official K3s quick-start documentation](https://docs.k3s.io/quick-start). Do not disable the bundled Traefik installation.
2. Measure and validate the resulting CNI/Flannel overlay MTU; do not copy the 9000-byte underlay value blindly.
3. Confirm the node, CoreDNS, Traefik, ServiceLB, and local-path components are healthy before adding workloads. Record the K3s version, overlay MTU, and rendered component versions.
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
