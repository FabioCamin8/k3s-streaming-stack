# ADR-0003: K3s bundled Traefik

- Status: Accepted
- Date: 2026-08-25

## Context

The stack needs one Kubernetes-native ingress controller for hostname routing and TLS. Installing another controller would duplicate edge ownership and create unnecessary load-balancer and certificate configuration.

## Decision

Keep and use the Traefik v3 bundled by K3s. Configure it through K3s's supported HelmChartConfig mechanism when deployment configuration is added.

## Consequences

There is one clear ingress owner and no Docker provider, Docker labels, Docker network, or Docker socket dependency. Configuration must follow the K3s-packaged Traefik chart's supported values and be checked against the selected K3s release.

## Alternatives considered

- NGINX Ingress: mature, but a second controller would add migration and ownership cost.
- Traefik installed independently: more version control, but duplicates the component already supplied by K3s.
- Cloudflare Tunnel: potentially useful later, but not required for the initial DNS and direct streaming path.
