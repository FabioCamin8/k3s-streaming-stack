# Bootstrap sequence

This is the intended sequence for a fresh deployment. The Proxmox/Debian
template, `k3s01` full-clone lifecycle, pinned K3s platform, and cert-manager
DNS-01/TLS foundation have been executed and validated with the repository
automation. AIOStreams and Remux are completed application milestones;
selective Authelia is the current application/security phase. Automatic update
controllers remain a separate future phase in [`plan.md`](plan.md).

## Prerequisites

- A Proxmox VE host with one image-capable storage and one snippets-capable storage.
- A local copy of the repository on that Proxmox host.
- An operator SSH public-key file supplied out of band only when overriding the
  template's inherited key.
- A DHCP reservation and working guest DNS.
- A private operator workstation with Git and, later, `kubectl`/`helm` if needed by the selected installation path.

## Phase 0: Debian template and VM — validated

1. Inspect storage and bridge choices with `pvesm status --content images`,
   `pvesm status --content snippets`, and `ip link show vmbr0`. Do not assume a
   storage name.
2. Run the template builder from [`infra/proxmox/README.md`](../infra/proxmox/README.md)
   with explicit image and snippet storage IDs. The builder verifies the
   dated Debian image checksum, configures the generic `debian13-cloud`
   template, and refuses collisions.
3. Run the clone builder with the selected image storage. It creates a full
   `k3s01` clone, applies `ip=dhcp`, declares the VM NIC MTU as 9000, and starts
   the VM unless `--no-start` is selected. The template's Cloud-Init user,
   password, and SSH key are inherited by default. Supply
   `--ssh-public-key-file <path>` only to intentionally override the SSH key;
   the spawn script never reads or sets the password. The vendor-data policy
   keeps SSH password authentication disabled, so that password is for local
   console, sudo, and recovery use.
4. From the guest, run `cloud-init status --wait` before considering it ready.
5. Copy and run `scripts/verify/debian-node.sh`. Investigate any failure using
   `cloud-init status --long`, `/var/log/cloud-init.log`, and
   `/var/log/cloud-init-output.log`.
6. Perform the explicit OS patching gate before K3s. Keep
   `package_upgrade: false` in vendor-data, then run `apt-get update`,
   `apt-get full-upgrade`, reboot if `/var/run/reboot-required` exists, and
   rerun the Debian verifier.
7. Continue to the K3s phase only after the post-upgrade Debian verification is
   passing and the template/clone result has been reviewed.

## Validated K3s platform sequence

1. After the Debian baseline and explicit `apt-get update`/`full-upgrade` gate
   pass, use `infra/k3s/versions.env` as the release contract and run the
   pinned installer. Do not use a moving stable channel or disable bundled
   Traefik.
2. Run `scripts/verify/k3s-node.sh`, inspect the actual Flannel/CNI interfaces
   and MTUs, and validate temporary Pod DNS, Service networking, outbound
   connectivity, local-path storage, metrics-server, and Traefik edge behavior.
3. Perform one controlled reboot and repeat the K3s verifier and OS persistence
   checks. Do not claim multi-node overlay validation from this single-node
   topology.
4. Continue to the TLS phase after the validated platform baseline. Do not
   infer application contracts from the platform alone.

## TLS platform milestone — validated

1. Follow [`tls.md`](tls.md) to install the pinned cert-manager release, create the out-of-band Cloudflare Secret, issue a staging certificate, and validate the disposable Traefik TLS route.
2. Only after staging succeeds, issue the host-specific production certificate, verify normal TLS, test lifecycle behavior with staging, and perform the controlled reboot proof.
3. Create the required application DNS record out of band. Keep the AIOStreams
   origin DNS-only; the repository does not contain the real hostname or
   address.
4. Verify the current AIOStreams contract in
   [`k8s/aiostreams/README.md`](../k8s/aiostreams/README.md), then copy its
   `operator.env.example` to a protected location and render outside Git.
5. Choose one direct public mode: WAN TCP/443 -> Traefik TCP/443, or WAN
   TCP/8443 -> Traefik TCP/443. Set `AIOSTREAMS_PUBLIC_HTTPS_PORT` to the same
   public port. Keep the DNS-only record hostname-only; do not require WAN 80
   or change Traefik's internal 443 entrypoint.
6. Apply the rendered AIOStreams bundle, run the workload verifier, and record
   the actual image digest and redacted lifecycle evidence in private operator
   notes and the PR.
7. Verify the Remux contract in [`k8s/remux/README.md`](../k8s/remux/README.md),
   copy `operator.env.example` to a protected path, replace the private
   AIOStreams user path, render outside Git, and apply the Remux bundle. Keep
   the WAN streaming forward disabled during this milestone.
8. Bootstrap one Remux admin user through its startup wizard, obtain a native
   Remux API/session token out of band, and run the addon helper with
   `REMUX_API_TOKEN_FILE`. Validate Remux locally/LAN-side through Traefik,
   then record protocol, integration, stream, redirect, persistence, and
   resource evidence only for checks actually executed.

## Selective Authelia phase — current

1. Verify the current Authelia contract in
   [`k8s/authelia/README.md`](../k8s/authelia/README.md) and obtain its users
   file, password hashes, session/storage/OIDC secrets, signing key, and
   AIOStreams OIDC client material through protected operator files. Never
   place those values in the checkout or command history.
2. Render the Authelia, AIOStreams, and Remux bundles into a protected
   temporary directory. Apply the Authelia bundle first, then the updated
   AIOStreams and Remux bundles, while preserving the existing native recovery
   login and machine endpoints.
3. Validate Authelia health, TLS, login, invalid-login rejection, TOTP,
   recovery, and persistent state. Validate AIOStreams OIDC only for its human
   configuration flow; its Stremio machine URLs remain independently tested.
4. Validate Remux `/admin` through ForwardAuth, then separately rerun Jellyfin
   bootstrap/login/API, playback, WebSocket, and internal AIOStreams checks
   without an Authelia browser session. Remove the `/admin` middleware if the
   deployed Remux route boundary is not stable.
5. Keep WAN forwarding disabled. Record the exact image digests and each
   browser, machine-protocol, Pod-recreation, and certificate result in the
   redacted validation record. Back up Authelia's local-path state separately
   from the K3s datastore before any future upgrade.

## Application stop conditions

Stop before applying a manifest when any of these are unknown:

- The upstream image name or tag is not confirmed by the primary project.
- The container port, health behavior, or persistence path is guessed.
- A required application secret or credential has no private delivery path.
- The certificate issuer would use a production ACME endpoint before staging succeeds.
- The proposed configuration requires Docker socket access, a second runtime,
  or a storage system outside v0.1 scope.
- The AIOStreams `SECRET_KEY`, native auth credentials, Remux API token,
  private AIOStreams manifest path, or public hostname has no protected
  operator-file delivery path.

## First verification pass

The AIOStreams deployment pass proved the smallest useful path: the node and
platform are healthy, Traefik serves the production HTTPS host, native login
protects configuration/admin access, the public Stremio manifest remains
usable without a browser session, the PVC survives Pod recreation and a safe
node reboot, and the actual Traefik source range is validated before trusting
forwarded client IP headers. The Remux pass adds Jellyfin-compatible protocol,
internal AIOStreams, proxy/redirect, and local/LAN TLS gates. Provider-backed
playback and physical Infuse/Swiftfin behavior remain optional and are never
claimed without direct evidence. A failed proof is a reason to correct the
responsible layer, not to add another component.
