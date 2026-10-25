"""Recovery must preserve identity and never overwrite a shared credential."""

import base64
import copy
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("local_admin_password", Path(__file__).with_name("local-admin-password.py"))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class LocalPasswordRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.user = {
            "metadata": {"name": "retained-user", "uid": "original-uid", "resourceVersion": "7"},
            "spec": {"email": "owner@example.com", "role": "admin", "namespaceAccess": [{"namespace": "shared", "role": "editor"}], "localAuth": {"enabled": True, "passwordSecretRef": {"name": "shared-legacy", "key": "customHash"}}},
            "status": {"personalNamespace": "retained-data"},
        }

    def test_get_resolves_reference_instead_of_email_slug(self):
        calls = []

        def kubectl(*args, payload=None):
            calls.append(args)
            if args[:2] == ("get", "users.kubeworkspaces.io"):
                return {"items": [self.user]}
            return {"metadata": {"annotations": {"kubeworkspaces.io/user-uid": "original-uid"}}, "data": {"password": base64.b64encode(b"one-time-password").decode()}}

        with patch.object(helper, "kubectl", kubectl):
            self.assertEqual(helper.run("get", "owner@example.com"), "one-time-password")
        self.assertIn(("get", "secret", "shared-legacy", "-n", helper.NAMESPACE, "-o", "json"), calls)

    def test_ambiguous_email_refuses_all_mutation(self):
        duplicate = copy.deepcopy(self.user)
        duplicate["spec"]["email"] = "OWNER@example.com"
        with patch.object(helper, "kubectl", return_value={"items": [self.user, duplicate]}) as command:
            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                helper.run("reset", "owner@example.com")
        self.assertEqual(command.call_count, 1)

    def test_get_refuses_other_uid(self):
        with patch.object(helper, "kubectl", side_effect=[{"items": [self.user]}, {"metadata": {"annotations": {"kubeworkspaces.io/user-uid": "other-uid"}}}]):
            with self.assertRaisesRegex(RuntimeError, "different User UID"):
                helper.run("get", "owner@example.com")

    def test_reset_never_writes_old_secret_and_fences_user_update(self):
        for conflict in (False, True):
            with self.subTest(conflict=conflict):
                original = copy.deepcopy(self.user)
                calls = []

                def kubectl(*args, payload=None):
                    calls.append((args, copy.deepcopy(payload)))
                    if args[:2] == ("get", "users.kubeworkspaces.io"):
                        return {"items": [self.user]}
                    if args[0] == "patch" and conflict:
                        raise RuntimeError("concurrent User update")
                    return {}

                bcrypt = SimpleNamespace(gensalt=lambda rounds: b"test-salt", hashpw=lambda password, salt: b"test-bcrypt-hash")
                with patch.object(helper, "kubectl", kubectl), patch.dict("sys.modules", {"bcrypt": bcrypt}):
                    if conflict:
                        with self.assertRaisesRegex(RuntimeError, "concurrent"):
                            helper.run("reset", "owner@example.com")
                    else:
                        password = helper.run("reset", "owner@example.com")
                        self.assertGreaterEqual(len(password), 12)
                self.assertEqual(self.user, original)
                self.assertEqual([args[0] for args, _ in calls], ["get", "create", "patch"])
                secret = calls[1][1]
                self.assertEqual(secret["metadata"]["ownerReferences"][0]["uid"], "original-uid")
                self.assertEqual(secret["stringData"]["mustChangePassword"], "true")
                operations = calls[2][1]
                self.assertEqual(operations[:2], [{"op": "test", "path": "/metadata/uid", "value": "original-uid"}, {"op": "test", "path": "/metadata/resourceVersion", "value": "7"}])
                self.assertEqual(operations[2]["path"], "/spec/localAuth")
                self.assertEqual(operations[2]["value"]["passwordSecretRef"]["name"], secret["metadata"]["name"])
                self.assertNotEqual(secret["metadata"]["name"], "shared-legacy")


if __name__ == "__main__":
    unittest.main()
