# cert-manager bootstrap

This directory installs cert-manager as third-party infrastructure. It is
separate from the repository-owned ClusterIssuer and Certificate resources in
[`k8s/platform/cert-manager/`](../../k8s/platform/cert-manager/).

## Pinned installation

The installer downloads the official static manifest for cert-manager `v1.21.1`
from the release URL in [`versions.env`](versions.env), verifies the published
SHA-256 digest, applies it with `kubectl`, and waits for the CRDs and the
controller, cainjector, and webhook Deployments. It also checks the deployed
images and performs a server-side dry run through the validating webhook.

The release and installation contract is recorded in
[`docs/research/cert-manager-v1.21.1-cloudflare-dns01.md`](../../docs/research/cert-manager-v1.21.1-cloudflare-dns01.md).
The installer does not copy the upstream manifest into Git and does not create
issuers or application workloads.

Run it only after the Debian and K3s baseline verifiers pass:

```sh
sudo ./infra/cert-manager/install.sh
```

Use `KUBECONFIG` when the operator kubeconfig is not the default. The temporary
download directory is removed on exit.

## Cloudflare Secret

Create a Cloudflare API Token outside Git with only `Zone - DNS - Edit` and
`Zone - Zone - Read`, restricted to the one deployment zone. Do not use the
Global API Key. Keep the token in an owner-readable private file, for example
mode 600, and pass only the file path to the helper:

```sh
sudo ./infra/cert-manager/create-cloudflare-secret.sh \
  --token-file /secure/operator-secrets/cloudflare-api-token
```

The helper strips editor-added trailing newlines, creates or replaces
`cert-manager/cloudflare-api-token-secret`, and verifies only that the
`api-token` key exists. It never prints the token or emits a Secret manifest.
The token path and file remain outside this checkout.

The Kubernetes Secret is encrypted at rest by the existing K3s secrets-
encryption configuration. It is still sensitive cluster state and is therefore
covered by the private K3s backup boundary.
