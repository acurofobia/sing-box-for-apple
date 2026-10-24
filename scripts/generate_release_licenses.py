#!/usr/bin/env python3
"""Collect exact notices for the pinned iOS source graph, without network access.

Run from any directory. Requires the resolved Swift checkouts and cached Go
modules. This is source-graph evidence, not a legal clearance or an IPA SBOM.
The default inventory records the iOS build tags used by the prototype script.
"""

import argparse
import copy
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
INVENTORY = "docs/testing/testflight-go-dependencies-2026-10-22.json"
RESOLVED = "sing-box.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
# Audited Library target products, not every package present in Package.resolved.
# Source roots follow each pinned package's Package.swift. Collection may include
# platform-conditional headers from these roots; it does not assert file linkage.
SWIFT_PRODUCTS = {
    "binarycodable": ("BinaryCodable", ["Sources/BinaryCodable"]),
    "legacybinarycodable": ("LegacyBinaryCodable", ["Sources/LegacyBinaryCodable"]),
    "grdb.swift": ("GRDB.swift", ["GRDB", "Sources/GRDBSQLite"]),
    "devicekit": ("DeviceKit", ["Source"]),
    "plcrashreporter": ("plcrashreporter", ["Source", "Dependencies/protobuf-c"]),
}
SOURCE_SUFFIXES = {".go", ".c", ".h", ".cc", ".cpp", ".m", ".mm", ".swift", ".s", ".S", ".hpp"}
LEGAL_WORDS = re.compile(r"copyright|SPDX-License|licen[cs]e|permission|redistribut|public domain", re.I)
NOTICE_NAME = re.compile(r"^(?:licen[cs]e(?:[._-].*)?|copying(?:[._-].*)?|copyright(?:[._-].*)?|notice(?:[._-].*)?|thirdpartynotices(?:[._-].*)?|patents|authors)$", re.I)
UNRESOLVED = [
    "Distribution clearance remains unresolved: the included GPL chain and the actual TestFlight terms require a compatible licensing path. These notices grant no additional permissions.",
    "Corresponding Source must match the distributed binary and be supplied through a GPL-compliant mechanism. No public release-source URL or source offer is asserted by this generated file.",
    "This generator inventories source inputs rather than the framework or final IPA. Rebuild from the matching release tree, record toolchain/tags and artifact hashes, and reconcile the final shipped binaries before distribution.",
    "github.com/bogdanfinn/fhttp v0.6.8 has no root LICENSE in its module distribution. Selected source headers are preserved; the complete fork grant and provenance still require confirmation.",
    "Bundled and remotely updated rule datasets require separate provenance and permission review: roscomvpn-routing, roscomvpn-geoip, itdoginfo/allow-domains, and the exact roscomvpn-geosite snapshot and its upstream inputs. GeoLite2/IPinfo/DB-IP terms may apply. No rights to these datasets are granted here.",
    "The upstream sing-box naming/association restriction is reproduced below. Branding, upstream app icons, ModeSelected, ModeUnselected and SubscriptionTexture require separate rights/provenance resolution.",
    "Module LICENSE templates alone do not establish a project's GPL version grant. Review project-level grants, modifications and any required Apache change notices with the matching release sources.",
    "github.com/tailscale/web-client-prebuilt embeds a JavaScript/CSS web client and an Inter WOFF2 font. Embedded legal comments and additional full upstream notices are included; Inter's exact 3.019;git-0a5106e0b OFL grant is supplied. The prebuilt module does not record its exact upstream source commit. Reconcile the prebuilt JavaScript's complete dependency/version inventory with the supplied cached Tailscale yarn.lock closure; see supplemental component review_required fields for missing original notices.",
]


def exact_text(path):
    """Decode without universal-newline conversion, preserving the legal text."""
    return path.read_bytes().decode("utf-8")


def source_headers(text):
    """Return legal leading comment blocks, never executable source or config."""
    position = 0
    while position < len(text):
        whitespace = re.match(r"\s*", text[position:])
        position += whitespace.end()
        if text.startswith("//", position):
            match = re.match(r"(?://[^\n]*(?:\n|$))+", text[position:])
        elif text.startswith("/*", position):
            match = re.match(r"/\*[\s\S]*?\*/(?:\r?\n)?", text[position:])
        else:
            break
        if not match:
            break
        block = match.group()
        if LEGAL_WORDS.search(block):
            yield block
        position += match.end()


def collect_component(name, version, source, directory, sources):
    """Collect root notices and ancestor notices for selected source files.

    Unselected nested notices are recorded separately, not silently labelled as
    iOS-linked dependencies (for example, WinDivert and test-only reference code).
    """
    directory = Path(directory)
    sources = sorted(set(sources))
    entries = {}
    excluded = []
    has_root_license = False

    def add(path, kind, text):
        key = (kind, text)
        if key not in entries:
            entries[key] = {"kind": kind, "paths": [], "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(), "text": text}
        entries[key]["paths"].append(path)

    for current, dirs, files in os.walk(directory):
        dirs[:] = sorted(d for d in dirs if d not in {".git", ".build"})
        for filename in sorted(files):
            if not NOTICE_NAME.fullmatch(filename) or Path(filename).suffix in SOURCE_SUFFIXES:
                continue
            path = Path(current) / filename
            relative = path.relative_to(directory)
            parent = relative.parent
            selected = parent == Path(".") or any(Path(s).is_relative_to(parent) for s in sources)
            if not selected:
                excluded.append(relative.as_posix())
                continue
            add(relative.as_posix(), "notice-file", exact_text(path))
            if parent == Path(".") and re.match(r"^(license|licence|copying)([._-]|$)", filename, re.I):
                has_root_license = True

    for relative in sources:
        path = directory / relative
        if not path.is_file():
            raise FileNotFoundError(path)
        if path.name.endswith((".js.gz", ".css.gz")) or path.suffix in {".js", ".css"}:
            data = gzip.decompress(path.read_bytes()) if path.suffix == ".gz" else path.read_bytes()
            for match in re.finditer(r"/\*[\s\S]*?\*/", data.decode("utf-8")):
                if LEGAL_WORDS.search(match.group()):
                    add(relative, "embedded-asset-comment", match.group())
            continue
        if path.suffix not in SOURCE_SUFFIXES:
            continue
        for header in source_headers(exact_text(path)):
            add(relative, "source-header", header)

    # Project-level README grants can clarify a GPL template or supplemental
    # licensing (notably VKTurnProxy); preserve the complete License section.
    for readme in sorted(directory.glob("README*")):
        if not readme.is_file() or readme.suffix.lower() not in {".md", ".txt", ".rst", ""}:
            continue
        text = exact_text(readme)
        match = re.search(r"(?im)^(#{1,6})\s+(?:license|licensing)\s*\r?$", text)
        if match:
            next_heading = re.search(r"(?m)^#{1," + str(len(match[1])) + r"}\s+", text[match.end():])
            end = match.end() + next_heading.start() if next_heading else len(text)
            add(readme.name + "#license", "project-grant", text[match.start():end])

    notices = sorted(entries.values(), key=lambda n: (n["kind"], sorted(n["paths"])[0], n["sha256"]))
    for notice in notices:
        notice["paths"] = sorted(set(notice["paths"]))
    return {"name": name, "version": version, "source": source, "has_root_license": has_root_license,
            "selected_source_files": sources, "notices": notices, "excluded_notice_candidates": sorted(excluded)}


def validate_inventory(inventory, packages):
    expected = {m["module"]: m["version"] or "" for m in inventory["modules"]}
    actual = {p["Module"]["Path"]: p["Module"].get("Version", "") for p in packages if "Module" in p}
    if len(expected) != inventory["module_count"] or actual != expected:
        missing = sorted(set(expected) - set(actual))
        added = sorted(set(actual) - set(expected))
        changed = sorted(k for k in actual.keys() & expected.keys() if actual[k] != expected[k])
        raise ValueError(f"Go inventory drift: missing={missing}, added={added}, changed={changed}; regenerate/review the inventory first")


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def go_packages(root, inventory, go):
    command = list(inventory["command"])
    command[0] = go
    format_index = command.index("-f")
    command[format_index:format_index + 2] = ["-json"]
    output = run(command, cwd=root / "upstream/sing-box", env=os.environ | inventory["environment"])
    decoder = json.JSONDecoder()
    packages = []
    while output.strip():
        package, end = decoder.raw_decode(output.lstrip())
        packages.append(package)
        output = output.lstrip()[end:]
    validate_inventory(inventory, packages)
    return packages


def selected_files(packages, directory):
    fields = ("GoFiles", "CgoFiles", "CFiles", "CXXFiles", "MFiles", "HFiles", "FFiles", "SFiles", "SwigFiles", "SwigCXXFiles", "EmbedFiles")
    return sorted({(Path(p["Dir"]) / name).relative_to(directory).as_posix()
                   for p in packages for field in fields for name in p.get(field, [])})


def supplemental_components(root):
    directory = root / "scripts/license_sources"
    manifest = json.loads(exact_text(directory / "manifest.json"))
    entries = list(manifest["packages"])
    if "font" in manifest:
        entries.append(manifest["font"])
    components = []
    for entry in entries:
        component = {"name": entry["name"], "version": entry["version"], "source": entry["source"],
                     "ecosystem": "additional-web-source-notices", "selection": manifest["scope"],
                     "provenance": {k: v for k, v in entry.items() if k != "notices"},
                     "notices": [], "selected_source_files": [], "excluded_notice_candidates": [],
                     "has_root_license": bool(entry["notices"])}
        if not entry["notices"]:
            component["review_required"] = "The pinned npm tarball omits its full license/copyright notice. Its declared license alone does not preserve the missing attribution; confirm upstream grant and notices."
        for notice in entry["notices"]:
            path = directory / notice["path"]
            text = exact_text(path)
            if hashlib.sha256(path.read_bytes()).hexdigest() != notice["sha256"]:
                raise ValueError(f"Supplemental notice hash mismatch: {notice['path']}")
            component["notices"].append({"kind": "notice-file", "paths": [notice["upstream_path"]],
                                         "sha256": notice["sha256"], "text": text,
                                         "source": notice.get("source", entry["source"])})
        if entry.get("copyright"):
            text = entry["copyright"]
            component["notices"].append({"kind": "asset-copyright", "paths": ["Embedded font name table"],
                                         "sha256": hashlib.sha256(text.encode()).hexdigest(), "text": text})
        components.append(component)
    return components


def build_bundle(root, checkouts, go):
    inventory_path = root / INVENTORY
    inventory = json.loads(exact_text(inventory_path))
    packages = go_packages(root, inventory, go)
    components = [collect_component("vipin application", "working source tree", "repository:.", root, [])]
    # Avoid walking the entire repository a second time: only its root grant is
    # needed here; dependency notices are collected in their own components.
    components[0]["excluded_notice_candidates"] = []
    pins = {p["identity"]: p for p in json.loads(exact_text(root / RESOLVED))["pins"]}
    for identity, (checkout, source_roots) in SWIFT_PRODUCTS.items():
        pin = pins[identity]
        directory = checkouts / checkout
        revision = run(["git", "-C", str(directory), "rev-parse", "HEAD"])
        if revision != pin["state"]["revision"]:
            raise ValueError(f"Swift checkout {identity} does not match Package.resolved")
        sources = [f.relative_to(directory).as_posix() for subdir in source_roots
                   for f in (directory / subdir).rglob("*") if f.is_file() and f.suffix in SOURCE_SUFFIXES]
        if not sources:
            raise ValueError(f"No Swift product sources found for {identity}: {directory}")
        component = collect_component(checkout, pin["state"]["version"], pin["location"], directory, sources)
        component.update({"ecosystem": "swift", "revision": revision, "identity": identity,
                          "selection": "Notice/header coverage of product source roots; conditional source files may be included."})
        components.append(component)

    modules = {p["Module"]["Path"]: p["Module"] for p in packages if "Module" in p}
    for name, module in sorted(modules.items()):
        directory = Path(module["Dir"])
        selected = [p for p in packages if p.get("Module", {}).get("Path") == name]
        component = collect_component(name, module.get("Version", ""), "https://" + name, directory, selected_files(selected, directory))
        component.update({"ecosystem": "go", "packages": sorted(p["ImportPath"] for p in selected)})
        if name == "github.com/bogdanfinn/fhttp":
            component["review_required"] = "No root LICENSE: per-file headers do not resolve the complete fork grant."
        if name in {"github.com/sagernet/sing-box", "github.com/cacggghp/vk-turn-proxy"}:
            component["local_source"] = directory.relative_to(root).as_posix()
        components.append(component)

    goroot = Path(run([go, "env", "GOROOT"]))
    standard = [p for p in packages if p.get("Standard")]
    runtime = collect_component("Go standard library and runtime", run([go, "version"]), "https://go.dev/", goroot, selected_files(standard, goroot))
    if not runtime["has_root_license"]:
        # Homebrew relocates Go's root LICENSE outside libexec.
        license_path = goroot.parent / "LICENSE"
        if not license_path.is_file():
            raise FileNotFoundError(f"Go runtime LICENSE not found in {goroot} or its parent")
        text = exact_text(license_path)
        runtime["notices"].insert(0, {"kind": "notice-file", "paths": ["LICENSE (toolchain distribution root)"],
                                     "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(), "text": text})
        runtime["has_root_license"] = True
    runtime["ecosystem"] = "go-toolchain"
    runtime["selection"] = "Includes interface/source-header notices for selected standard packages. Inclusion of crypto/internal/boring's notice does not assert BoringSSL is enabled; this iOS graph selects notboring.go."
    components.append(runtime)
    branding = root / "docs/release/branding"
    icon = json.loads(exact_text(branding / "SOURCE.json"))
    components.append(collect_component("Lucide shield-check app icon", icon["revision"], icon["repository"], branding, ["shield-check.svg"]))
    components.extend(supplemental_components(root))
    return {"schema_version": 1,
            "scope": "Notices from the pinned iOS source dependency graph; not a verified SBOM of the prebuilt Libbox.xcframework or final IPA, and not distribution clearance.",
            "selection": "Five audited Swift products; go list -deps selects iOS packages, source/interface files and embedded assets using the recorded environment/build tags. Root notices and nested notices ancestral to selected files are included. Legal source headers and embedded JavaScript legal comments are preserved. This notice coverage does not assert every interface or nested implementation is linked. Unselected nested candidates are listed only in metadata. Swift product roots may conservatively include platform-conditional source headers.",
            "inventory": INVENTORY, "inventory_sha256": hashlib.sha256(inventory_path.read_bytes()).hexdigest(),
            "go_command": inventory["command"], "go_environment": inventory["environment"],
            "go_module_count": len(modules), "swift_product_count": len(SWIFT_PRODUCTS),
            "unresolved": UNRESOLVED, "components": components}


def render_bundle(bundle):
    metadata = copy.deepcopy(bundle)
    sections = ["vipin — software licenses and notices\n\nThis application includes open-source software. Copyright and license notices follow."]
    for index, component in enumerate(bundle["components"]):
        if not component["notices"]:
            continue
        sections.append("=" * 78 + "\n" + component["name"] + "\nVersion: " + component["version"] + "\nSource: " + component["source"])
        for notice in component["notices"]:
            sections.append("--- " + notice["kind"] + " ---\n" + "\n".join(notice["paths"]) + "\n\n" + notice["text"])
        for notice in metadata["components"][index]["notices"]:
            del notice["text"]
    return {"Licenses.txt": "\n\n".join(sections) + "\n",
            "DependencyLicenses.json": json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n"}


def write_outputs(directory, outputs, check=False):
    stale = []
    for name, content in outputs.items():
        path = directory / name
        expected = content.encode("utf-8")
        if check:
            if not path.is_file() or path.read_bytes() != expected:
                stale.append(name)
        else:
            directory.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
    if stale:
        print("Stale/missing release notices: " + ", ".join(stale), file=sys.stderr)
    return not stale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if bundled outputs differ; do not write files")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--swift-checkouts", type=Path, help="Default: build/DerivedData/SourcePackages/checkouts")
    parser.add_argument("--output", type=Path, help="Default: PrototypeApp/Legal")
    parser.add_argument("--go", default="go", help="Go executable for the offline iOS source graph")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        bundle = build_bundle(root, args.swift_checkouts or root / "build/DerivedData/SourcePackages/checkouts", args.go)
        success = write_outputs(args.output or root / "PrototypeApp/Legal", render_bundle(bundle), args.check)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot generate release licenses: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    if success:
        print(f"{'Verified' if args.check else 'Generated'} notices for {bundle['swift_product_count']} Swift products, {bundle['go_module_count']} Go modules, and the Go runtime. Distribution requirements remain unresolved.")
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
