#!/usr/bin/env python3
"""The app's words and their translations.

    scripts/strings.py check     every key the code uses has a translation, and no translation is left over;
                                 the same for the permission prompts in Info.plist (InfoPlist.strings)
    scripts/strings.py update    adds the keys missing from each table, untranslated, to fill in
    scripts/strings.py audit     text in the code that looks like it's shown but is never looked up

The keys come from the compiler (`-emit-localized-strings`), so they are the
ones SwiftUI and `String(localized:)` look up, interpolations included
("Version %@ is available"). English is the code's own text: it has no table.
"""
import glob
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGUAGES = ["pt-PT"]
TARGETS = {"Toolkit": "Resources", "FinderExtension": "Resources/FinderExtension"}


def table_path(target, language):
    return os.path.join(ROOT, TARGETS[target], f"{language}.lproj", "Localizable.strings")


def extract(target):
    """Key -> the first place it's used, from a clean build of `target`."""
    with tempfile.TemporaryDirectory() as out, tempfile.TemporaryDirectory() as build:
        result = subprocess.run(
            ["swift", "build", "--build-path", build, "--product", target,
             "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out],
            cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(result.stdout[-3000:] + result.stderr[-3000:])
        keys = {}
        for path in glob.glob(os.path.join(out, "*.stringsdata")):
            data = json.load(open(path))
            source = os.path.relpath(data["source"], ROOT)
            for entries in data["tables"].values():
                for entry in entries:
                    if entry["key"]:
                        keys.setdefault(entry["key"], f"{source}:{entry['location']['startingLine']}")
        return keys


STRING = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def unescape(text):
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def read_table(path):
    if not os.path.exists(path):
        return {}
    return {unescape(k): unescape(v) for k, v in STRING.findall(open(path, encoding="utf-8").read())}


def write_table(path, table, keys):
    """Sorted by key, each with where it's first used, for whoever translates."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = []
    for key in sorted(table, key=str.lower):
        place = keys.get(key)
        if place:
            lines.append(f"/* {place} */")
        lines.append(f'"{escape(key)}" = "{escape(table[key])}";')
        lines.append("")
    open(path, "w", encoding="utf-8").write("\n".join(lines))


def placeholders(text):
    return re.findall(r"%(?:\d+\$)?(?:@|lld|ld|lf|d|f|\.\d+f)", text.replace("%%", ""))


def check(update):
    problems = 0
    for target in TARGETS:
        keys = extract(target)
        for language in LANGUAGES:
            path = table_path(target, language)
            table = read_table(path)
            missing = sorted(set(keys) - set(table), key=str.lower)
            unused = sorted(set(table) - set(keys), key=str.lower)
            # A translation fills in the same values, in the same order, or the
            # wrong one lands in its place (or the app crashes on a %@ given a number).
            mismatched = sorted(k for k in keys if k in table and placeholders(table[k]) != placeholders(k))
            # Untranslated: left as the English, where that's not the point (a name, a figure).
            same = sorted(k for k in keys if table.get(k) == k and re.search(r"[A-Za-z]{3}", k.replace("%@", "")))
            print(f"{target} {language}: {len(keys)} keys, {len(missing)} missing, {len(unused)} unused, "
                  f"{len(mismatched)} with other values, {len(same)} the same as English")
            for key in missing:
                print(f"  missing  {keys[key]}  {key!r}")
            for key in unused:
                print(f"  unused   {key!r}")
            for key in mismatched:
                print(f"  values   {keys[key]}  {key!r} -> {table[key]!r}")
            problems += len(missing) + len(unused) + len(mismatched)
            problems += check_info_plist(target, language)
            if update and missing:
                for key in missing:
                    table[key] = key
                write_table(path, table, keys)
                print(f"  added {len(missing)} to {os.path.relpath(path, ROOT)}, in English: translate them")
    return problems


def check_info_plist(target, language):
    """The texts macOS shows from Info.plist (the reasons it gives when it asks
    for a permission) are translated in InfoPlist.strings, by their key."""
    plist = plistlib.load(open(os.path.join(ROOT, TARGETS[target], "Info.plist"), "rb"))
    shown = {k for k in plist if k.endswith("UsageDescription")}
    path = os.path.join(ROOT, TARGETS[target], f"{language}.lproj", "InfoPlist.strings")
    table = read_table(path)
    missing, unused = sorted(shown - set(table)), sorted(set(table) - shown)
    for key in missing:
        print(f"  missing  Info.plist  {key!r}")
    for key in unused:
        print(f"  unused   InfoPlist.strings  {key!r}")
    return len(missing) + len(unused)


# Literals that look like words a person reads: a capital and a lowercase
# letter, or a space between words. Code (keys, symbols, identifiers, paths,
# formats) mostly doesn't.
PROSE = re.compile(r'"((?:[^"\\]|\\.)*[A-Za-z]{2,}(?:[^"\\]|\\.)*)"')
SKIP_FILES = ("SelfTest", "Snapshot", "main.swift", "PrivateAPI", "LayoutTrace")
SKIP_LINE = re.compile(r'^\s*(//|///|\*)|NSLog\(|LayoutTrace\.log|print\(|Logger|systemName:|forKey|NSSound\(named|UserDefaults|'
                       r'kAX|com\.apple|x-apple|NSDeviceDescriptionKey|bundleIdentifier|'
                       r'CodingKeys|case \w+ = "|rawValue|attribute\(|URL\(|appendingPathComponent|executableURL|arguments|'
                       r'_silgen_name|Notification\.Name|DispatchQueue\(label|named:|\.sf|font\(|withIdentifier|hasPrefix|hasSuffix|'
                       r'String\(localized:|LocalizedStringKey|\.verbatim\(|Text\("|Button\("|Toggle\("|Menu\("|Picker\("|Label\("|'
                       r'help\("|title: "|caption: "|footnote: "|subtitle: "|text: "|button: "|badge: "|low: "|high: "')


def interpolations_as_percent(literal):
    """`\\(…)` in a Swift literal, nested parentheses and all, as one %."""
    out, i = [], 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[i], 0)
                i += 1
            out.append("%")
        else:
            out.append(literal[i])
            i += 1
    return "".join(out)


def audit():
    keys = set()
    for target in TARGETS:
        keys |= set(extract(target))
    plain = {re.sub(r"%(?:@|lld|lf|ld|d|f)", "%", k) for k in keys}
    found = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "Sources/**/*.swift"), recursive=True)):
        rel = os.path.relpath(path, ROOT)
        if any(skip in rel for skip in SKIP_FILES):
            continue
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            if SKIP_LINE.search(line):
                continue
            for literal in PROSE.findall(line):
                if " " not in literal and not re.match(r"[A-Z][a-z]", literal):
                    continue
                if interpolations_as_percent(literal) in plain:
                    continue
                print(f"{rel}:{number}  {literal!r}")
                found += 1
    print(f"{found} that may be shown without a translation")
    return found


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "check":
        sys.exit(1 if check(update=False) else 0)
    elif command == "update":
        check(update=True)
    elif command == "audit":
        audit()
    else:
        sys.exit(__doc__)
