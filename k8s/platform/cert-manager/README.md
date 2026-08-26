# cert-manager platform resources

These are repository-owned cert-manager resources. The third-party
cert-manager installation is handled separately by
[`infra/cert-manager/install.sh`](../../../infra/cert-manager/install.sh).

The checked-in manifests contain placeholders only. Copy
`operator.env.example` to an operator-controlled file outside Git and render
to a new temporary directory:

```sh
cp k8s/platform/cert-manager/operator.env.example /secure/operator-secrets/tls-operator.env
chmod 600 /secure/operator-secrets/tls-operator.env
# Edit the protected file with the deployment email and two hostnames.
CERT_MANAGER_CONFIG_FILE=/secure/operator-secrets/tls-operator.env \
  ./k8s/platform/cert-manager/render.sh /tmp/k3s-tls-manifests
```

The renderer validates lowercase hostnames, keeps staging and production
hostnames distinct, and writes no output inside the repository. It renders
separate Kustomize roots so production is not part of the staging apply:

```sh
kubectl apply -k /tmp/k3s-tls-manifests/staging
kubectl -n default wait --for=condition=Ready \
  certificate/platform-staging-certificate --timeout=10m
```

Inspect the staging CertificateRequest, Order, and Challenge if issuance
fails. Confirm the temporary `_acme-challenge` TXT record appears and is later
removed by cert-manager. Do not create the TXT record manually during normal
operation.

Only after staging DNS-01 and the disposable Traefik route pass should the
production root be applied:

```sh
kubectl apply -k /tmp/k3s-tls-manifests/production
kubectl -n default wait --for=condition=Ready \
  certificate/platform-production-certificate --timeout=10m
```

Both certificates are deliberately host-specific. The production test does
not issue a wildcard because the application hostname layout is not yet part
of this milestone. A later application milestone can choose a broader scope
from its real host requirements.

The Cloudflare record must remain DNS-only. The purpose here is direct origin
TLS validation through the bundled Traefik IngressClass, not Cloudflare proxy
validation.

## Disposable Traefik route

The renderer also creates a separate `tls-validation` Kustomize root containing
only a one-replica `traefik/whoami:v1.10.3` Deployment, Service, and Ingress.
Apply it only after the staging Certificate is Ready:

```sh
kubectl apply -k /tmp/k3s-tls-manifests/tls-validation
kubectl -n default wait --for=condition=Available \
  deployment/tls-validation-whoami --timeout=5m
```

Use a `curl` request to the selected staging hostname with an explicit
certificate trust override because Let's Encrypt staging is intentionally
untrusted. Confirm the response is from the whoami Pod and inspect the served
certificate's hostname and staging issuer separately. Delete this root after
the proof:

```sh
kubectl delete -k /tmp/k3s-tls-manifests/tls-validation
```
