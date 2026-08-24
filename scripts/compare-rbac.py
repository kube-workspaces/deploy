#!/usr/bin/env python3
"""Compare effective RBAC between the kustomize and Helm render paths.

The two paths write their ClusterRoles differently — kustomize groups rules one
way, the chart another, and they use different ServiceAccount names (kustomize
uses kube-workspaces-controller, the chart uses the release fullname). A textual
diff is therefore useless, but a silent divergence in *permissions* would mean
one install method is subtly more or less privileged than the other.

Flatten both to {apiGroup/resource: sorted(verbs)} and compare that instead.

Role names are normalised before comparison: the chart prefixes them with the
release name, and kustomize uses a fixed prefix, so an unnormalised comparison
just reports every role as missing from the other side.

Usage: scripts/compare-rbac.py <kustomize-render.yaml> <helm-render.yaml>
       [--helm-release NAME]
Exit:  0 if equivalent, 1 if not.
"""

import sys
import yaml

# Both paths converge on these logical roles; only the prefix differs.
KNOWN_SUFFIXES = (
    "manager",
    "proxy-secrets",
    "proxy",
    "workspace-admin-role",
    "workspace-editor-role",
    "workspace-viewer-role",
)


def canonical(name):
    """Strip release/chart prefixes so the same logical role matches.

    kustomize: kube-workspaces-manager
    helm:      <release>-kube-workspaces-manager
    Both reduce to 'manager'.
    """
    for suffix in KNOWN_SUFFIXES:
        if name == suffix or name.endswith(f"-{suffix}"):
            return suffix
    return name


def load_roles(path):
    """Return {canonical_role: {group/resource: set(verbs)}} for Cluster/Roles."""
    roles = {}
    with open(path) as fh:
        for doc in yaml.safe_load_all(fh):
            if not doc or doc.get("kind") not in ("ClusterRole", "Role"):
                continue
            name = doc.get("metadata", {}).get("name")
            if not name:
                continue
            perms = roles.setdefault(canonical(name), {})
            for rule in doc.get("rules") or []:
                for group in rule.get("apiGroups", [""]) or [""]:
                    for res in rule.get("resources", []) or []:
                        key = f"{group or 'core'}/{res}"
                        perms.setdefault(key, set()).update(rule.get("verbs", []))
    return roles


def normalise(roles):
    return {r: {k: sorted(v) for k, v in p.items()} for r, p in roles.items()}


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    a = normalise(load_roles(sys.argv[1]))
    b = normalise(load_roles(sys.argv[2]))

    problems = []

    # Roles present in one render but not the other. The frontend SA has no
    # bindings by design, so only roles are compared here, not bindings.
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    for r in only_a:
        problems.append(f"role {r!r} exists in kustomize but not helm")
    for r in only_b:
        problems.append(f"role {r!r} exists in helm but not kustomize")

    for role in sorted(set(a) & set(b)):
        pa, pb = a[role], b[role]
        for key in sorted(set(pa) | set(pb)):
            va, vb = pa.get(key), pb.get(key)
            if va != vb:
                problems.append(
                    f"{role}: {key}: kustomize={va} helm={vb}"
                )

    if problems:
        print("RBAC differs between render paths:")
        for p in problems:
            print(f"  {p}")
        return 1

    print(f"RBAC equivalent across {len(a)} role(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
