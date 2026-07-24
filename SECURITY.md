# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Kube Workspaces, please report it responsibly. **Do not open a public GitHub issue for security vulnerabilities.**

### How to Report

Email: **security@kubeworkspaces.io**

Alternatively, use [GitHub's private vulnerability reporting](https://github.com/kube-workspaces/controller/security/advisories/new) on the relevant repository.

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected component(s): controller, api, proxy, frontend
- Impact assessment (what an attacker could achieve)
- Any suggested fix (optional)

### Response Timeline

- **Acknowledgement:** Within 48 hours
- **Initial assessment:** Within 7 days
- **Fix timeline:** Depends on severity, typically within 30 days for critical issues

### Scope

The following are in scope:

- Authentication bypass (OIDC flow, session validation, cookie handling)
- Authorization bypass (namespace access, role escalation)
- Proxy request smuggling or path traversal
- CRD injection or privilege escalation via workspace specs
- Information disclosure (secrets, tokens, user data)
- Denial of service against the control plane components

### Out of Scope

- Vulnerabilities in workspace container images themselves (these are user-configured)
- Issues requiring physical access to the cluster nodes
- Social engineering attacks
- Vulnerabilities in dependencies that are already publicly disclosed (open a regular issue instead)

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Previous minor | Best effort |
| Older | No |

## Security Architecture

Kube Workspaces handles sensitive operations:

- **Authentication:** OIDC-based with HMAC-SHA256 signed session cookies
- **Authorization:** CRD-based roles (admin/editor/viewer) with namespace-level access control
- **Proxy:** Routes browser traffic to workspace pods with session validation
- **No database:** All state in Kubernetes CRDs and Secrets (encrypted at rest via cluster config)

For architecture details, see the [proxy documentation](docs/proxy.md) and [authentication documentation](docs/authentication.md).
