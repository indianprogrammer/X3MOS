#!/usr/bin/env python3
"""Trixie package metadata DB + dependency logic (stdlib only).

Layout (TOP = project dir):
  dl/Packages.trixie.<area>.gz   downloaded indexes (main, contrib, ...)
  package/db.json                 parsed database

Subcommands (all take TOP as first arg after the command):
  db-update TOP                 fetch indexes from the mirror, parse, save
  search TOP TERM [LIMIT]       name/desc search, TSV: name|ver|section|desc
  show TOP PKG                  human-readable metadata + deps + rdeps
  sections TOP                  TSV: section<TAB>package-count
  section-pkgs TOP SEC [LIMIT]  TSV package list for a section
  plan TOP --selected FILE [--os-selected OSFILE] PKG...
                                dependency closure for adding PKGs
  check TOP --selected FILE --core FILE [--os-selected OSFILE]
                                verify a selection
  internal TOP --live FILE [--selected FILE] [--os-selected OSFILE]
           [--category CAT]     list OS-internal (installed) packages as TSV
  os-check TOP --os-selected OSFILE [--selected FILE] [--core FILE]
           [--live FILE]        verify OS removals (boot guards + broken deps)
  rdeps TOP PKG [--selected FILE]   direct reverse dependencies
"""

import gzip
import json
import os
import re
import sys
import urllib.request

AREAS = ["main", "contrib", "non-free", "non-free-firmware"]
DISTRO = "trixie"
ARCH = "binary-amd64"
MIRROR = "http://deb.debian.org/debian"
BASE_PRIORITIES = {"required", "important"}


def paths(top):
    return {
        "dl": os.path.join(top, "dl"),
        "db": os.path.join(top, "package", "db.json"),
    }


def split_top_commas(s):
    """Split a dependency list on top-level commas (parens-aware)."""
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def parse_alt(token):
    """'name [(op ver)]' -> (name, ver|None). Strips :arch qualifiers."""
    token = token.strip()
    m = re.match(r"^([A-Za-z0-9+.:\-]+?)\s*(\(\s*[^)]+\s*\))?$", token)
    if not m:
        return None
    name = m.group(1)
    if ":" in name:  # multi-arch qualifier, e.g. libfoo:amd64
        name = name.split(":")[0]
    ver = m.group(2)
    if ver:
        ver = ver.strip("() ").strip()
    return (name, ver)


def parse_dep_field(value):
    """'a (>= 1) | b, c' -> [[(a,ver),(b,None)], [(c,None)]]."""
    groups = []
    for part in split_top_commas(value or ""):
        alts = []
        for tok in part.split("|"):
            alt = parse_alt(tok)
            if alt and alt[0]:
                alts.append(alt)
        if alts:
            groups.append(alts)
    return groups


def parse_provides(value):
    out = []
    for part in split_top_commas(value or ""):
        alt = parse_alt(part)
        if alt and alt[0]:
            out.append(alt[0])
    return out


def parse_packages_file(path):
    pkgs = {}
    try:
        fh = gzip.open(path, "rt", encoding="utf-8", errors="replace")
    except OSError:
        return pkgs
    with fh:
        entry, field, value = {}, None, ""
        def flush():
            if not entry or "Package" not in entry:
                return
            arch = entry.get("Architecture", "")
            if arch not in ("amd64", "all"):
                return
            name = entry["Package"]
            pkgs[name] = {
                "v": entry.get("Version", ""),
                "ess": entry.get("Essential", "no") == "yes",
                "pri": entry.get("Priority", ""),
                "sec": entry.get("Section", "unknown"),
                "dep": parse_dep_field(entry.get("Depends", "")),
                "pre": parse_dep_field(entry.get("Pre-Depends", "")),
                "conf": [a for a in (parse_alt(t) for t in split_top_commas(entry.get("Conflicts", ""))) if a],
                "brk": [a for a in (parse_alt(t) for t in split_top_commas(entry.get("Breaks", ""))) if a],
                "prov": parse_provides(entry.get("Provides", "")),
                "desc": (entry.get("Description", "").split("\n")[0])[:160],
                "size": int(entry.get("Installed-Size", "0") or "0"),
            }
        for line in fh:
            if line.strip() == "":
                if field:
                    entry[field] = value.rstrip("\n")
                flush()
                entry, field, value = {}, None, ""
            elif line[0] in (" ", "\t"):
                value += line[1:]
            else:
                if field:
                    entry[field] = value.rstrip("\n")
                if ":" in line:
                    field, value = line.split(":", 1)
                    value = value[1:] if value.startswith(" ") else value
                else:
                    field, value = None, ""
        if field:
            entry[field] = value.rstrip("\n")
        flush()
    return pkgs


def cmd_db_update(top):
    p = paths(top)
    os.makedirs(p["dl"], exist_ok=True)
    os.makedirs(os.path.dirname(p["db"]), exist_ok=True)
    db = {}
    for area in AREAS:
        url = "%s/dists/%s/%s/%s/Packages.gz" % (MIRROR, DISTRO, area, ARCH)
        dest = os.path.join(p["dl"], "Packages.%s.%s.gz" % (DISTRO, area))
        print("fetching %s ..." % url)
        urllib.request.urlretrieve(url, dest)
        for name, info in parse_packages_file(dest).items():
            db[name] = info
    with open(p["db"], "w", encoding="utf-8") as fh:
        json.dump({"distro": DISTRO, "areas": AREAS, "packages": db}, fh)
    print("db: %d packages -> %s" % (len(db), p["db"]))


def load_db(top):
    p = paths(top)
    if not os.path.exists(p["db"]):
        sys.stderr.write("package DB missing: %s (run: scripts/package updatedb)\n" % p["db"])
        sys.exit(2)
    with open(p["db"], encoding="utf-8") as fh:
        return json.load(fh)["packages"]


def read_selection(path):
    sel = set()
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^CONFIG_PACKAGE_(.+?)=y\s*$", line.strip())
                if m:
                    sel.add(m.group(1))
    return sel


def read_core(path):
    core = set()
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    core.add(line.split()[0])
    return core


def read_os_selection(path):
    """Parse .config.os-packages.

    Returns (kept, removed):
      kept    CONFIG_OS_<name>=y  (explicitly kept OS/internal package)
      removed '# CONFIG_OS_<name> is not set' (explicitly removed -> excluded
              from bootstrap + purged by chroot hook)
    Absent names default to kept (base image default).
    """
    kept, removed = set(), set()
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                m = re.match(r"^CONFIG_OS_(.+?)=y\s*$", line)
                if m:
                    kept.add(m.group(1))
                    continue
                m = re.match(r"^#\s*CONFIG_OS_(.+?)\s+is\s+not\s+set\s*$", line)
                if m:
                    removed.add(m.group(1))
    return kept, removed


def read_live_set(path):
    """Parse a live-build *.packages file (NAME\\tVERSION per line)."""
    out = set()
    if path and os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                name = line.split()[0]
                if ":" in name:  # arch-qualified, e.g. libc6:amd64
                    name = name.split(":")[0]
                out.add(name)
    return out


LIVE_BOOT_CRITICAL = {
    "live-boot", "live-boot-initramfs-tools", "live-config-systemd",
}

KERNEL_RE = re.compile(r"^(linux-image|linux-headers|linux-base|linux-sysctl|firmware-|.*-microcode|.*-modules-)")


def classify_pkg(db, name):
    """Bucket an installed package for the OS-internal UI."""
    info = db.get(name)
    if info is None:
        return "unknown"
    if info.get("ess"):
        return "essential"
    if name in LIVE_BOOT_CRITICAL or name in ("live-boot", "live-config"):
        if name.startswith("live-"):
            return "live-boot"
    if name.startswith("live-"):
        return "live-docs" if name.endswith(("-doc", "-docs")) else "live-boot"
    if KERNEL_RE.match(name):
        return "kernel"
    if info.get("pri") in BASE_PRIORITIES:
        return "base"
    if info.get("pri") == "standard":
        return "standard"
    return "other"


def base_satisfied(db):
    """Packages present in every build: Essential + required/important."""
    return {n for n, i in db.items() if i["ess"] or i.get("pri") in BASE_PRIORITIES}


def providers_map(db):
    prov = {}
    for name, info in db.items():
        for v in info.get("prov", []):
            prov.setdefault(v, []).append(name)
    return prov


def group_satisfied(group, satisfied, prov):
    for name, _ver in group:
        if name in satisfied:
            return True
        for provider in prov.get(name, []):
            if provider in satisfied:
                return True
    return False


def cmd_search(top, term, limit=40):
    db = load_db(top)
    term = term.lower()
    exact, pref, sub, desc = [], [], [], []
    for name in db:
        ln = name.lower()
        if ln == term:
            exact.append(name)
        elif ln.startswith(term):
            pref.append(name)
        elif term in ln:
            sub.append(name)
        elif term in db[name]["desc"].lower():
            desc.append(name)
    for name in (exact + sorted(pref) + sorted(sub) + sorted(desc))[:limit]:
        i = db[name]
        print("%s\t%s\t%s\t%s" % (name, i["v"], i["sec"], i["desc"]))


def cmd_status(top, selfile):
    db = load_db(top)
    for pkg in sorted(read_selection(selfile)):
        if pkg in db:
            i = db[pkg]
            print("%s\t%s\t%s\t%s" % (pkg, i["v"], i["sec"], i["desc"]))
        else:
            print("%s\t???\t???\t(not in trixie index)" % pkg)


def cmd_show(top, pkg):
    db = load_db(top)
    if pkg not in db:
        print("unknown package: %s" % pkg)
        sys.exit(2)
    i = db[pkg]
    print("Package: %s\nVersion: %s\nSection: %s\nEssential: %s\nPriority: %s\nInstalled-Size: %s kB\nDescription: %s"
          % (pkg, i["v"], i["sec"], "yes" if i["ess"] else "no", i["pri"], i["size"], i["desc"]))
    for label, groups in (("Depends", i["dep"]), ("Pre-Depends", i["pre"])):
        if groups:
            print("%s:" % label)
            for g in groups:
                print("  " + " | ".join(n + (" (%s)" % v if v else "") for n, v in g))
    if i["prov"]:
        print("Provides: %s" % ", ".join(i["prov"]))
    rdeps = sorted(n for n, j in db.items()
                   for g in (j["dep"] + j["pre"]) for n_, _v in g if n_ == pkg)
    print("Reverse-Depends (direct, showing up to 20 of %d): %s"
          % (len(rdeps), ", ".join(rdeps[:20])))


def cmd_sections(top):
    from collections import Counter
    db = load_db(top)
    for sec, cnt in Counter(i["sec"] for i in db.values()).most_common():
        print("%s\t%d" % (sec, cnt))


def cmd_section_pkgs(top, section, limit=200):
    db = load_db(top)
    names = sorted(n for n, i in db.items() if i["sec"] == section)
    for name in names[:limit]:
        i = db[name]
        print("%s\t%s\t%s" % (name, i["v"], i["desc"]))
    if len(names) > limit:
        print("# ... truncated: %d of %d shown (use search to narrow down)"
              % (limit, len(names)))


def plan_add(db, satisfied, pkgs):
    """BFS closure over Depends/Pre-Depends, preferring first alternatives."""
    prov = providers_map(db)
    to_add, notes, queue = [], [], list(pkgs)
    seen = set(satisfied) | set(queue)
    unknown = [p for p in pkgs if p not in db]
    while queue:
        cur = queue.pop(0)
        if cur not in db:
            continue
        for group in db[cur]["dep"] + db[cur]["pre"]:
            if group_satisfied(group, seen, prov):
                continue
            choice = group[0][0]
            if choice in seen:
                continue
            # if the chosen alternative is virtual, take a real provider
            if choice not in db:
                providers = [x for x in prov.get(choice, []) if x in db]
                if not providers:
                    notes.append("%s needs (%s): no installable alternative" %
                                 (cur, " | ".join(n for n, _v in group)))
                    continue
                choice = providers[0]
                notes.append("%s needs %s: auto-selected provider %s" % (cur, group[0][0], choice))
            seen.add(choice)
            queue.append(choice)
            to_add.append(choice)
    return to_add, notes, unknown


def cmd_plan(top, selfile, pkgs, osfile=None):
    db = load_db(top)
    selected = read_selection(selfile)
    satisfied = selected | base_satisfied(db)
    if osfile:
        _kept, removed = read_os_selection(osfile)
        satisfied -= removed
    to_add, notes, unknown = plan_add(db, satisfied, pkgs)
    if unknown:
        print("UNKNOWN: %s" % " ".join(unknown))
        sys.exit(2)
    for n in notes:
        print("NOTE: %s" % n)
    for n in to_add:
        print("TOADD: %s" % n)
    if not to_add and not notes:
        print("PLAN-EMPTY: all dependencies already satisfied")


def effective_base(db, osfile):
    """Base packages assumed present after OS removals are applied."""
    base = base_satisfied(db)
    if osfile:
        _kept, removed = read_os_selection(osfile)
        base -= removed
    return base


def cmd_check(top, selfile, corefile, required=(), osfile=None):
    db = load_db(top)
    selected = read_selection(selfile)
    core = read_core(corefile)
    prov = providers_map(db)
    errors, warnings = [], []
    _kept, os_removed = read_os_selection(osfile) if osfile else (set(), set())
    unknown = sorted(p for p in selected if p not in db)
    for p in unknown:
        errors.append("unknown package (not in trixie index): %s" % p)
    for p in required:
        if p not in selected and p not in core:
            errors.append("locked core package missing (must be in core list): %s" % p)
    # A user-selected package that needs a removed OS package is broken.
    removed_lookup = os_removed
    for pkg in sorted(selected):
        if pkg not in db:
            continue
        info = db[pkg]
        for label, groups in (("Depends", info["dep"]), ("Pre-Depends", info["pre"])):
            for g in groups:
                alts = [n for n, _v in g]
                if not any(a in db or a in prov for a in alts):
                    errors.append("%s %s unsatisfiable from trixie archive: %s" %
                                  (pkg, label, " | ".join(alts)))
                elif any(a in removed_lookup for a in alts) and not any(
                        a in db and a not in removed_lookup for a in alts):
                    errors.append("%s %s %s but it is removed in .config.os-packages" %
                                  (pkg, label, " | ".join(alts)))
        for label, items in (("Conflicts", info["conf"]), ("Breaks", info["brk"])):
            for name, ver in items:
                if name in selected and name != pkg:
                    if ver:
                        warnings.append("%s %s %s (%s) [versioned - verify manually]" %
                                       (pkg, label, name, ver))
                    else:
                        errors.append("%s %s %s (both selected)" % (pkg, label, name))
    # Informative: what apt will pull in on top of the explicit selection.
    satisfied = selected | core | effective_base(db, osfile)
    to_add, _notes, _unknown = plan_add(db, satisfied, sorted(selected))
    for line in errors:
        print("ERROR: %s" % line)
    for line in warnings:
        print("WARNING: %s" % line)
    print("INFO: %d selected (+%d core); apt will auto-install ~%d further dependencies at build time"
          % (len(selected), len(core), len(to_add)))
    if os_removed:
        print("INFO: %d OS package(s) removed via .config.os-packages" % len(os_removed))
    if errors:
        print("CHECK-FAILED: %d error(s)" % len(errors))
        sys.exit(1)
    print("CHECK-OK: %d warning(s)" % len(warnings))


def cmd_internal(top, livefile, selfile=None, osfile=None, category=None):
    """List OS-internal packages (last build's installed set) as TSV.

    TSV: name|ver|section|priority|essential|category|state|desc
    state: user (in .config.packages) | removed (in os removals) |
           kept (explicit keep) | auto (default present)
    """
    db = load_db(top)
    live = read_live_set(livefile) if livefile and os.path.exists(livefile) else set()
    if not live:
        # Fall back to the debootstrap base when no build manifest exists.
        live = base_satisfied(db)
    selected = read_selection(selfile) if selfile else set()
    kept, removed = read_os_selection(osfile) if osfile else (set(), set())
    for name in sorted(live):
        cat = classify_pkg(db, name)
        if category and cat != category:
            continue
        if name in db:
            i = db[name]
            ver, sec, pri = i["v"], i["sec"], i["pri"]
            ess = "yes" if i["ess"] else "no"
            desc = i["desc"]
        else:
            ver, sec, pri, ess, desc = "???", "???", "???", "no", "(not in trixie index)"
        if name in selected:
            state = "user"
        elif name in removed:
            state = "removed"
        elif name in kept:
            state = "kept"
        else:
            state = "auto"
        print("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" % (name, ver, sec, pri, ess, cat, state, desc))


def cmd_os_check(top, selfile, corefile, osfile, livefile=None, required=()):
    """Verify OS removals: unknown names, boot-critical guards, broken deps."""
    db = load_db(top)
    selected = read_selection(selfile) if selfile else set()
    core = read_core(corefile) if corefile else set()
    prov = providers_map(db)
    kept, removed = read_os_selection(osfile) if osfile else (set(), set())
    live = read_live_set(livefile) if livefile and os.path.exists(livefile) else set()
    errors, warnings = [], []
    for p in sorted(removed):
        if p not in db:
            # Allow removing packages that vanished from the archive only
            # if they are not part of the last build (stale entries).
            if p in live or p in selected or p in core:
                errors.append("removed OS package not in trixie index: %s" % p)
            else:
                warnings.append("removed OS package not in index (ignored): %s" % p)
        if p in LIVE_BOOT_CRITICAL:
            errors.append("boot-critical OS package must stay (live boot will fail): %s" % p)
    for p in sorted(required or ()):
        if p in removed:
            errors.append("locked core package removed in .config.os-packages: %s" % p)
    # Every kept+selected package must still have its deps satisfiable
    # without the removed set (providers count as satisfied).
    satisfied = (selected | core | kept | base_satisfied(db)) - removed
    # Also treat the rest of the live set as present (they stay by default).
    satisfied |= (live - removed)
    check_set = sorted((selected | kept | (live & set(db))) - removed)
    for pkg in check_set:
        if pkg not in db:
            continue
        info = db[pkg]
        for label, groups in (("Depends", info["dep"]), ("Pre-Depends", info["pre"])):
            for g in groups:
                if group_satisfied(g, satisfied, prov):
                    continue
                alts = " | ".join(n for n, _v in g)
                # Only flag it when a removed package is the sole satisfier.
                if any(n in removed for n, _v in g):
                    errors.append("%s %s %s broken by OS removal" % (pkg, label, alts))
    for line in errors:
        print("ERROR: %s" % line)
    for line in warnings:
        print("WARNING: %s" % line)
    print("INFO: %d kept, %d removed OS packages" % (len(kept), len(removed)))
    if errors:
        print("OS-CHECK-FAILED: %d error(s)" % len(errors))
        sys.exit(1)
    print("OS-CHECK-OK: %d warning(s)" % len(warnings))


def cmd_rdeps(top, pkg, selfile=None):
    db = load_db(top)
    selected = read_selection(selfile) if selfile else None
    out = []
    for name, info in db.items():
        for g in info["dep"] + info["pre"]:
            if any(n == pkg for n, _v in g):
                if selected is None or name in selected:
                    out.append(name)
                break
    for n in sorted(out):
        print(n)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: pkgdb.py <db-update|search|show|sections|section-pkgs|plan|check|rdeps|internal|os-check> ...\n")
        return 2
    cmd = argv[1]
    if cmd == "db-update":
        cmd_db_update(argv[2])
    elif cmd == "search":
        cmd_search(argv[2], argv[3], int(argv[4]) if len(argv) > 4 else 40)
    elif cmd == "show":
        cmd_show(argv[2], argv[3])
    elif cmd == "status":
        selfile = None
        rest = argv[2:]
        if "--selected" in rest:
            i = rest.index("--selected")
            selfile = rest[i + 1]
        cmd_status(rest[0], selfile)
    elif cmd == "sections":
        cmd_sections(argv[2])
    elif cmd == "section-pkgs":
        cmd_section_pkgs(argv[2], argv[3], int(argv[4]) if len(argv) > 4 else 200)
    elif cmd == "plan":
        selfile = osfile = None
        rest = argv[2:]
        if "--selected" in rest:
            i = rest.index("--selected")
            selfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--os-selected" in rest:
            i = rest.index("--os-selected")
            osfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        top, pkgs = rest[0], rest[1:]
        cmd_plan(top, selfile, pkgs, osfile)
    elif cmd == "check":
        selfile = corefile = osfile = None
        required = []
        rest = argv[2:]
        if "--selected" in rest:
            i = rest.index("--selected")
            selfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--core" in rest:
            i = rest.index("--core")
            corefile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--required" in rest:
            i = rest.index("--required")
            required = rest[i + 1].split(",")
            rest = rest[:i] + rest[i + 2:]
        if "--os-selected" in rest:
            i = rest.index("--os-selected")
            osfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        cmd_check(rest[0], selfile, corefile, required, osfile)
    elif cmd == "internal":
        selfile = osfile = livefile = category = None
        rest = argv[2:]
        if "--selected" in rest:
            i = rest.index("--selected")
            selfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--os-selected" in rest:
            i = rest.index("--os-selected")
            osfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--live" in rest:
            i = rest.index("--live")
            livefile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--category" in rest:
            i = rest.index("--category")
            category = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        cmd_internal(rest[0], livefile, selfile, osfile, category)
    elif cmd == "os-check":
        selfile = corefile = osfile = livefile = None
        required = []
        rest = argv[2:]
        if "--selected" in rest:
            i = rest.index("--selected")
            selfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--core" in rest:
            i = rest.index("--core")
            corefile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--os-selected" in rest:
            i = rest.index("--os-selected")
            osfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--live" in rest:
            i = rest.index("--live")
            livefile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        if "--required" in rest:
            i = rest.index("--required")
            required = rest[i + 1].split(",")
            rest = rest[:i] + rest[i + 2:]
        cmd_os_check(rest[0], selfile, corefile, osfile, livefile, required)
    elif cmd == "rdeps":
        selfile = None
        rest = argv[2:]
        if "--selected" in rest:
            i = rest.index("--selected")
            selfile = rest[i + 1]
            rest = rest[:i] + rest[i + 2:]
        cmd_rdeps(rest[0], rest[1], selfile)
    else:
        sys.stderr.write("unknown command: %s\n" % cmd)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
