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

## Secrets encryption and recovery

K3s creates the encryption configuration at:

```text
/var/lib/rancher/k3s/server/cred/encryption-config.json
```

Protect this file as secret material. The default SQLite database,
`/var/lib/rancher/k3s/server/db/`, and the server token,
`/var/lib/rancher/k3s/server/token`, must be backed up together. Do not copy
any of these files into Git or public reports.
