"""Check the packager's archive (CI, after the BigWigs dry run). Reads the zip; extracts nothing.

The package is two top-level addons, AltStableSync and AltStableSyncLink (.pkgmeta move-folders).
Each may hold only what it loads: its TOC, the files the TOC lists, the files those XMLs load
(recursively), licences and textures under Libs/. Plus:
- LibAccountSync ships once, in AltStableSync/Libs (#66), and the Link addon loads no library of its
  own. Its store (the household key) is still written to AltStableSyncLink.lua, never to
  AltStableSync.lua: only AltStableSyncLink.toc declares it (#18; test_packaging checks the TOCs).
- Both TOCs carry the same substituted version (never "@project-version@").
- No development file anywhere (Markdown, scripts, tests, docs, tools).
"""
import re
import sys
from pathlib import PurePosixPath
from zipfile import ZipFile

ADDONS = {"AltStableSync": "AltStableSync.toc", "AltStableSyncLink": "AltStableSyncLink.toc"}
MEDIA = {".tga", ".blp"}
DEV = {".md", ".ps1", ".py", ".sh", ".yml", ".yaml", ".json"}
DEV_DIRS = {"tests", "docs", "Tools", ".github", ".claude", "Plugins"}


def norm(path):
    p = PurePosixPath(path.replace("\\", "/"))
    if p.is_absolute() or ".." in p.parts or ":" in str(p):
        raise ValueError(f"unsafe path: {path}")
    return str(p)


def loaded_by_xml(archive, names, xml_path, seen):
    """Every file an XML loads, following <Include> as well as <Script>."""
    if xml_path in seen:
        return set()
    seen.add(xml_path)
    if xml_path not in names:
        raise ValueError(f"missing: {xml_path}")
    text = re.sub(r"<!--.*?-->", "", archive.read(xml_path).decode("utf-8-sig"), flags=re.S)
    base = PurePosixPath(xml_path).parent
    out = {xml_path}
    for tag, ref in re.findall(r'<(Script|Include)\s+file="([^"]+)"', text):
        target = norm(str(base / norm(ref)))
        if tag == "Include" or target.lower().endswith(".xml"):
            out |= loaded_by_xml(archive, names, target, seen)
        else:
            if target not in names:
                raise ValueError(f"{xml_path} loads a missing file: {target}")
            out.add(target)
    return out


def check(path):
    with ZipFile(path) as archive:
        files = [e.filename for e in archive.infolist() if not e.is_dir()]
        if len(files) != len(set(files)):
            raise ValueError("duplicate archive entries")
        names = set(files)
        tops = {n.split("/", 1)[0] for n in names}
        if tops != set(ADDONS):
            raise ValueError(f"top-level folders {sorted(tops)}, want {sorted(ADDONS)}")

        expected, versions = set(), {}
        for addon, toc in ADDONS.items():
            toc_path = f"{addon}/{toc}"
            if toc_path not in names:
                raise ValueError(f"missing TOC: {toc_path}")
            expected.add(toc_path)
            text = archive.read(toc_path).decode("utf-8-sig")
            found = [l.split(":", 1)[1].strip() for l in text.splitlines() if l.startswith("## Version:")]
            if len(found) != 1 or found[0] in {"", "dev", "@project-version@"}:
                raise ValueError(f"{toc_path}: unsubstituted or invalid version {found}")
            versions[addon] = found[0]
            seen = set()
            for line in text.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                target = f"{addon}/{norm(line)}"
                if target.lower().endswith(".xml"):
                    expected |= loaded_by_xml(archive, names, target, seen)
                elif target not in names:
                    raise ValueError(f"{toc_path} lists a missing file: {target}")
                else:
                    expected.add(target)

        if len(set(versions.values())) != 1:
            raise ValueError(f"the two TOCs disagree on the version: {versions}")

        extra = []
        for n in sorted(names - expected):
            parts = PurePosixPath(n).parts
            suffix = PurePosixPath(n).suffix.lower()
            licence = parts[-1].upper().startswith("LICENSE")
            in_libs = len(parts) > 2 and parts[1] == "Libs"
            if (licence and (len(parts) == 2 or in_libs)) or (in_libs and suffix in MEDIA):
                continue
            extra.append(n)
        if extra:
            raise ValueError(f"files nothing loads (development files?): {extra}")

        for n in names:
            parts = PurePosixPath(n).parts
            if PurePosixPath(n).suffix.lower() in DEV or DEV_DIRS & set(parts[1:]):
                raise ValueError(f"development file in the package: {n}")
            if parts[0] == "AltStableSyncLink" and len(parts) > 2 and parts[1] == "Libs":
                raise ValueError(f"a library inside AltStableSyncLink (it loads them from AltStableSync): {n}")
        if not any(n.startswith("AltStableSync/Libs/LibAccountSync-1.0/") for n in names):
            raise ValueError("LibAccountSync missing from AltStableSync/Libs")
        link_toc = archive.read("AltStableSyncLink/AltStableSyncLink.toc").decode("utf-8-sig")
        main_toc = archive.read("AltStableSync/AltStableSync.toc").decode("utf-8-sig")
        if "AltStableSyncLAS" in main_toc or "## SavedVariables: AltStableSyncLAS" not in link_toc:
            raise ValueError("the LibAccountSync store must be declared by AltStableSyncLink.toc only")
        if "AltStableSync/LICENSE" not in names:
            raise ValueError("AltStableSync/LICENSE missing")

    print(f"package: {len(names)} files, two addons, version {versions['AltStableSync']}, nothing extra")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python Tools/check_package.py <release.zip>")
    check(sys.argv[1])
