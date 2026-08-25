# Proxmox Debian bootstrap

This directory builds the disposable Debian layer that precedes K3s. It does
not install K3s, Docker, Podman, AIOStreams, Remux, cert-manager, or any
Kubernetes manifest.

```text
official Debian 13 genericcloud image
        -> debian13-cloud (reusable generic template)
        -> full clone
        -> k3s01 (project VM profile)
        -> Cloud-Init
        -> Debian baseline verification
```

The template is Debian-specific and application-independent. Its vendor-data
installs only the small OS baseline, enables the QEMU guest agent, and applies
SSH hardening. Proxmox-generated Cloud-Init remains responsible for the
instance hostname, user, public key, DHCP networking, and DNS.

## Requirements

Run the scripts as root on a Proxmox VE host with the repository checkout
available. The builder requires an image-capable storage and a snippets-capable
storage. They can be different storage IDs; neither is assumed to be named
`local-lvm`.

Inspect the available choices without changing anything:

```sh
pvesm status --content images
pvesm status --content snippets
ip link show vmbr0
```

The scripts refuse existing VMID or VM-name collisions. If a failure occurs
after VM creation has started, they do not delete the partial resource; inspect
it before retrying.

## Build the template

`versions.env` pins a dated official Debian 13 genericcloud amd64 image and
its SHA-512 checksum source and expected digest. The builder downloads to a
secure temporary directory, verifies the digest, installs the vendor-data
snippet without overwriting a different existing snippet, imports the disk,
and converts the VM to a template.

The default template VMID is `9000`; override it when that ID is occupied.
The builder default bridge and NIC MTU are `vmbr0` and `9000`, respectively.

Use `--dry-run` after supplying the real storage IDs to validate host
prerequisites and print the mutations without downloading or creating a VM.

## Spawn the project VM

The clone is a full clone, so it has no runtime dependency on the template
disk. The default project profile is:

| Property | Default |
| --- | --- |
| Name / VMID | `k3s01` / `9001` |
| CPU | 4 vCPU, `host` |
| Memory | 6144 MiB, ballooning disabled |
| Disk | `scsi0`, resized to 40 GiB |
| NIC | VirtIO on `vmbr0`, explicit MTU 9000 |
| Addressing | Cloud-Init `ip=dhcp` |
| Guest integration | QEMU agent enabled |
| Boot policy | start on boot; starts immediately unless `--no-start` is used |

The clone command requires a public SSH key file. Key contents are read from
that file and are never stored in this repository.

After the VM starts, wait for Cloud-Init before treating it as ready:

```sh
cloud-init status --wait
```

If it fails, inspect `cloud-init status --long`,
`/var/log/cloud-init.log`, and `/var/log/cloud-init-output.log` before making
another attempt.

## Network contract

The physical underlay, Proxmox bridge, VirtIO NIC, and Debian guest are
expected to use MTU 9000. The VM provisioning path declares `mtu=9000`
explicitly; it does not rely on bridge inheritance.

This is only the VM underlay. The future K3s CNI/Flannel overlay MTU is not
configured here and must be discovered and validated after K3s is installed.
An overlay MTU must not be assumed to be 9000 merely because the underlay is
9000.

## Guest verification

Copy `scripts/verify/debian-node.sh` to the guest and run it after the
Cloud-Init wait. It reports PASS, WARN, and FAIL, and returns non-zero on a
baseline failure. It checks Debian 13, Cloud-Init completion, QEMU agent,
effective SSH hardening, disk capacity, default route, DNS, explicit MTU 9000,
absence of Docker/Podman/containerd/CRI-O packages, and time synchronization.
