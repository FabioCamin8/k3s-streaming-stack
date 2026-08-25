# Proxmox VM contract

The target is a conventional Debian 13 VM under a current Proxmox VE release. Community Scripts may be a convenient bootstrap aid, but it is optional and not a project requirement. The authoritative choices are the VM properties below. The repository implements this contract with a dated official Debian genericcloud image, a reusable `debian13-cloud` template, and a full clone for `k3s01`.

| Property | Target | Rationale |
| --- | --- | --- |
| Guest | Debian 13 | Current stable Debian base with a conventional kernel and package ecosystem. |
| Machine | Q35 | Modern virtual chipset and PCIe-oriented device model. |
| Firmware | OVMF/UEFI | Standard UEFI guest boot path and closer parity with modern servers. |
| CPU | 4 vCPU, type `host` | Enough initial headroom for K3s plus two small workloads; exposes host CPU features. |
| Memory | 6144 MiB fixed | Predictable capacity for the node and applications without ballooning variability. |
| Disk | 40 GiB | Initial room for the OS, container images, local-path data, and logs; monitor growth. |
| Storage bus | VirtIO SCSI Single where practical | Efficient paravirtualized storage with a clear device boundary. |
| I/O thread | Enabled where appropriate | Keeps storage I/O scheduling from unnecessarily contending with the guest. |
| Discard/TRIM | Enabled | Allows reclaiming unused blocks when the backing storage supports it. |
| Network | VirtIO NIC, MTU 9000 | Matches the Proxmox jumbo-frame underlay and is declared explicitly in the VM configuration. |
| Addressing | DHCP reservation preferred | Stable identity is managed by the network while guest configuration stays portable. |
| Provisioning | Cloud-Init | Repeatable initial user, SSH, package, and network setup without hand-editing a guest. |
| Guest integration | QEMU Guest Agent | Better lifecycle and IP/state visibility from Proxmox. |

## Deliberate non-choices

- This is a VM, not an LXC container. Do not follow an LXC-specific K3s recipe for this deployment.
- The guest does not run Docker or Podman alongside K3s.
- The guest address is not embedded in this public repository.
- No static address is configured inside the guest by this repository; reserve the address in the DHCP service.
- The VM underlay MTU is 9000. The future K3s CNI/Flannel overlay MTU is not assumed to be 9000 and is validated only after K3s installation.

## Template and clone ownership

`infra/proxmox/build-debian-template.sh` downloads and verifies the pinned
Debian 13 genericcloud image, creates `debian13-cloud` with Q35, OVMF/UEFI,
VirtIO SCSI Single, an imported disk, Cloud-Init, serial console, QEMU agent,
and an explicit VirtIO NIC MTU. It refuses an existing VMID or name and never
deletes a partial VM automatically.

`infra/proxmox/spawn-k3s-node.sh` performs a full clone and applies the
project-specific profile: `k3s01`, 4 vCPU, host CPU, 6144 MiB fixed RAM,
ballooning disabled, 40 GiB `scsi0`, VirtIO on the configurable bridge with
explicit MTU 9000 by default, DHCP, Cloud-Init user and public key, QEMU
agent, and start-on-boot. It refuses an existing target VMID or name and can
leave the new clone powered off with `--no-start`.

The template remains reusable and Kubernetes-independent. K3s installation is
the next milestone, after the guest baseline is verified.

## Build checklist

Before installing K3s, build the template and clone the node with the scripts
in [`infra/proxmox/`](../infra/proxmox/), then run the guest verification script
from [`scripts/verify/debian-node.sh`](../scripts/verify/debian-node.sh).
Confirm:

- UEFI boot succeeds from the chosen Debian 13 cloud image or installer.
- The guest receives its reserved address through DHCP, has correct DNS, and its primary interface has MTU 9000.
- The QEMU Guest Agent is installed and enabled in the guest and enabled in Proxmox.
- Disk discard behavior is supported by the storage path.
- Time synchronization works; ACME validation depends on correct time.
- The VM has no public credentials or private configuration copied from this repository.

The repository documents the target but does not create or modify a Proxmox VM.
