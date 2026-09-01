#!/usr/bin/env bash
#
# Runs the device-only tests on a tethered phone and records that it happened.
#
# The tests this exists for are the ones a simulator cannot answer: whether
# a Bayer format is actually offered, whether an exposure lock lands where it
# was asked, whether a bracket past the ceiling splits at the seam. Everywhere
# else they skip, and a skip reads as green.
#
# Two refusals are deliberate:
#
#   * A dirty tree cannot be verified. The ledger names a commit, and a commit
#     does not describe uncommitted edits.
#   * No phone is not a pass. It exits non-zero and says so, rather than
#     recording a run that did not happen.
#
# Known limitation, and it is not fixable here: camera permission needs a
# physical tap the first time the app is installed on a device. Once granted it
# survives reinstalls, so this is automatable on a phone that has run the app
# before and manual exactly once per device.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(cd .. && pwd)"
LEDGER="$REPO_ROOT/docs/hardware-verification.json"

# --- the tree must be committed -------------------------------------------

if [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  echo "FAIL: app/ has uncommitted changes." >&2
  echo "A verification names a commit; it cannot name a working tree." >&2
  exit 1
fi
COMMIT=$(git rev-parse HEAD)

# --- find a phone ----------------------------------------------------------

echo "==> looking for a tethered device"
DEVICE_JSON=$(mktemp)
trap 'rm -f "$DEVICE_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1 || true

read -r UDID NAME MODEL OSVER < <(python3 - "$DEVICE_JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("platform") != "iOS":
        continue
    # available/connected wording has moved between Xcode releases, so this
    # asks the tolerant question rather than matching one exact string.
    if "connected" not in str(conn.get("tunnelState", "")).lower() \
       and "connected" not in str(conn.get("pairingState", "")).lower():
        continue
    print(hw.get("udid", ""),
          (d.get("deviceProperties", {}).get("name") or "device").replace(" ", "_"),
          hw.get("productType", "?"),
          d.get("deviceProperties", {}).get("osVersionNumber", "?"))
    break
PY
) || true

if [ -z "${UDID:-}" ]; then
  echo "FAIL: no tethered iOS device found." >&2
  echo "Connect the phone, unlock it, and trust this Mac. Nothing was recorded." >&2
  exit 1
fi
echo "    $NAME · $MODEL · iOS $OSVER · $UDID"

# --- signing ---------------------------------------------------------------

# Not hard-coded: the team is the certificate's organizational unit, and the
# suffix in the identity's common name is the *user* ID — passing that instead
# fails with "No Account for Team", which cost an afternoon once.
TEAM="${DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o 'Apple Development: [^"]*' | head -1 \
    | { read -r ident; [ -n "$ident" ] && security find-certificate -c "$ident" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | awk -F' = ' '/organizationalUnitName/ {print $2}' | head -1; } || true)
fi
if [ -z "$TEAM" ]; then
  echo "FAIL: no development team. Set DEVELOPMENT_TEAM=<team id> and re-run." >&2
  exit 1
fi
echo "    team $TEAM"

# --- run -------------------------------------------------------------------

xcodegen generate >/dev/null

LOG=$(mktemp)
echo "==> running the suite on the device"
set +e
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath /tmp/rawforge-hardware \
  DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates \
  test 2>&1 | tee "$LOG" | grep -E "Executed [0-9]+ test|TEST SUCCEEDED|TEST FAILED|error:"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$STATUS" -ne 0 ]; then
  echo >&2
  echo "FAIL: the device suite did not pass. Nothing recorded." >&2
  echo "Full log: $LOG" >&2
  exit 1
fi

# The line that matters is the last summary: how many actually ran, and how
# many still skipped. A run where everything skipped is not a verification, and
# this is where that would show.
SUMMARY=$(grep -E "Executed [0-9]+ tests?" "$LOG" | tail -1)
EXECUTED=$(echo "$SUMMARY" | grep -oE "Executed [0-9]+" | grep -oE "[0-9]+" || echo 0)
SKIPPED=$(echo "$SUMMARY" | grep -oE "[0-9]+ tests? skipped" | grep -oE "[0-9]+" || echo 0)

if [ "$SKIPPED" -gt 0 ]; then
  echo
  echo "NOTE: $SKIPPED test(s) still skipped on a real device."
  echo "If that is the device-only suite, this run verified nothing it was meant to."
fi

# --- record ----------------------------------------------------------------

python3 - "$LEDGER" "$COMMIT" "$MODEL" "$OSVER" "$EXECUTED" "$SKIPPED" <<'PY'
import json, sys, datetime
path, commit, model, osver, executed, skipped = sys.argv[1:7]
json.dump({
    "_comment": ("Written by app/tools/run-hardware-suite.sh. Read by "
                 "app/tools/require-hardware-verification.sh, which the release preflight "
                 "refuses to pass without. Never edited by hand — a hand-edited entry is a "
                 "claim nobody made."),
    "commit": commit,
    "verifiedAt": datetime.datetime.now(datetime.timezone.utc)
                    .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "device": model,
    "systemVersion": osver,
    "testsExecuted": int(executed),
    "testsSkipped": int(skipped),
    "note": None,
}, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY

echo
echo "==> recorded: ${COMMIT:0:8} verified on $MODEL (iOS $OSVER)"
echo "    Commit docs/hardware-verification.json to make the claim part of the history."
