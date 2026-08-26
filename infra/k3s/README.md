# Pinned K3s bootstrap

This layer starts only after the Debian template/clone baseline has passed. It
installs one K3s server on `k3s01`; it does not deploy application workloads,
cert-manager, Cloudflare configuration, or application ingress resources.

## Release contract

`versions.env` is the single repository contract for the release:

| Property | Value |
| --- | --- |
| K3s | `v1.36.3+k3s1` |
| Architecture | amd64 |
| Datastore | default embedded SQLite |
| Secrets encryption | enabled at first server start; K3s default `aescbc` provider |
| CNI | default Flannel; MTU is discovered after installation |

The installer downloads the release binary, the upstream checksum manifest, and
the official installer at the same release tag. It verifies the expected
checksums recorded in `versions.env`, then invokes the verified installer with
`INSTALL_K3S_SKIP_DOWNLOAD=true`. A moving stable channel cannot silently
replace the pinned binary.

The installer refuses an existing K3s binary, service, uninstall script, or
data directory. It never performs uninstall/reinstall cleanup automatically.

## Guest commands

Run on `k3s01` as root after the Debian verifier passes:

```sh
./infra/k3s/install.sh --dry-run
./infra/k3s/install.sh
```

The service is created and started by the supported K3s installer. Verify it
with the checked-in verifier, supplying the version contract explicitly when
the script has been copied to the guest:

```sh
EXPECTED_K3S_VERSION=v1.36.3+k3s1 \
EXPECTED_NODE_NAME=k3s01 \
sudo -E ./scripts/verify/k3s-node.sh
```

The verifier checks the node and bundled system components, default storage and
IngressClass, metrics-server, Traefik's local edge response, the primary MTU,
and observed CNI interfaces/MTUs. A CNI MTU different from 9000 is expected to
be possible; it is reported and checked for underlay consistency, not forced.

## Validated single-node result

The pinned bootstrap was executed on the disposable `k3s01` Debian 13 VM and
completed with one Ready node. The bundled CoreDNS, Traefik, ServiceLB,
local-path provisioner, and metrics-server workloads became healthy. The
default `local-path` StorageClass bound a temporary PVC and the mounted test
Pod successfully wrote and read data. Temporary networking tests also passed
for Pod IP allocation, Kubernetes and external DNS, Kubernetes Service
networking, and outbound HTTP; all test resources were deleted afterwards.

The observed networking contract is:

| Interface | Observed MTU |
| --- | ---: |
| Debian primary NIC | 9000 |
| `cni0` | 8950 |
| `flannel.1` | 8950 |
| temporary Pod `eth0` | 8950 |

The backend is the default Flannel VXLAN backend (`flannel.1`, VXLAN ID 1,
UDP 8472). The underlay value 9000 is not copied into the overlay. This is a
single-node result: the overlay was locally inspected and tested, but
multi-node VXLAN transport has not been validated.

Traefik's Service exposed ports 80 and 443 through ServiceLB, and both local
edge checks returned the expected 404 no-route response. One controlled reboot
completed successfully: QEMU Guest Agent, SSH, K3s, all bundled components,
the observed MTUs, and `kubectl top node` recovered afterward.

The checked-in Debian verifier is a pre-K3s gate and intentionally fails when
K3s or its bundled containerd is present. After K3s installation, use
`scripts/verify/k3s-node.sh` together with the OS persistence checks instead.

## Secrets encryption and recovery

K3s creates the encryption configuration at:

```text
/var/lib/rancher/k3s/server/cred/encryption-config.json
```

Protect this file as secret material. The default SQLite database,
`/var/lib/rancher/k3s/server/db/`, and the server token,
`/var/lib/rancher/k3s/server/token`, must be backed up together. Do not copy
any of these files into Git or public reports.

The validated server used the default embedded SQLite datastore (`state.db`)
and enabled secrets encryption at first start. `k3s secrets-encrypt status`
reported encryption enabled, the active AES-CBC `aescbckey`, and matching
server encryption hashes. Back up the database, token, and encryption
configuration together through a private operator-controlled process.
