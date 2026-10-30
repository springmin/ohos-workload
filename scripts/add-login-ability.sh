#!/bin/sh
# add-login-ability.sh - add a second UIAbility to an OpenHarmony hap and sign it.
#
# The OpenHarmony MAUI pack emits one ability (EntryAbility). This post-processor appends a
# `LoginAbility` entry that reuses the same ArkTS shell entry (`srcEntry`) and the same .NET
# payload, with launchType=multiton, so the OS can start it as a separate ability/instance:
#
#   sh scripts/add-login-ability.sh <udid> --unsigned <hap> --out <hap>
#
# It is a probe, not a pack feature: the second ability currently renders the start window
# (the shared MAUI host binds the main EntryAbility surface), so treat the UI as pending.
# The patch is applied to the UNSIGNED hap; signing uses scripts/sign-for-device.sh (debug
# profile for the given UDID).
set -eu

if [ $# -lt 1 ]; then
    sed -n '2,13p' "$0"
    exit 2
fi

UDID=$1
shift
UNSIGNED=
OUT=
while [ $# -gt 0 ]; do
    case "$1" in
        --unsigned) UNSIGNED=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        *) echo "add-login-ability: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$UNSIGNED" ] && [ -f "$UNSIGNED" ] || { echo "add-login-ability: --unsigned <hap> is required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "add-login-ability: --out <hap> is required" >&2; exit 2; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/data/storage/el2/base/tmp/opencode}/loginability.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15
mkdir -p "$WORK/unpacked"
unzip -q "$UNSIGNED" -d "$WORK/unpacked"

python3 - "$WORK/unpacked/module.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
abilities = d["module"]["abilities"]
if any(a.get("name") == "LoginAbility" for a in abilities):
    print("LoginAbility already present")
    raise SystemExit(0)
a = abilities[0]
login = {
    "name": "LoginAbility",
    "srcEntry": a["srcEntry"],
    "description": a["description"],
    "icon": a["icon"],
    "label": a["label"],
    "startWindowIcon": a["startWindowIcon"],
    "startWindowBackground": a["startWindowBackground"],
    "supportWindowModes": a.get("supportWindowModes", ["fullscreen", "split", "floating"]),
    "exported": True,
    "launchType": "multiton",
    "process": "login",
}
abilities.append(login)
json.dump(d, open(p, "w"), ensure_ascii=False, separators=(",", ":"))
print("abilities:", [x["name"] for x in abilities])
PY

( cd "$WORK/unpacked" && find . -type f | zip -q -X "$WORK/patched-unsigned.hap" -@ )
sh "$HERE/sign-for-device.sh" "$UDID" --unsigned "$WORK/patched-unsigned.hap" --out "$OUT"
echo "second-ability hap: $OUT"
