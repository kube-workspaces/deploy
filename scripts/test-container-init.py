#!/usr/bin/env python3
"""Opt-in, isolated Kind proof using sibling controller/API/catalog sources.

Builds local executables and an installer image, creates a uniquely named Kind
cluster with its own temporary kubeconfig, and always tears it down. No existing
cluster context or deployment is used. Requires Go, Docker, Kind, kubectl and yq.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


SIBLINGS = Path(__file__).resolve().parents[2]


def run(*args, cwd=None, data=None, check=True):
    result = subprocess.run(args, cwd=cwd, input=data, text=True, capture_output=True, timeout=180)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}:\n{result.stdout}\n{result.stderr}")
    return result


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(description, predicate, seconds=180):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                print(f"PASS {description}", flush=True)
                return result
        except (RuntimeError, OSError, ValueError, urllib.error.URLError) as error:
            last = error
        time.sleep(1)
    raise RuntimeError(f"timed out: {description}; last error: {last}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, default=SIBLINGS)
    parser.add_argument("--node-image", default="kindest/node:v1.31.0")
    args = parser.parse_args()
    for tool in ("go", "docker", "kind", "kubectl", "yq", "make"):
        if not shutil.which(tool):
            parser.error(f"missing prerequisite: {tool}")
    sources = args.sources.resolve()
    controller, api, runner, catalog = (sources / name for name in ("controller", "api", "container-init", "image-catalog"))
    demo = json.loads(run("yq", "-o=json", ".", str(catalog / "images/community/alpine-container-init.yaml")).stdout)
    baked_demo = json.loads(run("yq", "-o=json", ".", str(catalog / "images/community/alpine-container-init-baked.yaml")).stdout)
    cluster = "container-init-proof-" + uuid.uuid4().hex[:8]
    installer = "container-init:" + cluster
    processes, logs = [], []
    created = False
    with tempfile.TemporaryDirectory(prefix="container-init-proof-") as directory:
        temp = Path(directory)
        kubeconfig = temp / "kubeconfig"

        def kubectl(*command, data=None, check=True):
            return run("kubectl", "--kubeconfig", str(kubeconfig), *command, data=data, check=check)

        def apply(obj):
            kubectl("apply", "--server-side", "-f", "-", data=json.dumps(obj))

        def get(resource, name):
            return json.loads(kubectl("get", resource, name, "-n", "workspaces", "-o", "json").stdout)

        def pod(name):
            items = json.loads(kubectl("get", "pods", "-n", "workspaces", "-l", "workspace-name=" + name, "-o", "json").stdout)["items"]
            # Wait out rolling overlap instead of reading markers from one pod
            # and then accidentally executing the assertion in its replacement.
            if len(items) != 1:
                return None
            current = items[0]
            return current if not current["metadata"].get("deletionTimestamp") and current["status"].get("phase") == "Running" else None

        def exec_in(name, *command):
            current = pod(name)
            if not current:
                return None
            result = kubectl("exec", "-n", "workspaces", current["metadata"]["name"], "-c", "workspace", "--", *command, check=False)
            return result.stdout if result.returncode == 0 else None

        def ready(name, marker="/run/container-init-demo-ready", old_uid=None):
            stable = {"uid": None, "since": 0}
            def check():
                current = pod(name)
                if not current or current["metadata"]["uid"] == old_uid:
                    stable["uid"] = None
                    return None
                if exec_in(name, "test", "-f", marker) is None:
                    return None
                if (exec_in(name, "cat", "/proc/1/comm") or "").strip() != "sleep":
                    return None
                if stable["uid"] != current["metadata"]["uid"]:
                    stable.update(uid=current["metadata"]["uid"], since=time.monotonic())
                    return None
                if time.monotonic() - stable["since"] < 2:
                    return None
                return current
            return wait_for(name + " initialized", check)

        def start(binary, *flags):
            path = temp / (binary.name + ".log")
            log = path.open("w")
            logs.append((path, log))
            # Isolate service configuration from any operator's shell settings.
            env = {key: os.environ[key] for key in ("PATH", "HOME") if key in os.environ}
            env["KUBECONFIG"] = str(kubeconfig)
            process = subprocess.Popen([str(binary), *flags], env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            return process

        try:
            run("make", "build-all", "VERSION=kind-proof", cwd=runner)
            run("docker", "build", "--provenance=false", "-t", installer, ".", cwd=runner)
            run("go", "build", "-o", str(temp / "manager"), "./cmd/main.go", cwd=controller)
            run("go", "build", "-o", str(temp / "api"), "./cmd/kube_workspaces", cwd=api)
            created = True
            run("kind", "create", "cluster", "--name", cluster, "--image", args.node_image,
                "--kubeconfig", str(kubeconfig), "--wait", "120s")
            run("kind", "load", "docker-image", installer, "--name", cluster)
            for crd in sorted((controller / "config/crd/bases").glob("*.yaml")):
                kubectl("apply", "--server-side", "-f", str(crd))
            kubectl("create", "namespace", "workspaces")
            apply({"apiVersion": "kubeworkspaces.io/v1alpha1", "kind": "AuthConfig", "metadata": {"name": "default"}, "spec": {"enabled": False}})
            apply(demo)
            start(temp / "manager", "--metrics-bind-address=0", "--metrics-secure=false",
                  "--health-probe-bind-address=127.0.0.1:" + str(free_port()), "--container-init-image=" + installer)
            port = free_port()
            api_process = start(temp / "api", "--domain", "127.0.0.1:" + str(port), "--http-port", str(port))

            def request(path, body=None):
                data = json.dumps(body).encode() if body is not None else None
                req = urllib.request.Request(f"http://127.0.0.1:{port}" + path, data=data, headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=15) as response:
                    return json.loads(response.read())

            def api_ready():
                assert api_process.poll() is None, "API exited before accepting requests"
                return isinstance(request("/v1/images"), list)
            wait_for("API available", api_ready)

            def create(name, kind, **extra):
                payload = {
                    "name": name, "namespace": "workspaces", "type": kind,
                    "container": {"name": "workspace", "image": demo["spec"]["image"], "port": 80,
                                  "cpu_request": "50m", "cpu_limit": "500m", "memory_request": "64Mi", "memory_limit": "256Mi"},
                }
                payload.update(extra)
                return request("/v1/workspaces", payload)

            original_data = demo["spec"]["defaultUserData"]
            for kind in ("container", "scratch"):
                name = "injected-" + kind
                create(name, kind)
                current = ready(name)
                ws = get("workspace", name)
                assert ws["spec"]["containerInit"]["userData"] == original_data
                assert ws["spec"]["template"]["spec"]["containers"][0]["command"] == ["sleep"]
                main = current["spec"]["containers"][0]
                assert main["command"] == ["/opt/container-init/container-init"]
                assert all(m["readOnly"] for m in main["volumeMounts"] if m["name"].startswith("kw-container-init-"))
                assert exec_in(name, "cat", "/proc/1/comm").strip() == "sleep"
                assert "Created by injected" in exec_in(name, "cat", "/etc/container-init-demo.txt")
                assert "curl " in exec_in(name, "cat", "/run/container-init-demo-curl.txt")
                secret = get("secret", name + "-container-init")
                assert secret["metadata"]["ownerReferences"][0]["uid"] == ws["metadata"]["uid"]
                print("PASS API defaults, main-root package/file setup, readonly mounts and exec: " + kind, flush=True)

            for kind in ("container", "scratch"):
                name = "drop-" + kind
                create(name, kind, container_init={"mode": "injected", "user_data": original_data,
                                                  "default_user": "nobody", "run_as_user": "nobody"})
                ready(name)
                snapshot = get("workspace", name)["spec"]["containerInit"]
                assert snapshot["defaultUser"] == "nobody" and snapshot["runAsUser"] == "nobody"
                wait_for(name + " non-root PID 1", lambda: "Uid:\t65534\t65534\t65534\t65534" in (exec_in(name, "cat", "/proc/1/status") or ""))
                assert "NoNewPrivs:\t1" in exec_in(name, "cat", "/proc/1/status")
                print("PASS API identity snapshot and root-provision/non-root application: " + kind, flush=True)

            # Changing catalog data does not retrofit the existing snapshot.
            demo["spec"]["defaultUserData"] = "#cloud-config\nruncmd: []\n"
            apply(demo)
            old = pod("injected-container")["metadata"]["uid"]
            kubectl("delete", "pod", "injected-container-0", "-n", "workspaces", "--wait=true")
            ready("injected-container", old_uid=old)
            assert get("workspace", "injected-container")["spec"]["containerInit"]["userData"] == original_data
            print("PASS Pod replacement reapplies the original snapshotted cloud-config", flush=True)

            for kind in ("container", "scratch"):
                source = "injected-" + kind
                clone = "clone-" + kind
                request(f"/v1/workspaces/{source}/clone?namespace=workspaces", {"new_name": clone})
                ready(clone)
                ws = get("workspace", clone)
                assert ws["spec"]["containerInit"]["userData"] == original_data
                assert get("secret", clone + "-container-init")["metadata"]["ownerReferences"][0]["uid"] == ws["metadata"]["uid"]
                assert ws["metadata"]["uid"] != get("workspace", source)["metadata"]["uid"]
                try:
                    request(f"/v1/workspaces/{source}/reset?namespace=workspaces", {})
                except urllib.error.HTTPError as error:
                    assert error.code == 400 and "only vm workspaces" in error.read().decode()
                else:
                    raise AssertionError("non-VM reset must remain explicitly unsupported")
                print("PASS clone snapshots/independent Secrets and explicit non-VM reset rejection: " + kind, flush=True)
            old = pod("injected-scratch")["metadata"]["uid"]
            kubectl("annotate", "workspace", "injected-scratch", "-n", "workspaces", "kubeworkspaces.io/stopped=true", "--overwrite")
            wait_for("scratch stopped", lambda: not json.loads(kubectl("get", "pods", "-n", "workspaces", "-l", "workspace-name=injected-scratch", "-o", "json").stdout)["items"])
            kubectl("annotate", "workspace", "injected-scratch", "-n", "workspaces", "kubeworkspaces.io/stopped-")
            ready("injected-scratch", old_uid=old)

            # Direct CR and independently managed Secret, including a data update.
            private = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "private-init", "namespace": "workspaces"}, "stringData": {"user-data": "#cloud-config\nwrite_files:\n  - path: /run/reference-version\n    content: v1\n"}}
            apply(private)
            direct = {"apiVersion": "kubeworkspaces.io/v1alpha1", "kind": "Workspace", "metadata": {"name": "direct", "namespace": "workspaces"}, "spec": {"type": "scratch", "containerInit": {"mode": "injected", "userDataSecretRef": {"name": "private-init"}}, "template": {"spec": {"containers": [{"name": "workspace", "image": "alpine:3.22", "command": ["sleep"], "args": ["infinity"], "ports": [{"containerPort": 80}]}]}}}}
            apply(direct)
            old = ready("direct", marker="/run/reference-version")["metadata"]["uid"]
            private["stringData"]["user-data"] = private["stringData"]["user-data"].replace("v1", "v2")
            apply(private)
            ready("direct", marker="/run/reference-version", old_uid=old)
            assert exec_in("direct", "cat", "/run/reference-version") == "v2"
            assert not get("secret", "private-init")["metadata"].get("ownerReferences")
            print("PASS direct CR and independently owned Secret update/rollout", flush=True)

            for kind in ("container", "scratch"):
                name = "baked-" + kind
                baked_demo["spec"]["image"] = installer
                apply(baked_demo)
                create(name, kind, container={"name": "workspace", "image": installer, "port": 80},
                       container_init={"mode": "baked-in", "user_data": original_data})
                current = ready(name)
                assert not current["spec"].get("initContainers")
                assert exec_in(name, "cat", "/proc/1/comm").strip() == "sleep"
                assert "Created by injected" in exec_in(name, "cat", "/etc/container-init-demo.txt")
                assert "curl " in exec_in(name, "cat", "/run/container-init-demo-curl.txt")
                print("PASS baked-in catalog startup, equivalent provisioning and unchanged entrypoint: " + kind, flush=True)

            shared = json.loads(json.dumps(direct))
            shared["metadata"]["name"] = "shared-only"
            shared["spec"]["containerInit"] = {"mode": "disabled"}
            shared_spec = shared["spec"]["template"]["spec"]
            shared_spec["volumes"] = [{"name": "shared", "emptyDir": {}}]
            shared_spec["initContainers"] = [{"name": "prepare-shared", "image": "alpine:3.22",
                "command": ["sh", "-ec", "touch /shared/ready /etc/init-container-only"],
                "volumeMounts": [{"name": "shared", "mountPath": "/shared"}]}]
            shared_spec["containers"][0]["volumeMounts"] = [{"name": "shared", "mountPath": "/shared"}]
            apply(shared)
            ready("shared-only", marker="/shared/ready")
            assert exec_in("shared-only", "test", "!", "-e", "/etc/init-container-only") is not None
            print("PASS shared-volume preparation does not provision the main root", flush=True)

            apply({"apiVersion": "v1", "kind": "PersistentVolume", "metadata": {"name": "init-proof"},
                   "spec": {"capacity": {"storage": "1Gi"}, "accessModes": ["ReadWriteOnce"], "storageClassName": "",
                            "hostPath": {"path": "/tmp/container-init-proof-data", "type": "DirectoryOrCreate"}}})
            apply({"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "init-proof", "namespace": "workspaces"},
                   "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "", "volumeName": "init-proof",
                            "resources": {"requests": {"storage": "1Gi"}}}})
            persistent = json.loads(json.dumps(direct))
            persistent["metadata"]["name"] = "persistent-proof"
            persistent["spec"]["containerInit"] = {"mode": "injected", "userData": "#cloud-config\nwrite_files:\n  - path: /etc/root-ready\n    content: recreated\nruncmd:\n  - [sh, -ec, 'test -s /etc/root-ready; echo run >> /persistent/runs; touch /run/persistent-ready']\n"}
            persistent_spec = persistent["spec"]["template"]["spec"]
            persistent_spec["volumes"] = [{"name": "persistent", "persistentVolumeClaim": {"claimName": "init-proof"}}]
            persistent_spec["containers"][0]["volumeMounts"] = [{"name": "persistent", "mountPath": "/persistent"}]
            apply(persistent)
            current = ready("persistent-proof", marker="/run/persistent-ready")
            runs_before = len(exec_in("persistent-proof", "cat", "/persistent/runs").splitlines())
            kubectl("delete", "pod", current["metadata"]["name"], "-n", "workspaces", "--wait=true")
            ready("persistent-proof", marker="/run/persistent-ready", old_uid=current["metadata"]["uid"])
            # Commands may run more than once during ordinary rolling replacement;
            # the contract promises rerun, not exactly-once persistent side effects.
            runs = exec_in("persistent-proof", "cat", "/persistent/runs").splitlines()
            assert len(runs) > runs_before and all(line == "run" for line in runs)
            assert exec_in("persistent-proof", "cat", "/etc/root-ready") == "recreated"
            print("PASS persistent volume reuse never skips replacement root provisioning", flush=True)

            failure = create("failed", "container", container_init={"mode": "injected", "user_data": "#cloud-config\nbootcmd: [[test, '!', -e, /etc/attempt-marker]]\nwrite_files:\n  - path: /etc/attempt-marker\n    content: fresh-root\nruncmd: [[sh, -c, 'exit 7']]\n"})
            assert failure
            def failed():
                current = pod("failed")
                if not current:
                    return False
                statuses = current["status"].get("containerStatuses", [])
                if not statuses or statuses[0].get("restartCount", 0) == 0:
                    return False
                log = kubectl("logs", "-n", "workspaces", current["metadata"]["name"], "-c", "workspace", "--previous", check=False)
                return "runcmd[0]" in log.stdout and "exit status 7" in log.stdout
            wait_for("failed provisioning prevents application exec", failed)
            print("PASS container restart retries provisioning against a fresh root filesystem", flush=True)
            def failed_condition():
                conditions = get("workspace", "failed").get("status", {}).get("conditions", [])
                return any(c.get("type") == "ContainerInitialized" and c.get("reason") == "ContainerInitFailed"
                           and "runcmd[0]" in c.get("message", "") for c in conditions)
            wait_for("payload-free initialization failure condition", failed_condition)
            print("PASS injected Alpine milestone end-to-end", flush=True)
        finally:
            if created and sys.exc_info()[0] is not None:
                print(kubectl("get", "pods", "-n", "workspaces", "-o", "wide", check=False).stdout)
                print(kubectl("get", "events", "-n", "workspaces", "--sort-by=.lastTimestamp", check=False).stdout[-8000:])
                for name in ("injected-container-0", "failed-0"):
                    print(kubectl("logs", "-n", "workspaces", name, "-c", "workspace", check=False).stdout[-4000:])
            for process in reversed(processes):
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for path, log in logs:
                log.close()
                if sys.exc_info()[0] is not None:
                    print(path.name + ":\n" + path.read_text()[-8000:])
            if created:
                run("kind", "delete", "cluster", "--name", cluster, check=False)
            run("docker", "image", "rm", installer, check=False)


if __name__ == "__main__":
    main()
