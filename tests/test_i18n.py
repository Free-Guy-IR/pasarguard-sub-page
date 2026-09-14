import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = REPO_ROOT / "index.html"

EXPECTED_LOCALES = ("fa", "en", "ru")

STRINGS_LINE = re.compile(r"^\s*var STRINGS\s*=\s*(\{.*\})\s*;\s*$", re.MULTILINE)


def main():
    failures = []
    source = TEMPLATE.read_text(encoding="utf-8")

    matches = STRINGS_LINE.findall(source)
    if len(matches) != 1:
        print("  FAIL: expected exactly one `var STRINGS = {...};` line, found %d" % len(matches))
        return 1

    try:
        strings = json.loads(matches[0])
    except ValueError as error:
        print("  FAIL: the STRINGS table is not valid JSON: %s" % error)
        return 1
    print("  STRINGS parsed as JSON: %d bytes" % len(matches[0]))

    if not isinstance(strings, dict):
        print("  FAIL: the STRINGS table is a %s, not an object" % type(strings).__name__)
        return 1

    locales = sorted(strings)
    if locales != sorted(EXPECTED_LOCALES):
        failures.append(
            "locales are %s, expected exactly %s" % (locales, sorted(EXPECTED_LOCALES))
        )

    tables = {}
    for locale in EXPECTED_LOCALES:
        table = strings.get(locale)
        if not isinstance(table, dict):
            failures.append("locale %r is missing or is not an object" % locale)
            continue
        tables[locale] = table
        print("  %-3s %4d keys" % (locale, len(table)))

    if len(tables) == len(EXPECTED_LOCALES):
        reference = EXPECTED_LOCALES[0]
        reference_keys = set(tables[reference])
        for locale in EXPECTED_LOCALES[1:]:
            other_keys = set(tables[locale])
            missing = sorted(reference_keys - other_keys)
            extra = sorted(other_keys - reference_keys)
            if missing:
                failures.append(
                    "locale %r is missing %d key(s) that %r has: %s"
                    % (locale, len(missing), reference, missing[:10])
                )
            if extra:
                failures.append(
                    "locale %r has %d key(s) %r does not: %s"
                    % (locale, len(extra), reference, extra[:10])
                )

    for locale, table in tables.items():
        for key, value in sorted(table.items()):
            if not isinstance(value, str):
                failures.append(
                    "%s[%r] is a %s, every translation must be a string"
                    % (locale, key, type(value).__name__)
                )

    print("")
    if failures:
        for item in failures:
            print("  FAIL: %s" % item)
        return 1
    print(
        "  PASS: STRINGS is valid JSON, locales are %s, all key sets identical"
        % (list(EXPECTED_LOCALES),)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
