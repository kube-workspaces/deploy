#!/usr/bin/env python3
"""Read/reset one existing local account, retaining its UID and namespace."""

import argparse
import base64
import hashlib
import json
import secrets
import subprocess
import sys

NAMESPACE = "kube-workspaces-system"


def kubectl(*args, payload=None):
    result = subprocess.run(
        ["kubectl", *args],
        input=None if payload is None else json.dumps(payload),
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        # Do not expose payloads/passwords in failed kubectl diagnostics.
        raise RuntimeError("kubectl operation failed; check access and account resourceVersion before retrying")
    return json.loads(result.stdout) if result.stdout.strip() else None


def account(email):
    users = kubectl("get", "users.kubeworkspaces.io", "-o", "json")["items"]
    matches = [u for u in users if u.get("spec", {}).get("email", "").casefold() == email.casefold()]
    if len(matches) != 1:
        raise RuntimeError("exactly one matching User is required; resolve duplicate/case-variant emails first")
    user = matches[0]
    if user["metadata"].get("deletionTimestamp") or not user["metadata"].get("uid"):
        raise RuntimeError("a persisted, non-deleting User is required")
    if not user.get("spec", {}).get("localAuth", {}).get("enabled"):
        raise RuntimeError("local authentication must already be enabled for this account")
    return user


def run(action, email):
    user = account(email)
    metadata = user["metadata"]
    local = user["spec"]["localAuth"]
    if action == "get":
        name = local.get("passwordSecretRef", {}).get("name")
        if not name:
            raise RuntimeError("account has no password Secret reference")
        secret = kubectl("get", "secret", name, "-n", NAMESPACE, "-o", "json")
        owner = secret["metadata"].get("annotations", {}).get("kubeworkspaces.io/user-uid")
        if owner and owner != metadata["uid"]:
            raise RuntimeError("password Secret belongs to a different User UID")
        value = secret.get("data", {}).get("password")
        if not value:
            raise RuntimeError("no plaintext password remains; use reset-admin-password")
        return base64.b64decode(value, validate=True).decode()

    import bcrypt  # Only the reset operation needs the optional dependency.

    password = secrets.token_urlsafe(24)
    hash_value = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()
    suffix = hashlib.sha256((metadata["uid"] + ":" + secrets.token_hex(32)).encode()).hexdigest()[:48]
    name = "kw-password-" + suffix
    secret = {
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {
            "name": name, "namespace": NAMESPACE,
            "annotations": {"kubeworkspaces.io/user-uid": metadata["uid"], "kubeworkspaces.io/user-name": metadata["name"]},
            "ownerReferences": [{"apiVersion": "kubeworkspaces.io/v1alpha1", "kind": "User", "name": metadata["name"], "uid": metadata["uid"]}],
        },
        "stringData": {"passwordHash": hash_value, "password": password, "mustChangePassword": "true"},
    }
    kubectl("create", "-f", "-", "-o", "json", payload=secret)
    replacement = {**local, "passwordSecretRef": {"name": name, "key": "passwordHash"}, "mustChangePassword": True}
    patch = [
        {"op": "test", "path": "/metadata/uid", "value": metadata["uid"]},
        {"op": "test", "path": "/metadata/resourceVersion", "value": metadata["resourceVersion"]},
        {"op": "replace", "path": "/spec/localAuth", "value": replacement},
    ]
    # The plaintext exists only in the new Secret and this process. Passing the
    # patch on stdin keeps credentials out of argv; no old/shared Secret is changed.
    kubectl("patch", "users.kubeworkspaces.io", metadata["name"], "--type=json", "--patch-file=/dev/stdin", "-o", "json", payload=patch)
    return password


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["get", "reset"])
    parser.add_argument("--email", default="admin@local")
    args = parser.parse_args()
    try:
        print(run(args.action, args.email))
    except (RuntimeError, ValueError, KeyError, ImportError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
