# K3s `v1.36.3+k3s1` bootstrap contract

Scope: primary-source contract for an online, single-node Debian server. This note records documented behavior and release artifacts; it is not an installation record.

## Release and artifacts

The official GitHub release for tag `v1.36.3+k3s1` exists and is neither a draft nor a prerelease. The release updates Kubernetes to `v1.36.3` and publishes these relevant URLs:

| Target | Binary | Air-gap image archive | Checksum manifest |
|---|---|---|---|
| x86_64 / amd64 | [k3s](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/k3s) | [amd64 `.tar.zst`](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/k3s-airgap-images-amd64.tar.zst) | [sha256sum-amd64.txt](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/sha256sum-amd64.txt) |
| arm64 / aarch64 | [k3s-arm64](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/k3s-arm64) | [arm64 `.tar.zst`](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/k3s-airgap-images-arm64.tar.zst) | [sha256sum-arm64.txt](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/sha256sum-arm64.txt) |
| armhf | [k3s-armhf](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/k3s-armhf) | [arm `.tar.zst`](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/k3s-airgap-images-arm.tar.zst) | [sha256sum-arm.txt](https://github.com/k3s-io/k3s/releases/download/v1.36.3%2Bk3s1/sha256sum-arm.txt) |

The amd64 manifest records `2f98a9f8fe5782479ee2d54e70a1b10a7f6fd4cae8d38ed3098452dc6eed76b5` for `k3s`; the arm64 manifest records `c9a209103f480f163b7c6a56f00862b4481927b284dc29a3716bb70d886691a8` for `k3s-arm64`. The [release API record](https://api.github.com/repos/k3s-io/k3s/releases/tags/v1.36.3%2Bk3s1) is the authoritative asset listing and also exposes GitHub asset digests.

## Supported pinned installation

K3s documents the `https://get.k3s.io` service installer and version pinning with `INSTALL_K3S_VERSION`. A bootstrap-shaped command is:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v1.36.3+k3s1' sh -s - server --secrets-encryption
```

This command is documented here as a contract example only; it was not run. With no `K3S_URL`, the installer configures a server. The current official [installer script](https://get.k3s.io) uses the GitHub release-download prefix, percent-encodes `+` in the tag, downloads `sha256sum-<arch>.txt`, and verifies the downloaded `k3s` binary against the matching manifest entry. `INSTALL_K3S_COMMIT` is documented for developer/QA temporary artifacts, not a released-version pin.

`INSTALL_K3S_VERSION` pins the K3s release artifact; the `https://get.k3s.io` installer endpoint itself is not a version-pinned URL.

For durable configuration, use `/etc/rancher/k3s/config.yaml` (and its drop-ins) rather than relying only on installer arguments: installer-supplied values are persisted in the service, and omitted values can be lost when the installer is rerun. The [configuration guide](https://docs.k3s.io/installation/configuration) also describes direct binary downloads, but characterizes that path as useful for quick tests rather than permanent service installation.

## Single-node defaults and bundled components

- A single-node server is a complete Kubernetes cluster: datastore, control plane, kubelet, and container runtime are present on that node. The default datastore is embedded SQLite when no other datastore is configured; `--cluster-init` selects embedded etcd instead.
- K3s-managed packaged AddOns are `coredns`, `traefik`, `local-storage`, and `metrics-server`; the embedded `servicelb` controller is also enabled by default. CoreDNS and Traefik are deployed automatically, and ServiceLB uses host ports. Traefik therefore claims ports 80/443 through ServiceLB unless disabled or customized. Packaged manifests are K3s-managed and should not be edited in place.
- The default server network settings are pod CIDR `10.42.0.0/16`, service CIDR `10.43.0.0/16`, and Flannel VXLAN. Disable or replace packaged components only with the corresponding documented flags, consistently across servers if the topology later grows.
- The release bundle identifies Kubernetes `v1.36.3`, containerd `v2.3.2-k3s2`, Flannel `v0.28.4`, Traefik `v3.7.8`, CoreDNS `v1.14.6`, metrics-server `v0.9.0`, local-path-provisioner `v0.0.36`, Helm controller `v0.17.7`, Kine `v0.16.3`, SQLite `3.53.2`, and embedded etcd `v3.6.14-k3s1`. See the [v1.36 release notes](https://docs.k3s.io/release-notes/v1.36.X).

## Secrets encryption and recovery contract

Passing `--secrets-encryption` at first server start makes K3s generate an AES-CBC key and encryption configuration, then pass that configuration to the kube-apiserver. The generated file is `/var/lib/rancher/k3s/server/cred/encryption-config.json`; `aescbc` is the default provider and `secretbox` is also supported. On a single server, key rotation uses `k3s secrets-encrypt rotate-keys`; wait for the re-encryption stage to finish and verify status. The official command documentation warns that an incorrect rotation procedure can permanently corrupt the cluster.

For a cluster bootstrapped without the flag, the v1.36-era `secrets-encrypt` tool documents an enable flow: `enable`, add `--secrets-encryption`, restart, rotate keys, restart, and verify. A fresh bootstrap with the flag avoids that migration sequence.

Because SQLite is the single-node default, its documented backup is a copy of `/var/lib/rancher/k3s/server/db/`. The server token at `/var/lib/rancher/k3s/server/token` must be backed up and restored with it (or supplied via `--token`); the token is used to encrypt confidential data in the datastore, so a missing or changed token makes the backup unusable. Protect both the database backup and token as secrets.

`k3s etcd-snapshot` is for embedded etcd, not the default SQLite datastore. For an etcd design, snapshots are scheduled by default twice daily with five retained locally and may be sent to S3-compatible storage. Such snapshots include CA private keys and, when enabled, the secrets-encryption configuration and keys; possession of both a snapshot and the server join token can expose encrypted resources. Treat snapshots and the token as high-sensitivity recovery material.

## Debian 13 and v1.36.3 caveats

- The official requirements page says K3s is expected to work on modern Linux and lists Ubuntu/Debian guidance, but it does not state a Debian-13-specific certification or a v1.36.3 Debian-13 exception. The documented baseline for a server is 2 CPU cores and 2 GB RAM, excluding workload needs; an SSD is recommended for datastore performance.
- For a single node using default Flannel VXLAN, protect API port TCP 6443 and do not expose UDP 8472 to the world. TCP 2379-2380 are required only for HA embedded etcd; TCP 10250 is relevant when using metrics-server or adding nodes. Check host firewall policy before bootstrap.
- v1.36.3 has a release-specific Traefik caveat: the chart upgrade to v40 changes the ingress-nginx migration provider name from `kubernetesIngressNginx` to `kubernetesIngressNGINX`. Existing migration configuration must use the new spelling.

## Primary sources

- [K3s v1.36.3+k3s1 GitHub release](https://github.com/k3s-io/k3s/releases/tag/v1.36.3%2Bk3s1) and [release API](https://api.github.com/repos/k3s-io/k3s/releases/tags/v1.36.3%2Bk3s1)
- [Official install script](https://get.k3s.io)
- [Quick Start](https://docs.k3s.io/quick-start), [Configuration Options](https://docs.k3s.io/installation/configuration), and [Requirements](https://docs.k3s.io/installation/requirements)
- [Packaged Components](https://docs.k3s.io/installation/packaged-components), [Networking Services](https://docs.k3s.io/networking/networking-services), and [Cluster Datastore](https://docs.k3s.io/datastore)
- [Secrets Encryption](https://docs.k3s.io/security/secrets-encryption) and [`secrets-encrypt` command](https://docs.k3s.io/cli/secrets-encrypt)
- [Backup and Restore](https://docs.k3s.io/datastore/backup-restore) and [`etcd-snapshot` command](https://docs.k3s.io/cli/etcd-snapshot)
- [v1.36 release notes](https://docs.k3s.io/release-notes/v1.36.X)
