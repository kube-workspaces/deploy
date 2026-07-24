# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email security concerns to: security@kubeworkspaces.io

You should receive a response within 72 hours. If the issue is confirmed, we will release a patch as soon as possible depending on complexity.

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest main | Yes |
| Previous releases | Best effort |

## Security Best Practices

When deploying Kube Workspaces:

- Always use TLS for ingress
- Rotate the session signing key periodically
- Use network policies to restrict pod-to-pod communication
- Enable RBAC and limit namespace access
- Keep container images updated
- Use `readOnlyRootFilesystem: true` in production deployments
