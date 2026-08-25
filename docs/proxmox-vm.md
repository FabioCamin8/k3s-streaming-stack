# Proxmox VM contract

The target is a conventional Debian 13 VM under a current Proxmox VE release. Community Scripts may be a convenient bootstrap aid, but it is optional and not a project requirement. The authoritative choices are the VM properties below.

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
| Network | VirtIO NIC, MTU 1500 | Efficient virtual networking and a conservative path MTU. |
| Addressing | DHCP reservation preferred | Stable identity is managed by the network while guest configuration stays portable. |
| Provisioning | Cloud-Init | Repeatable initial user, SSH, package, and network setup without hand-editing a guest. |
| Guest integration | QEMU Guest Agent | Better lifecycle and IP/state visibility from Proxmox. |

## Deliberate non-choices

- This is a VM, not an LXC container. Do not follow an LXC-specific K3s recipe for this deployment.
- The guest does not run Docker or Podman alongside K3s.
- The guest address is not embedded in this public repository.
- No static address is configured inside the guest by this repository; reserve the address in the DHCP service.

## Build checklist

Before installing K3s, record the VM configuration in the private deployment notes and confirm:

- UEFI boot succeeds from the chosen Debian 13 cloud image or installer.
- The guest has the reserved address, correct DNS, and an MTU of 1500.
- The QEMU Guest Agent is installed and enabled in the guest and enabled in Proxmox.
- Disk discard behavior is supported by the storage path.
- Time synchronization works; ACME validation depends on correct time.
- The VM has no public credentials or private configuration copied from this repository.

The repository documents the target but does not create or modify a Proxmox VM.
