#!/usr/bin/env python3
"""Generate a CycloneDX 1.5 SBOM for netstudio-headless.

Only the crates that end up in the shipped binary are listed: the normal
dependency edges from cargo metadata, with the checksums Cargo.lock already
pins. Dev- and build-dependencies are dropped because they never reach the
package, and `cargo metadata` needs no compilation, so this runs before the
release build and cannot disagree with what was actually linked.

Usage:
    python3 tool/headless-sbom.py --output dist/netstudio-headless.cdx.json

Done with the standard library only: the CI container is Debian bullseye,
whose python3.9 has no tomllib, so Cargo.lock is scanned line by line.
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "native_engine", "Cargo.toml")
LOCK = os.path.join(ROOT, "native_engine", "Cargo.lock")


def metadata(manifest):
    result = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--manifest-path", manifest],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit("cargo metadata failed")
    return json.loads(result.stdout)


def lock_checksums(path):
    if not os.path.exists(path):
        return {}
    checksums = {}
    name = version = None
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if line == "[[package]]":
                name = version = None
            elif line.startswith("name = \""):
                name = line.split('"')[1]
            elif line.startswith("version = \""):
                version = line.split('"')[1]
            elif line.startswith("checksum = \"") and name and version:
                checksums[(name, version)] = line.split('"')[1]
    return checksums


def shipped_packages(data):
    """Ids reachable from the root through normal (non-dev, non-build) edges."""
    resolve = data.get("resolve") or {}
    root = resolve.get("root")
    nodes = {node["id"]: node for node in resolve.get("nodes", [])}
    if not root or root not in nodes:
        raise SystemExit("cargo metadata has no resolve root; pass --frozen?")
    included = {root}
    queue = [root]
    while queue:
        node = nodes[queue.pop()]
        for dep in node.get("deps", []):
            kinds = [kind.get("kind") for kind in dep.get("dep_kinds", [])]
            if kinds and all(kind in ("dev", "build") for kind in kinds):
                continue
            if dep["pkg"] not in included:
                included.add(dep["pkg"])
                queue.append(dep["pkg"])
    return root, included


def purl(name, version):
    return "pkg:cargo/{}@{}".format(name, version)


def component(package, checksums, scope):
    name = package["name"]
    version = package["version"]
    entry = {
        "type": "library",
        "bom-ref": purl(name, version),
        "name": name,
        "version": version,
        "scope": scope,
        "purl": purl(name, version),
    }
    license = package.get("license")
    if license:
        entry["licenses"] = [{"expression": license}]
    checksum = checksums.get((name, version))
    if checksum:
        entry["hashes"] = [{"alg": "SHA-256", "content": checksum}]
    source = package.get("source") or ""
    if source.startswith("registry+"):
        entry["externalReferences"] = [
            {"type": "distribution", "url": "https://crates.io/crates/{}/{}".format(name, version)}
        ]
    return entry


def timestamp():
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    moment = datetime.datetime.now(datetime.timezone.utc)
    if epoch and epoch.isdigit():
        moment = datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def build(manifest):
    data = metadata(manifest)
    root, included = shipped_packages(data)
    checksums = lock_checksums(LOCK)
    packages = {package["id"]: package for package in data["packages"]}
    root_package = packages[root]
    components = []
    dependencies = []
    for package_id in sorted(included - {root}):
        package = packages[package_id]
        components.append(component(package, checksums, "required"))
    resolve = data["resolve"]
    nodes = {node["id"]: node for node in resolve["nodes"]}
    for package_id in sorted(included):
        node = nodes[package_id]
        depends = sorted(
            purl(packages[dep["pkg"]]["name"], packages[dep["pkg"]]["version"])
            for dep in node.get("deps", [])
            if dep["pkg"] in included
        )
        dependencies.append({"ref": purl(packages[package_id]["name"], packages[package_id]["version"]), "dependsOn": depends})
    root_component = component(root_package, checksums, "required")
    root_component["type"] = "application"
    root_component["description"] = root_package.get("description") or ""
    serial = uuid.uuid5(
        uuid.NAMESPACE_URL,
        "https://github.com/Cadman021/VeloceNet-Studio/netstudio-headless/{}@{}".format(
            root_package["name"], root_package["version"]
        ),
    )
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:{}".format(serial),
        "version": 1,
        "metadata": {
            "timestamp": timestamp(),
            "tools": {
                "components": [
                    {"type": "application", "name": "headless-sbom.py", "version": "1"}
                ]
            },
            "component": root_component,
        },
        "components": components,
        "dependencies": dependencies,
    }


def check(document):
    """Invariants a consumer relies on; run in CI so a bad SBOM fails loudly."""
    problems = []
    if document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.5":
        problems.append("not a CycloneDX 1.5 document")
    refs = {document["metadata"]["component"]["bom-ref"]}
    for entry in document.get("components", []):
        for field in ("bom-ref", "name", "version", "purl"):
            if not entry.get(field):
                problems.append("component without {}: {}".format(field, entry.get("name")))
        refs.add(entry["bom-ref"])
    for entry in document.get("dependencies", []):
        if entry["ref"] not in refs:
            problems.append("dependency on unknown ref {}".format(entry["ref"]))
        for target in entry["dependsOn"]:
            if target not in refs:
                problems.append("unknown dependency target {}".format(target))
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description="Generate a CycloneDX SBOM for netstudio-headless")
    parser.add_argument("--output", default="-", help="write here (default: stdout)")
    parser.add_argument("--manifest", default=MANIFEST, help="Cargo.toml to describe")
    arguments = parser.parse_args(argv)
    document = build(arguments.manifest)
    problems = check(document)
    if problems:
        for problem in problems:
            sys.stderr.write("sbom: {}\n".format(problem))
        return 1
    text = json.dumps(document, indent=2, sort_keys=False) + "\n"
    if arguments.output == "-":
        sys.stdout.write(text)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(arguments.output)), exist_ok=True)
        with open(arguments.output, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        sys.stderr.write(
            "sbom: {} components, {} bytes\n".format(
                len(document["components"]), len(text)
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))