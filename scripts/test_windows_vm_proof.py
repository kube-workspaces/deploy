"""Regression checks for Windows proof hardware and storage selection."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("proof", Path(__file__).with_name("windows-vm-proof.py"))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class WindowsProofTests(unittest.TestCase):
    def render(self, **overrides):
        values = dict(mode="firmware", name="windows11-proof", namespace="windows11-proof",
                      node="worker", storage_class="local-path", firmware_uuid=None,
                      installer_pvc=None, drivers_pvc=None, image=None, sysprep_secret=None,
                      import_secret=None, cpus=4, memory_gi=8)
        values.update(overrides)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            proof.render(argparse.Namespace(**values))
        return json.loads(output.getvalue())

    def test_explicit_class_empty_profile_requests_rwx(self):
        self.assertEqual(proof.state_access_mode({"vmStateStorageClass": "local-path"}, {}),
                         "ReadWriteMany")
        self.assertEqual(proof.state_access_mode({}, {}), "ReadWriteOnce")

    def test_filesystem_rwo_overrides_explicit_class(self):
        profile = {"status": {"claimPropertySets": [
            {"volumeMode": "Block", "accessModes": ["ReadWriteMany"]},
            {"volumeMode": "Filesystem", "accessModes": ["ReadWriteOnce"]}]}}
        self.assertEqual(proof.state_access_mode({"vmStateStorageClass": "local-path"}, profile),
                         "ReadWriteOnce")

    def test_independent_identities_and_persistent_hardware(self):
        first = self.render()
        second = self.render()
        domain = first["spec"]["template"]["spec"]["domain"]
        self.assertNotEqual(domain["firmware"]["uuid"],
                            second["spec"]["template"]["spec"]["domain"]["firmware"]["uuid"])
        self.assertTrue(domain["devices"]["tpm"]["persistent"])
        self.assertTrue(domain["firmware"]["bootloader"]["efi"]["secureBoot"])
        self.assertTrue(domain["firmware"]["bootloader"]["efi"]["persistent"])
        self.assertTrue(domain["features"]["smm"]["enabled"])
        self.assertEqual(first["spec"]["runStrategy"], "Halted")
        self.assertNotIn("cloudInitNoCloud", str(first))
        self.assertNotIn("accessCredentials", str(first))

    def test_install_boots_media_before_root(self):
        vm = self.render(mode="install", installer_pvc="windows-iso", drivers_pvc="virtio-iso")
        disks = vm["spec"]["template"]["spec"]["domain"]["devices"]["disks"]
        self.assertEqual({d["name"]: d["bootOrder"] for d in disks},
                         {"rootdisk": 2, "installer": 1, "drivers": 3})
        self.assertEqual(disks[1]["cdrom"]["bus"], "sata")
        self.assertEqual(vm["spec"]["dataVolumeTemplates"][0]["metadata"]["annotations"],
                         {"volume.kubernetes.io/selected-node": "worker"})

    def test_installer_answer_media_and_identity_survive_rerender(self):
        first = self.render(mode="install", installer_pvc="windows-iso", drivers_pvc="virtio-iso",
                            sysprep_secret="build-bootstrap")
        identity = first["spec"]["template"]["spec"]["domain"]["firmware"]["uuid"]
        second = self.render(mode="install", installer_pvc="windows-iso", drivers_pvc="virtio-iso",
                             sysprep_secret="build-bootstrap", firmware_uuid=identity)
        self.assertEqual(first, second)
        interface = first["spec"]["template"]["spec"]["domain"]["devices"]["interfaces"][0]
        self.assertTrue(interface["macAddress"].startswith("02:"))
        self.assertEqual(first["spec"]["template"]["spec"]["volumes"][-1]["sysprep"],
                         {"secret": {"name": "build-bootstrap"}})

    def test_clone_private_import_and_sysprep_reference(self):
        image = "registry.example/private/windows@sha256:" + "a" * 64
        vm = self.render(mode="clone", image=image, import_secret="registry-import",
                         sysprep_secret="clone-bootstrap")
        source = vm["spec"]["dataVolumeTemplates"][0]["spec"]["source"]["registry"]
        self.assertEqual(source["secretRef"], "registry-import")
        self.assertEqual(source["url"], "docker://" + image)
        self.assertEqual(vm["spec"]["template"]["spec"]["volumes"][1]["sysprep"],
                         {"secret": {"name": "clone-bootstrap"}})

    def test_incomplete_or_mutable_sources_rejected(self):
        for values in ({"mode": "install"}, {"mode": "clone"},
                       {"mode": "clone", "image": "registry/windows:latest", "sysprep_secret": "setup"},
                       {"mode": "firmware", "sysprep_secret": "setup"}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.render(**values)


if __name__ == "__main__":
    unittest.main()
