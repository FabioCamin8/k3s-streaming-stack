# ADR-0001: VM over LXC

- Status: Accepted
- Date: 2026-08-25

## Context

Kubernetes can be made to run in several Proxmox guest types, but a public learning and operations project benefits from a conventional Linux boundary. LXC shares the host kernel and can add nested-container, cgroup, and AppArmor interactions that are not part of the application problem.

## Decision

Run the initial K3s node in a Debian 13 VM with a dedicated guest kernel.

## Consequences

The guest more closely resembles a VPS, cloud VM, or bare-metal node and is easier to reason about across environments. The tradeoff is additional memory, disk, and virtualization overhead, which is accepted for the initial single-node stack.

## Alternatives considered

- LXC: lower overhead, but a less conventional Kubernetes boundary and more nested-container edge cases.
- Bare metal: valid but outside the current Proxmox learning and recovery workflow.
- Nested Kubernetes inside another orchestration system: unnecessary complexity for v0.1.
