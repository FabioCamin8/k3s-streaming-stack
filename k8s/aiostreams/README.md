# AIOStreams configuration

The intended first workload is one AIOStreams replica with SQLite and persistent `/app/data`, exposed through explicit ingress while retaining direct administrative/configuration access.

Before adding YAML, verify the current [AIOStreams upstream documentation](https://github.com/Viren070/AIOStreams) for the image reference, release/tag policy, listening port, probes, persistence behavior, required configuration, and authentication safeguards. Do not guess these values in a public manifest.
