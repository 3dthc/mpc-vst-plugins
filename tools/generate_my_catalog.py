#!/usr/bin/env python3
"""Create or update catalog entries for my MPC/Force plugins."""

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_DIR = ROOT / "catalog" / "plugins"

PROJECTS = [
    {
        "id": "fretty",
        "name": "Fretty",
        "repo": "3dthc/fretty-mpc",
        "local": Path.home() / "fretty-mpc",
        "kind": "instrument",
    },
    {
        "id": "obxd",
        "name": "OB-Xd",
        "repo": "3dthc/OB-XD-MPC",
        "local": Path.home() / "mpc-vst-obxd",
        "kind": "instrument",
    },
    {
        "id": "odin2",
        "name": "Odin 2",
        "repo": "3dthc/Odin2-MPC",
        "local": Path.home() / "odin2-mpc-1.3" / "Odin2-MPC",
        "kind": "instrument",
    },
    {
        "id": "sonix",
        "name": "Sonix",
        "repo": "3dthc/Sonix",
        "local": Path.home() / "Sonix",
        "kind": "instrument",
    },
]


def github_metadata(repo):
    """Read repository metadata using the GitHub CLI."""
    try:
        result = subprocess.run(
            [
                "gh", "repo", "view", repo,
                "--json", "nameWithOwner,description,licenseInfo,owner",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"  WARNING: unable to read GitHub metadata: {exc}")
        return {}


def readme_summary(directory):
    """Find a plausible summary paragraph in a README."""
    if not directory.is_dir():
        return ""

    names = ("README.md", "readme.md", "README", "README.rst", "README.txt")

    for name in names:
        path = directory / name
        if not path.is_file():
            continue

        content = path.read_text(encoding="utf-8", errors="replace")
        content = re.sub(r"<!--.*?-->", "", content, flags=re.S)

        for paragraph in re.split(r"\n\s*\n", content):
            paragraph = paragraph.strip()

            if not paragraph or paragraph.startswith(
                ("#", "!", "<", "[![", "```")
            ):
                continue

            paragraph = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", paragraph)
            paragraph = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", paragraph)
            paragraph = re.sub(r"`([^`]+)`", r"\1", paragraph)
            paragraph = " ".join(paragraph.split()).strip(" -*_")

            if len(paragraph) >= 25 and not paragraph.startswith("http"):
                return paragraph[:300].rstrip()

    return ""


def get_license(existing, metadata, directory):
    """Determine the project's license without guessing."""
    if existing.get("license"):
        return existing["license"]

    info = metadata.get("licenseInfo") or {}

    spdx = info.get("spdxId")
    if spdx and spdx != "NOASSERTION":
        return spdx

    # GitHub can recognize a license key without returning an SPDX ID.
    key_to_spdx = {
        "mit": "MIT",
        "gpl-3.0": "GPL-3.0-only",
        "gpl-3.0-only": "GPL-3.0-only",
        "gpl-3.0-or-later": "GPL-3.0-or-later",
    }

    key = (info.get("key") or "").lower()
    if key in key_to_spdx:
        return key_to_spdx[key]

    # Check local license files for an explicit SPDX identifier.
    for filename in ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"):
        path = directory / filename
        if not path.is_file():
            continue

        content = path.read_text(encoding="utf-8", errors="replace")[:20000]

        match = re.search(
            r"SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+)",
            content,
        )
        if match:
            return match.group(1)

        # Identify the standard GPL version 3 license text.
        if (
            "GNU GENERAL PUBLIC LICENSE" in content
            and re.search(r"Version 3,\s*29 June 2007", content)
        ):
            return "GPL-3.0-only"

    return ""


def main():
    PLUGIN_DIR.mkdir(parents=True, exist_ok=True)
    failed = []

    for project in PROJECTS:
        plugin_id = project["id"]
        path = PLUGIN_DIR / f"{plugin_id}.json"

        existing = {}
        if path.exists():
            try:
                existing = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                print(f"SKIP {plugin_id}: existing JSON is invalid: {exc}")
                failed.append(plugin_id)
                continue

        print(f"\n{plugin_id}: checking {project['repo']}")

        metadata = github_metadata(project["repo"])
        description = (metadata.get("description") or "").strip()

        summary = (
            existing.get("summary")
            or description
            or readme_summary(project["local"])
        )

        license_id = get_license(
            existing, metadata, project["local"]
        )

        if not summary:
            print("  SKIP: no summary found.")
            failed.append(plugin_id)
            continue

        if not license_id:
            print("  SKIP: project license is unknown; entry not written.")
            failed.append(plugin_id)
            continue

        owner = metadata.get("owner") or {}
        author = (
            existing.get("author")
            or owner.get("login")
            or project["repo"].split("/")[0]
        )

        # Preserve existing tags, screenshots, style, and other metadata.
        entry = dict(existing)
        entry.update({
            "id": plugin_id,
            "name": existing.get("name") or project["name"],
            "author": author,
            "repo": project["repo"],
            "kind": existing.get("kind") or project["kind"],
            "license": license_id,
            "summary": summary,
            "asset_pattern": existing.get(
                "asset_pattern", "*-mpc-armv7.zip"
            ),
        })

        path.write_text(
            json.dumps(entry, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"  WROTE: {path.relative_to(ROOT)}")

    print("\nDone.")
    if failed:
        print("Needs attention: " + ", ".join(failed))
    print("Review changes with: git diff -- catalog/plugins/")


if __name__ == "__main__":
    main()
