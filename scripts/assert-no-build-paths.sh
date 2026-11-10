#!/bin/bash
# Fail if a built app (or directory) contains the checkout path or $HOME.
# Usage: assert-no-build-paths.sh <scan-path> <checkout-root> [home]
set -euo pipefail
if [[ $# -lt 2 ]]; then
    echo "usage: assert-no-build-paths.sh <scan-path> <checkout-root> [home]" >&2
    exit 2
fi
SCAN="$1"
ROOT="$2"
HOME_PATH="${3:-${HOME:-}}"
if [[ ! -e "$SCAN" ]]; then
    echo "error: path check target does not exist: $SCAN" >&2
    exit 1
fi
python3 - "$SCAN" "$ROOT" "$HOME_PATH" <<'PY'
import os, sys

scan, root, home = sys.argv[1], sys.argv[2], sys.argv[3]
needles = []
for label, raw in (("checkout", root), ("home", home)):
    if not raw:
        continue
    path = os.path.abspath(raw)
    # Never search for a prefix that would match almost every binary.
    if path in ("", "/", "/Users", "/home"):
        continue
    if path not in {p for _, p, _ in needles}:
        needles.append((label, path, path.encode()))

if not needles:
    print("error: no usable checkout or home path to scan for", file=sys.stderr)
    sys.exit(2)

def files(path):
    if os.path.isfile(path):
        yield path
        return
    for dp, dns, fns in os.walk(path):
        for fn in fns:
            yield os.path.join(dp, fn)

found = []
for f in files(scan):
    try:
        data = open(f, "rb").read()
    except OSError:
        continue
    for label, text, needle in needles:
        cap = 0
        i = 0
        while True:
            j = data.find(needle, i)
            if j < 0:
                break
            ctx = data[max(0, j - 40) : j + len(needle) + 60]
            shown = "".join(chr(b) if 32 <= b < 127 else "." for b in ctx)
            found.append((f, label, text, shown))
            cap += 1
            i = j + len(needle)
            if cap >= 5:
                break

if found:
    print(
        f"error: built product leaks a build-machine path ({len(found)} hit(s)):",
        file=sys.stderr,
    )
    for f, label, text, shown in found[:24]:
        print(f"  {f}", file=sys.stderr)
        print(f"    {label}: {text}", file=sys.stderr)
        print(f"    ctx: {shown}", file=sys.stderr)
    sys.exit(1)
PY
