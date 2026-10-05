#!/usr/bin/env python3
"""Read-only preflight and direct KubeVirt Windows proof manifest generator.

Prints JSON (accepted by kubectl); never applies resources or reads Secrets.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import uuid


def get(resource, name=None, namespace=None):
    command = ["kubectl", "get", resource]
    if name:
        command.append(name)
    command += ["-n", namespace] if namespace else []
    command += ["-o", "json", "--request-timeout=15s"]
    return json.loads(subprocess.check_output(command, text=True))


def state_access_mode(configuration, profile):
    """Match KubeVirt 1.9 backend-storage selection, including empty profiles."""
    properties = profile.get("status", {}).get("claimPropertySets", [])
    modes = {mode for p in properties if p.get("volumeMode") == "Filesystem"
             for mode in p.get("accessModes", [])}
    if "ReadWriteMany" in modes:
        return "ReadWriteMany"
    if "ReadWriteOnce" in modes:
        return "ReadWriteOnce"
    return "ReadWriteMany" if configuration.get("vmStateStorageClass") else "ReadWriteOnce"


def preflight(args):
    kv = get("kubevirt", args.kubevirt_name, args.kubevirt_namespace)
    cdi = get("cdi", args.cdi_name)
    node = get("node", args.node)
    classes = get("storageclass")["items"]
    configuration = kv.get("spec", {}).get("configuration", {})
    state_class = configuration.get("vmStateStorageClass")
    if not state_class:
        for annotation in ("storageclass.kubevirt.io/is-default-virt-class",
                           "storageclass.kubernetes.io/is-default-class"):
            candidates = [s["metadata"]["name"] for s in classes
                          if s["metadata"].get("annotations", {}).get(annotation) == "true"]
            if len(candidates) == 1:
                state_class = candidates[0]
                break
    errors = []
    profiles = get("storageprofiles")["items"]
    profile = next((p for p in profiles if p["metadata"]["name"] == state_class), {})
    mode = state_access_mode(configuration, profile)
    labels = node["metadata"].get("labels", {})
    allocatable = node["status"].get("allocatable", {})
    if labels.get("kubernetes.io/arch") != "amd64":
        errors.append("Selected node must be amd64")
    if labels.get("kubevirt.io/schedulable") != "true" or node["spec"].get("unschedulable"):
        errors.append("Selected node is not schedulable for KubeVirt")
    if not any(c["type"] == "Ready" and c["status"] == "True"
               for c in node["status"].get("conditions", [])):
        errors.append("Selected node is not Ready")
    if allocatable.get("devices.kubevirt.io/kvm", "0") == "0":
        errors.append("Selected node does not advertise KVM")
    if configuration.get("developerConfiguration", {}).get("useEmulation", False):
        errors.append("Windows acceptance requires KVM, not useEmulation")
    if kv.get("status", {}).get("phase") != "Deployed":
        errors.append("KubeVirt is not Deployed")
    if cdi.get("status", {}).get("phase") != "Deployed":
        errors.append("CDI is not Deployed")
    state_sc = next((s for s in classes if s["metadata"]["name"] == state_class), None)
    root_sc = next((s for s in classes if s["metadata"]["name"] == args.storage_class), None)
    if not state_sc:
        errors.append("No unambiguous backend-state StorageClass found")
    if not root_sc:
        errors.append("Root StorageClass does not exist")
    if state_sc and state_sc["provisioner"].endswith("/local-path") and mode != "ReadWriteOnce":
        errors.append("local-path cannot satisfy backend-state RWX: leave vmStateStorageClass unset "
                      "or configure its StorageProfile with Filesystem/ReadWriteOnce")
    version = kv.get("status", {}).get("observedKubeVirtVersion", "")
    if not version.startswith("v1.9."):
        errors.append("Proof tooling targets KubeVirt 1.9.x; review versioned schema and gates")
    report = {
        "kubevirtVersion": version,
        "cdiVersion": cdi.get("status", {}).get("observedVersion"),
        "node": args.node,
        "hostModelLabels": [k for k in labels if k.startswith("host-model-cpu.node.kubevirt.io/")],
        "allocatable": allocatable,
        "taints": node["spec"].get("taints", []),
        "rootStorageClass": args.storage_class,
        "stateStorageClass": state_class,
        "stateAccessMode": mode,
        "errors": errors,
        "manualChecks": [
            "Inventory actual CPU model (host-model labels are not CPU eligibility evidence)",
            "Verify entitled Windows edition/build and signed pinned VirtIO driver media",
            "Check available node memory/CPU, physical disk space and namespace quota",
            "Check uploaded media PVC node affinity against the selected node",
            "Prove guest TPM/Secure Boot and state persistence across different VMI UIDs",
        ],
    }
    print(json.dumps(report, indent=2))
    return bool(errors)


def dns_name(value):
    if len(value) > 63 or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value):
        raise argparse.ArgumentTypeError("must be a DNS label of at most 63 characters")
    return value


def render(args):
    if len(args.name) > 45:
        raise ValueError("proof VM name must be at most 45 characters (generated disk names)")
    if args.mode == "install" and not (args.installer_pvc and args.drivers_pvc):
        raise ValueError("install requires --installer-pvc and --drivers-pvc")
    if args.mode == "clone" and not (args.image and args.sysprep_secret):
        raise ValueError("clone requires --image and --sysprep-secret")
    if args.image and not re.fullmatch(r"[^\s]+@sha256:[a-f0-9]{64}", args.image):
        raise ValueError("--image must be an OCI reference pinned by sha256 digest")
    if args.mode != "clone" and (args.image or args.import_secret):
        raise ValueError("image and import Secret options are only valid in clone mode")
    if args.mode == "firmware" and args.sysprep_secret:
        raise ValueError("Sysprep media is only valid in install/clone mode")
    if args.mode != "install" and (args.installer_pvc or args.drivers_pvc):
        raise ValueError("installer and driver media are only valid in install mode")
    # New VM identities are independent; persist the rendered manifest for reuse.
    identity = args.firmware_uuid or str(uuid.uuid4())
    uuid.UUID(identity)
    disks = [{"name": "rootdisk", "disk": {"bus": "virtio"},
              "bootOrder": 2 if args.mode == "install" else 1}]
    volumes = [{"name": "rootdisk", "dataVolume": {"name": args.name + "-rootdisk"}}]
    if args.mode == "install":
        for name, pvc, order in (("installer", args.installer_pvc, 1),
                                 ("drivers", args.drivers_pvc, 3)):
            disks.append({"name": name, "cdrom": {"bus": "sata", "readonly": True},
                          "bootOrder": order})
            volumes.append({"name": name, "persistentVolumeClaim": {"claimName": pvc}})
    if args.sysprep_secret:
        disks.append({"name": "sysprep", "cdrom": {"bus": "sata", "readonly": True}})
        volumes.append({"name": "sysprep", "sysprep": {"secret": {"name": args.sysprep_secret}}})
    source = {"blank": {}}
    if args.mode == "clone":
        registry = {"url": "docker://" + args.image, "pullMethod": "pod"}
        if args.import_secret:
            registry["secretRef"] = args.import_secret
        source = {"registry": registry}
    vm = {
        "apiVersion": "kubevirt.io/v1", "kind": "VirtualMachine",
        "metadata": {"name": args.name, "namespace": args.namespace,
                     "labels": {"app.kubernetes.io/part-of": "windows11-proof"}},
        "spec": {
            "runStrategy": "Halted",
            "dataVolumeTemplates": [{
                "metadata": {"name": args.name + "-rootdisk",
                             "annotations": {"volume.kubernetes.io/selected-node": args.node}},
                "spec": {"source": source, "storage": {
                    "storageClassName": args.storage_class,
                    "accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem",
                    "resources": {"requests": {"storage": "1Gi" if args.mode == "firmware" else "80Gi"}}}},
            }],
            "template": {"metadata": {"labels": {"app.kubernetes.io/part-of": "windows11-proof"}},
                         "spec": {
                "architecture": "amd64",
                "nodeSelector": {"kubernetes.io/hostname": args.node, "kubernetes.io/arch": "amd64"},
                "terminationGracePeriodSeconds": 180,
                "domain": {
                    "machine": {"type": "q35"},
                    "cpu": {"cores": 1 if args.mode == "firmware" else args.cpus, "model": "host-passthrough"},
                    "memory": {"guest": "1Gi" if args.mode == "firmware" else f"{args.memory_gi}Gi"},
                    "resources": {"requests": {"memory": "1Gi" if args.mode == "firmware" else f"{args.memory_gi}Gi"}},
                    "firmware": {"uuid": identity, "bootloader": {
                        "efi": {"secureBoot": True, "persistent": True}}},
                    "features": {"acpi": {"enabled": True}, "smm": {"enabled": True},
                                 "hyperv": {"relaxed": {"enabled": True},
                                            "vapic": {"enabled": True},
                                            "spinlocks": {"enabled": True, "spinlocks": 8191}}},
                    "clock": {"utc": {}, "timer": {"hpet": {"present": False},
                              "pit": {"tickPolicy": "delay"}, "rtc": {"tickPolicy": "catchup"},
                              "hyperv": {"present": True}}},
                    "devices": {"tpm": {"persistent": True},
                                "autoattachGraphicsDevice": True,
                                "autoattachSerialConsole": False,
                                "video": {"type": "vga"},
                                "inputs": [{"name": "tablet", "type": "tablet", "bus": "usb"}],
                                "disks": disks,
                                "interfaces": [{"name": "default", "model": "virtio", "masquerade": {},
                                                "macAddress": "02:" + ":".join(
                                                    f"{b:02x}" for b in hashlib.sha256(identity.encode()).digest()[:5])}]},
                },
                "networks": [{"name": "default", "pod": {}}],
                "volumes": volumes,
            }},
        },
    }
    print(json.dumps(vm, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("preflight", help="read-only cluster inventory; exit 1 on known blockers")
    check.add_argument("--kubevirt-name", default="kubevirt")
    check.add_argument("--kubevirt-namespace", default="kubevirt")
    check.add_argument("--cdi-name", default="cdi")
    manifest = commands.add_parser("render", help="print a stopped VM; create namespace separately")
    manifest.add_argument("--mode", choices=["firmware", "install", "clone"], required=True)
    manifest.add_argument("--name", type=dns_name, default="windows11-proof")
    manifest.add_argument("--namespace", type=dns_name, default="windows11-proof")
    manifest.add_argument("--firmware-uuid", help="reuse the saved UUID when rendering an existing VM")
    manifest.add_argument("--installer-pvc", type=dns_name)
    manifest.add_argument("--drivers-pvc", type=dns_name)
    manifest.add_argument("--image")
    manifest.add_argument("--sysprep-secret", type=dns_name)
    manifest.add_argument("--import-secret", type=dns_name)
    manifest.add_argument("--cpus", type=int, choices=(2, 4), default=4,
                          help="install/clone vCPU count (firmware mode always uses 1)")
    manifest.add_argument("--memory-gi", type=int, choices=(4, 6, 8), default=8,
                          help="install/clone guest RAM; reserve additional launcher/host headroom")
    for command in (check, manifest):
        command.add_argument("--node", required=True, type=dns_name)
        command.add_argument("--storage-class", default="local-path", type=dns_name)
    args = parser.parse_args()
    try:
        if args.command == "preflight":
            return preflight(args)
        render(args)
        return 0
    except (ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
