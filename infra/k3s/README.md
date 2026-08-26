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

## Recovery baseline

The installed `v1.36.3+k3s1` single-server recovery boundary was inspected on
the running node. It is broader than `state.db` alone:

- `/var/lib/rancher/k3s/` is preserved as a complete tree. This includes the
  SQLite datastore and its `state.db-wal` companion when present, the server
  token, `cred/encryption-config.json`, encryption state, certificates,
  credential kubeconfigs, packaged manifests, and generated server state. The
  `state.db-shm` shared-memory index is deliberately excluded because SQLite
  regenerates it when the database is opened.
- `/etc/rancher/k3s/` is preserved, including the generated client kubeconfig.
- `/etc/systemd/system/k3s.service` and the K3s environment/drop-in paths are
  preserved when present. The current installation has the generated service
  unit and an empty service environment file, with no config YAML or drop-in.
- The pinned K3s binary is not duplicated in the backup. Reprovision the exact
  release with the checked-in bootstrap contract before restoring state.

The deterministic backup layout is:

```text
<backup>/
├── metadata/
│   ├── backup-info.tsv   # non-secret version, topology, timing, and status
│   ├── files.sha256      # SHA-256 per regular backed-up file
│   ├── symlinks.tsv      # symlink paths and targets
│   └── metadata.sha256   # hashes for the three metadata files above
└── server-state/
    ├── var/lib/rancher/k3s/
    ├── etc/rancher/k3s/
    └── etc/systemd/system/k3s.service[.env|.d/]
```

`server-state/` contains the sensitive recovery material. The metadata files
contain no token, certificate, key, kubeconfig, or Secret contents; the hash
manifests contain paths and digests only. `metadata.sha256` covers the metadata
that drives restore decisions, while the data manifest covers the sensitive
`server-state` tree. K3s/containerd directory symlinks are preserved and
recorded in `symlinks.tsv`; they are part of the installed state layout.

The backup uses a conservative stopped-service model. The helper verifies the
active node and secrets-encryption status, stops K3s, waits for it to exit,
copies the state into a mode-700 staging directory, validates SQLite with a
read-only `PRAGMA integrity_check`, writes SHA-256 and symlink manifests,
atomically renames the staging directory to the new destination, restarts K3s,
and waits for one Ready node. It restarts K3s from its failure trap when a
capture fails. Service downtime is accepted for this first single-node
baseline because it avoids copying a live SQLite WAL inconsistently. A backup
fails if the integrity tool is unavailable; this baseline does not accept an
unverified SQLite copy.

Run the capture and verification with a new private destination outside the
checkout:

```sh
sudo ./infra/k3s/backup.sh /secure/backup-root/k3s01-<timestamp>
sudo ./infra/k3s/backup.sh --verify /secure/backup-root/k3s01-<timestamp>
sudo ./scripts/verify/k3s-backup.sh /secure/backup-root/k3s01-<timestamp>
```

The backup contains cluster credentials and encrypted cluster state. Keep it
on encrypted, access-controlled storage separate from the Git checkout; do
not upload it to a public artifact store and do not commit it. The hash
manifest contains paths and digests only, never secret contents.

Restore is deliberately destructive and requires both an exact installed K3s
version and an explicit confirmation flag:

```sh
sudo ./infra/k3s/restore.sh \
  --expected-k3s-version v1.36.3+k3s1 \
  --force-restore \
  /secure/backup-root/k3s01-<timestamp>
```

Restore verifies the backup before stopping K3s, validates `state.db` with a
read-only SQLite `PRAGMA integrity_check`, moves existing K3s state/config and
service files to adjacent timestamped `.pre-restore` paths, restores ownership
and modes with `cp -a`, reloads systemd, starts K3s, and fails if the API does
not return with one Ready node. It does not rotate secrets-encryption keys.
The server token and encryption configuration must remain together; losing or
changing either makes the encrypted datastore unrecoverable. A failed restore
uses an explicit phase state machine. Before destructive mutation, an error
may restart the original K3s installation only when this script stopped an
active service. Once any live state is being preserved or restored, failure is
fail-closed: K3s is intentionally left stopped, no automatic restart or
rollback is attempted, and the preserved `.pre-restore` paths are listed for
operator-directed rollback or repair. After the restored state is installed,
the starting phase also fails closed and stops K3s if readiness or
secrets-encryption validation fails; the EXIT trap never attempts a second
startup. The restore validates SQLite both before and after copying it, and
never rotates secrets-encryption keys. Preserved state is never silently
deleted.

The recovery test procedure is to create a new disposable VM from the
reproducible Debian/K3s infrastructure, give it a distinct VMID and MAC, and
attach it only to a host-only or otherwise isolated network that cannot expose
a second control plane to the production LAN. Either install the exact pinned
K3s release and transfer the private backup, or full-clone the source after the
backup so the exact release and private backup are already present. If the
isolated bridge has no DHCP, assign the disposable guest a temporary
documentation-only RFC 5737 address and link-scoped route; do not connect it to
the production LAN. Restore with `--force-restore`, then run the K3s verifier
plus SQLite and secrets-encryption checks. Remove only the disposable VM and
its temporary network resources after the test; never remove the production VM
or the Debian template.

This baseline was validated with that isolated full-clone procedure. The
restored clone passed the exact-version K3s verifier, API and one-Ready-node
checks, read-only SQLite integrity checks before and after restore, enabled
secrets encryption with matching hashes, CoreDNS, Traefik, ServiceLB,
local-path provisioner, metrics-server, and a non-sensitive Secret survival
check. The temporary Secret was removed from both live clusters, the
disposable recovery VMs were purged, and the production node remained healthy.

Single-node embedded SQLite has no HA quorum or automatic remote backup. Store
backups on encrypted, access-controlled storage separate from the Git checkout
and maintain more than one recovery copy. A lost node plus an unavailable
private backup is a complete control-plane loss. This baseline introduces no
application credentials and does not back up application data that does not yet
exist.

## cert-manager and TLS recovery boundary

The cert-manager custom resources, ACME account keys, Certificate private keys,
and certificate chains are Kubernetes objects in the K3s datastore. They are
therefore included in this recovery boundary. The Cloudflare API-token
Kubernetes Secret is encrypted at rest through K3s secrets encryption, but the
private backup contains the token indirectly and must remain protected.

Never place a Cloudflare token, certificate private key, generated certificate,
kubeconfig, or private backup path in Git or public documentation. If a private
backup is lost or exposed, revoke and rotate the Cloudflare API token as an
operator security procedure, recreate the Secret, and verify certificate
issuance before relying on renewal. Application secrets follow the same
operator-managed model initially.
