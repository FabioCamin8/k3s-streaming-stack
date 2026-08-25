# Kubernetes configuration

This tree is reserved for Kubernetes-native configuration. It currently contains no deployment YAML on purpose: image names, ports, health checks, persistence, and environment contracts for AIOStreams and Remux must be verified from their primary upstream repositories before they become declarative configuration.

- [`infrastructure/`](infrastructure/README.md): cluster-level configuration that is proven necessary.
- [`aiostreams/`](aiostreams/README.md): AIOStreams resources after upstream verification.
- [`remux/`](remux/README.md): Remux resources after upstream verification.

Docker labels, Docker networks, Docker sockets, Compose profiles, and bind mounts do not belong here. They must be represented by Kubernetes Services, Ingress/IngressRoute resources, Secrets, ConfigMaps, and persistent volumes only when the resulting contract is known.
