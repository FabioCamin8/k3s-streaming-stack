# ADR-0005: Reproducible Debian Cloud-Init template

- Status: Accepted
- Date: 2026-08-25

## Context

The first K3s node must be disposable before Kubernetes and application
configuration are introduced. Hand-built Proxmox VMs make the Debian baseline,
SSH state, guest integration, and disk layout difficult to reproduce or
recover. A large image mutation step would also obscure the provenance of the
operating system and add another maintenance surface.

## Decision

Use the official, dated Debian 13 `genericcloud` image as the input to a small
native Proxmox builder. Verify its SHA-512 digest, attach a minimal Cloud-Init
vendor-data snippet, and convert the result to the reusable `debian13-cloud`
template. Create `k3s01` as a full clone with its project-specific CPU,
memory, disk, network, user, SSH key, DHCP, and start-on-boot profile.

Keep Proxmox-generated Cloud-Init data for instance-specific hostname, user,
SSH key, DHCP networking, and DNS. Keep vendor-data limited to generic Debian
baseline packages, SSH hardening, QEMU guest-agent setup, and generic OS
initialization.

The VM underlay MTU is explicitly 9000. K3s CNI/Flannel MTU is deliberately
left undiscovered and unconfigured until the later K3s milestone.

## Consequences

Full clones do not depend on the template disk lifecycle, so a node can be
recreated from a reviewed input. Separating the generic OS baseline from the
project VM profile reduces configuration drift, simplifies disaster recovery,
and leaves a reusable Debian template for future nodes. The tradeoff is that
the builder needs native Proxmox access and storage capable of holding both VM
images and the Cloud-Init snippet.

## Alternatives considered

- Hand-built VM: simpler once, but not repeatable and prone to baseline drift.
- `virt-customize` or a heavily mutated disk: adds image-maintenance and
  provenance complexity without a requirement that Cloud-Init cannot satisfy.
- Linked clone: saves storage but couples the disposable node to the template
  lifecycle; a full clone is the safer recovery boundary.
- Terraform, Ansible, or Packer: useful at larger scale, but unnecessary
  framework and state for this single-node bootstrap milestone.
