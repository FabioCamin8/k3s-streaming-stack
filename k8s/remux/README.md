# Remux configuration

The intended first workload is one Remux replica with SQLite and persistent `/data`, exposed through explicit ingress for compatible clients.

Before adding YAML, verify the current [Remux upstream documentation](https://github.com/lostb1t/remux) for the image reference, release/tag policy, listening port, probes, persistence behavior, required configuration, and redirect behavior. Treat every update as potentially breaking and preserve a tested rollback path.
