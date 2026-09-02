#!/usr/bin/env bash
#
# Everything that must be true before an archive is uploaded.
#
# This is the blocking form of the checks CI runs advisorily. CI reports on
# every push, when main is legitimately unverified for most of a development
# cycle; this refuses, because at this point the question is no longer "is the
# work in progress healthy" but "is this the thing that ships".
#
#   bash app/tools/preflight-release.sh
#
# Run it, then archive. It does not archive for you: signing an upload is a
# decision with an audit trail attached, and a script that did it as a side
# effect of a check would be doing something nobody asked for.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

echo "───────────────────────────────────────────────"
echo " 1/5  the tree is committed"
echo "───────────────────────────────────────────────"
if [ -n "$(git status --porcelain)" ]; then
  echo "FAIL: uncommitted changes. A release names a commit." >&2
  git status --short >&2
  exit 1
fi
echo "OK: clean at $(git rev-parse --short HEAD)"

echo
echo "───────────────────────────────────────────────"
echo " 2/5  the simulator suite passes"
echo "───────────────────────────────────────────────"
( cd app && xcodegen generate >/dev/null &&
  xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
    -destination "platform=iOS Simulator,name=${SIM_NAME:-iPhone 17 Pro}" \
    -derivedDataPath /tmp/rawforge-preflight test 2>&1 \
  | grep -E "Executed [0-9]+ tests?, with|TEST SUCCEEDED|TEST FAILED|error:" | tail -3 )

echo
echo "───────────────────────────────────────────────"
echo " 3/5  the privacy and compliance contract holds"
echo "───────────────────────────────────────────────"
bash app/tools/check-compliance.sh

echo
echo "───────────────────────────────────────────────"
echo " 4/5  Release builds and carries no developer-only code"
echo "───────────────────────────────────────────────"
bash app/tools/release-check.sh

echo
echo "───────────────────────────────────────────────"
echo " 5/5  this tree has been run on a phone"
echo "───────────────────────────────────────────────"
bash app/tools/require-hardware-verification.sh

echo
echo "==> preflight passed. Safe to archive."
