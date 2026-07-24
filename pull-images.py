#!/usr/bin/env python3
import json, sys, subprocess, yaml

result = subprocess.run(["kubectl", "get", "images.kubeworkspaces.io", "-o", "json"], capture_output=True, text=True)
data = json.loads(result.stdout)

out = []
for item in data.get("items", []):
    m = item["metadata"]
    for k in ["creationTimestamp", "generation", "resourceVersion", "uid", "annotations", "managedFields"]:
        m.pop(k, None)
    out.append(item)

print(yaml.dump_all(out, default_flow_style=False, allow_unicode=True))
