#!/bin/sh
# Signs a packed hap with the SDK's debug profile + OpenHarmony test keystore.
# Usage: sign-hap.sh <toolchains/lib> <unsigned.hap> <signed.hap> <bundle-name> [udid,udid]
set -e
TOOLCHAIN="$1"; IN="$2"; OUT="$3"; BUNDLE="$4"; UDID="${5:-}"
WORK="$(dirname "$OUT")/profile-work"
mkdir -p "$WORK"
python3 - "$TOOLCHAIN/UnsgnedDebugProfileTemplate.json" "$WORK/profile.json" "$BUNDLE" "$UDID" <<'PY'
import json, sys, time
src, dst, bundle, udid = sys.argv[1:5]
d = json.load(open(src))
now = int(time.time())
d["validity"] = {"not-before": now - 3600, "not-after": now + 10 * 365 * 24 * 3600}
d["bundle-info"]["bundle-name"] = bundle
if udid:
    d["debug-info"] = {"device-ids": [u for u in udid.split(",") if u]}
json.dump(d, open(dst, "w"), indent=1)
PY
"$TOOLCHAIN/hap-sign-tool" sign-profile -keyAlias "openharmony application profile debug" \
  -signAlg SHA256withECDSA -mode localSign -profileCertFile "$TOOLCHAIN/OpenHarmonyProfileDebug.pem" \
  -inFile "$WORK/profile.json" -keystoreFile "$TOOLCHAIN/OpenHarmony.p12" -outFile "$WORK/debug.p7b" \
  -keyPwd 123456 -keystorePwd 123456
"$TOOLCHAIN/hap-sign-tool" sign-app -keyAlias "openharmony application release" \
  -signAlg SHA256withECDSA -mode localSign -appCertFile "$TOOLCHAIN/OpenHarmonyApplication.pem" \
  -profileFile "$WORK/debug.p7b" -inFile "$IN" -keystoreFile "$TOOLCHAIN/OpenHarmony.p12" \
  -outFile "$OUT" -keyPwd 123456 -keystorePwd 123456 -signCode 1
"$TOOLCHAIN/hap-sign-tool" verify-app -inFile "$OUT" -outCertChain "$WORK/out.cer" -outProfile "$WORK/out.p7b" | tail -1
ls -l "$OUT"
