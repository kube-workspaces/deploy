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
    demo = json.loads(run("yq", "-o=json", ".", str(catalog / "images/alpine-container-init.yaml")).stdout)
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
            return next((p for p in items if not p["metadata"].get("deletionTimestamp") and p["status"].get("phase") == "Running"), None)

        def exec_in(name, *command):
            current = pod(name)
            if not current:
                return None
            result = kubectl("exec", "-n", "workspaces", current["metadata"]["name"], "-c", "workspace", "--", *command, check=False)
            return result.stdout if result.returncode == 0 else None

        def ready(name, marker="/run/container-init-demo-ready", old_uid=None):
            def check():
                current = pod(name)
                if not current or current["metadata"]["uid"] == old_uid:
                    return None
                if exec_in(name, "test", "-f", marker) is None:
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

            # Changing catalog data does not retrofit the existing snapshot.
            demo["spec"]["defaultUserData"] = "#cloud-config\nruncmd: []\n"
            apply(demo)
            old = pod("injected-container")["metadata"]["uid"]
            kubectl("delete", "pod", "injected-container-0", "-n", "workspaces", "--wait=true")
            ready("injected-container", old_uid=old)
            assert get("workspace", "injected-container")["spec"]["containerInit"]["userData"] == original_data
            print("PASS Pod replacement reapplies the original snapshotted cloud-config", flush=True)
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

            baked = json.loads(json.dumps(direct))
            baked["metadata"]["name"] = "baked"
            baked["spec"]["containerInit"] = {"mode": "baked-in", "userData": "#cloud-config\nwrite_files:\n  - path: /run/baked-ready\n    content: ready\n"}
            main = baked["spec"]["template"]["spec"]["containers"][0]
            main.update({"image": installer, "command": ["/usr/local/bin/container-init"], "args": ["--user-data", "/run/container-init/user-data", "--", "sleep", "infinity"]})
            apply(baked)
            current = ready("baked", marker="/run/baked-ready")
            assert not current["spec"].get("initContainers")
            assert exec_in("baked", "cat", "/proc/1/comm").strip() == "sleep"
            print("PASS baked-in data-only delivery and unchanged entrypoint", flush=True)

            failure = create("failed", "container", container_init={"mode": "injected", "user_data": "#cloud-config\nruncmd: [[sh, -c, 'exit 7']]\n"})
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
