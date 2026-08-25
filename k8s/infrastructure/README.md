# Infrastructure configuration

This directory will hold only verified cluster-level configuration, such as cert-manager ACME resources and the K3s-supported Traefik HelmChartConfig integration.

No secret, certificate key, Cloudflare token, or environment-specific address belongs in this directory. The first implementation must use Let's Encrypt staging and be reviewed against the selected K3s and cert-manager releases before production values are introduced.
