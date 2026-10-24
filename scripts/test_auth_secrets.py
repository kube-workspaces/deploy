"""Render real overlays/chart to guard signing key custody and namespace RBAC."""

from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(*args):
    output = subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True)
    return [doc for doc in yaml.safe_load_all(output.stdout) if doc]


class AuthSecretTests(unittest.TestCase):
    def test_kustomize_auth_overlays_never_overwrite_credentials(self):
        for overlay in ("auth", "auth-local"):
            with self.subTest(overlay=overlay):
                documents = render("kustomize", "build", f"kustomize/overlays/{overlay}")
                self.assertFalse(any(doc["kind"] == "Secret" for doc in documents))
                config = next(doc for doc in documents if doc["kind"] == "AuthConfig")
                self.assertEqual(config["spec"]["session"]["signingKey"],
                                 {"name": "kube-workspaces-session", "key": "signing-key"})

    def test_external_keys_render_stably_and_custom_namespace_has_account_rbac(self):
        command = ("helm", "template", "auth-test", "helm/kube-workspaces", "-n", "custom-system",
                   "--set", "auth.enabled=true", "--set", "auth.localAuth.enabled=true",
                   "--set", "auth.session.signingKey.create=false",
                   "--set", "auth.oidc.clientSecret.create=false")
        documents = render(*command)
        self.assertEqual(documents, render(*command))
        self.assertFalse(any(doc["kind"] == "Secret" for doc in documents))
        config = next(doc for doc in documents if doc["kind"] == "AuthConfig")
        self.assertEqual(config["spec"]["session"]["signingKey"]["name"], "kube-workspaces-session")
        for component in ("api", "proxy"):
            deployment = next(doc for doc in documents if doc["kind"] == "Deployment"
                              and doc["metadata"]["name"].endswith(f"-{component}"))
            pod = deployment["spec"]["template"]["spec"]
            env = {entry["name"]: entry for entry in pod["containers"][0]["env"]}
            self.assertEqual(env["POD_NAMESPACE"]["valueFrom"]["fieldRef"]["fieldPath"], "metadata.namespace")
            account_bindings = [doc for doc in documents if doc["kind"] == "RoleBinding"
                                and doc["metadata"].get("namespace") == "kube-workspaces-system"
                                and any(subject.get("name") == pod["serviceAccountName"]
                                        and subject.get("namespace") == "custom-system"
                                        for subject in doc["subjects"])]
            self.assertTrue(account_bindings, component)


if __name__ == "__main__":
    unittest.main()
