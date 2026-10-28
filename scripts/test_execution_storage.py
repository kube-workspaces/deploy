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
    def test_duration_defaults_do_not_enable_retention_in_any_mode(self):
        for profile in ("ephemeral", "external", "bundled"):
            with self.subTest(profile=profile):
                _, _, env = api_environment(render(profile))
                self.assertEqual(env["KW_EXECUTION_RETENTION_ENABLED"]["value"], "false")
                self.assertEqual(env["KW_EXECUTION_METADATA_RETENTION_ENABLED"]["value"], "false")

    def test_reviewed_overlay_wires_persistent_workers_without_enabling_guest_policy(self):
        for profile in ("external", "bundled"):
            with self.subTest(profile=profile):
                documents = render(profile, "-f", "examples/execution-storage/retention.yaml")
                _, _, env = api_environment(documents)
                self.assertEqual(env["KW_EXECUTION_RETENTION_ENABLED"]["value"], "true")
                self.assertEqual(env["KW_EXECUTION_METADATA_RETENTION_ENABLED"]["value"], "true")
                self.assertEqual(env["KW_EXECUTION_RETENTION_RECORDINGS"]["value"], "24h")
                self.assertEqual(env["KW_EXECUTION_RETENTION_METADATA"]["value"], "168h")
                self.assertFalse(any(doc["spec"].get("vmExecution", {}).get("enabled", False)
                                     for doc in documents if doc["kind"] == "PlatformConfig"))
                for doc in documents:
                    if doc["kind"] == "Deployment" and not doc["metadata"]["name"].endswith("-api"):
                        for container in doc["spec"]["template"]["spec"]["containers"]:
                            self.assertFalse(any(item["name"].startswith("KW_EXECUTION_") for item in container.get("env", [])))

    def test_recording_only_and_maximum_duration_policy(self):
        _, _, env = api_environment(render("external", "-f", "examples/execution-storage/retention.yaml",
                                           "--set", "execution.storage.retention.metadataEnabled=false",
                                           "--set", "execution.storage.retention.recordings=2562047h",
                                           "--set", "execution.storage.retention.metadata=2562047h"))
        self.assertEqual(env["KW_EXECUTION_RETENTION_ENABLED"]["value"], "true")
        self.assertEqual(env["KW_EXECUTION_METADATA_RETENTION_ENABLED"]["value"], "false")

    def test_retention_rejects_unsafe_policies_before_deployment(self):
        for setting in ("recordings=0h", "recordings=-1h", "recordings=1h30m", "recordings=1.5h",
                        "recordings=999999999999999999999h", "metadata=2562048h",
                        "recordings=", "metadata=1h", "policyAcknowledged=false",
                        "recordingsEnabled=false"):
            with self.subTest(setting=setting):
                with self.assertRaises(subprocess.CalledProcessError):
                    render("external", "-f", "examples/execution-storage/retention.yaml",
                           "--set", f"execution.storage.retention.{setting}")
        for flag in ("recordingsEnabled", "metadataEnabled", "policyAcknowledged"):
            with self.subTest(flag=flag):
                with self.assertRaises(subprocess.CalledProcessError):
                    render("external", "--set-string", f"execution.storage.retention.{flag}=false")
        with self.assertRaises(subprocess.CalledProcessError):
            render("ephemeral", "-f", "examples/execution-storage/retention.yaml")

    def test_duration_only_legacy_configuration_remains_non_destructive(self):
        _, _, env = api_environment(render("external", "--set", "execution.storage.retention.recordings=1h30m"))
        self.assertEqual(env["KW_EXECUTION_RETENTION_RECORDINGS"]["value"], "1h30m")
        self.assertEqual(env["KW_EXECUTION_RETENTION_ENABLED"]["value"], "false")

    def test_kustomize_base_never_enables_retention(self):
        result = subprocess.run(["kustomize", "build", "kustomize/base"], cwd=ROOT,
                                capture_output=True, text=True, check=True)
        _, _, env = api_environment([doc for doc in yaml.safe_load_all(result.stdout) if doc])
        self.assertEqual(env["KW_EXECUTION_RETENTION_ENABLED"]["value"], "false")
        self.assertEqual(env["KW_EXECUTION_METADATA_RETENTION_ENABLED"]["value"], "false")

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
