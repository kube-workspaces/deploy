"""Offline storage-mode integration checks against the real dependency charts."""

from pathlib import Path
import subprocess
import unittest
from urllib.parse import urlsplit

import yaml


ROOT = Path(__file__).resolve().parents[1]


def render(profile, *flags):
    result = subprocess.run(
        ["helm", "template", "storage-test", "helm/kube-workspaces", "-n", "test-system",
         "-f", f"examples/execution-storage/{profile}.yaml", *flags],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def api_environment(documents):
    deployment = next(doc for doc in documents if doc["kind"] == "Deployment"
                      and doc["metadata"]["name"].endswith("-api"))
    pod = deployment["spec"]["template"]["spec"]
    env = {entry["name"]: entry for entry in pod["containers"][0]["env"]}
    return deployment, pod, env


class ExecutionStorageTests(unittest.TestCase):
    def test_ephemeral_needs_no_database_object_store_or_pvc(self):
        documents = render("ephemeral")
        deployment, pod, env = api_environment(documents)
        self.assertEqual(env["KW_EXECUTION_STORAGE_MODE"]["value"], "ephemeral")
        self.assertEqual(deployment["spec"]["strategy"]["type"], "Recreate")
        self.assertNotIn("KW_EXECUTION_DATABASE_URL", env)
        self.assertNotIn("KW_EXECUTION_S3_ENDPOINT", env)
        self.assertNotIn("KW_EXECUTION_RECORDING_KEY_FILE", env)
        self.assertFalse(any(doc["kind"] in ("PersistentVolumeClaim", "StatefulSet") for doc in documents))
        temporary = next(vol for vol in pod["volumes"] if vol["name"] == "execution-temporary")
        self.assertEqual(temporary["emptyDir"]["sizeLimit"], "1Gi")
        self.assertEqual(pod["securityContext"]["fsGroup"], 65532)

    def test_external_installs_no_bundled_services(self):
        documents = render("external")
        _, pod, env = api_environment(documents)
        self.assertEqual(env["KW_EXECUTION_STORAGE_MODE"]["value"], "external")
        self.assertFalse(any(doc["kind"] in ("PersistentVolumeClaim", "StatefulSet") for doc in documents))
        self.assertEqual(env["KW_EXECUTION_DATABASE_URL"]["valueFrom"]["secretKeyRef"]["name"], "execution-postgresql")
        self.assertEqual(env["KW_EXECUTION_S3_CREATE_BUCKET"]["value"], "false")
        self.assertFalse(any("emptyDir" in volume for volume in pod["volumes"]))

    def test_bundled_uses_persistent_subcharts_and_app_credentials(self):
        documents = render("bundled")
        _, pod, env = api_environment(documents)
        self.assertEqual(env["KW_EXECUTION_STORAGE_MODE"]["value"], "bundled")
        self.assertEqual(env["KW_EXECUTION_PG_PASSWORD"]["valueFrom"]["secretKeyRef"]["name"], "execution-postgresql-app")
        self.assertNotIn("KW_EXECUTION_DATABASE_URL", env)
        self.assertEqual(env["KW_EXECUTION_S3_ACCESS_KEY"]["valueFrom"]["secretKeyRef"]["key"], "RUSTFS_ACCESS_KEY")
        services = {doc["metadata"]["name"] for doc in documents if doc["kind"] == "Service"}
        s3_hostname = urlsplit(env["KW_EXECUTION_S3_ENDPOINT"]["value"]).hostname
        self.assertIn(s3_hostname.split(".")[0], services)
        postgres = next(doc for doc in documents if doc["kind"] == "StatefulSet")
        self.assertTrue(postgres["spec"]["volumeClaimTemplates"])
        self.assertFalse(postgres["spec"]["template"]["spec"]["automountServiceAccountToken"])
        pvc = next(doc for doc in documents if doc["kind"] == "PersistentVolumeClaim")
        self.assertEqual(pvc["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
        self.assertEqual(pvc["spec"]["resources"]["requests"]["storage"], "20Gi")
        policies = [doc for doc in documents if doc["kind"] == "NetworkPolicy"]
        self.assertEqual(len(policies), 2)
        for policy in policies:
            self.assertNotIn("namespaceSelector", policy["spec"]["ingress"][0]["from"][0])
            self.assertEqual(policy["spec"]["ingress"][0]["from"][0]["podSelector"]["matchLabels"]["app.kubernetes.io/component"], "api")
        self.assertFalse(any(doc["kind"] == "Ingress" for doc in documents))
        self.assertFalse(any("emptyDir" in volume for volume in pod["volumes"]))

    def test_bundled_service_overrides_are_resolved_without_hardcoded_release_names(self):
        documents = render("bundled", "--set", "postgresql.fullnameOverride=custom-execution-db",
                           "--set", "rustfs.fullnameOverride=custom-execution-objects")
        _, _, env = api_environment(documents)
        services = {doc["metadata"]["name"] for doc in documents if doc["kind"] == "Service"}
        self.assertIn("custom-execution-db", services)
        self.assertIn("custom-execution-objects-svc", services)
        self.assertEqual(env["KW_EXECUTION_PG_HOST"]["value"], "custom-execution-db.test-system.svc")
        self.assertEqual(env["KW_EXECUTION_S3_ENDPOINT"]["value"], "http://custom-execution-objects-svc.test-system.svc:9000")


if __name__ == "__main__":
    unittest.main()
