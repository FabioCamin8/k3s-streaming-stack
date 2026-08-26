# Kubernetes configuration

This tree contains only Kubernetes-native configuration whose contract has been
verified. The cert-manager platform baseline is intentionally small; image
names, ports, health checks, persistence, and environment contracts for
AIOStreams and Remux remain deferred until they are verified from their primary
upstream repositories.

- [`infrastructure/`](infrastructure/README.md): cluster-level configuration that is proven necessary.
- [`platform/cert-manager/`](platform/cert-manager/README.md): pinned TLS issuers, certificates, and a disposable Traefik route.
- [`aiostreams/`](aiostreams/README.md): AIOStreams resources after upstream verification.
- [`remux/`](remux/README.md): Remux resources after upstream verification.

Docker labels, Docker networks, Docker sockets, Compose profiles, and bind mounts do not belong here. They must be represented by Kubernetes Services, Ingress/IngressRoute resources, Secrets, ConfigMaps, and persistent volumes only when the resulting contract is known.
