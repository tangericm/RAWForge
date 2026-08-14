#!/usr/bin/env bash
#
# Refuses when the code about to ship has not been run on a phone.
#
# 13 of this suite's tests need a real sensor and are skipped everywhere else.
# Skipped reads as green, so a simulator run says nothing about them — and the
# situation this exists to prevent is already the situation we are in: #17 and
# #18 are both merged to main with device runs outstanding, and until this
# script existed nothing in the repo recorded that.
#
# The gate is deliberately *not* strict SHA equality. Verification is a claim
# about a binary, so it survives a commit that cannot change the binary — a doc
# edit, an ADR, a workflow tweak. It is invalidated by anything under app/.
#
# Exit 0 = the working tree is covered by a real device run.
# Exit 1 = it is not, and the reason is printed.
#
# `--warn` reports without failing, which is what CI uses: main is legitimately
# unverified for most of a development cycle, and a red badge that is red by
# design gets ignored. The release preflight uses the failing form.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

LEDGER="docs/hardware-verification.json"
WARN_ONLY=0
[ "${1:-}" = "--warn" ] && WARN_ONLY=1

fail() {
  echo "$1" >&2
  if [ "$WARN_ONLY" -eq 1 ]; then
    echo "(warning only — the release preflight would refuse here)" >&2
    exit 0
  fi
  exit 1
}

[ -f "$LEDGER" ] || fail "FAIL: no $LEDGER — hardware verification has no record at all."

verified=$(python3 -c "
import json,sys
try: print(json.load(open('$LEDGER')).get('commit') or '')
except Exception as e: sys.exit('unreadable ledger: %s' % e)
")

if [ -z "$verified" ]; then
  fail "FAIL: the device-only suite has never been recorded as passing.
Run:  bash app/tools/run-hardware-suite.sh"
fi

if ! git cat-file -e "${verified}^{commit}" 2>/dev/null; then
  fail "FAIL: $LEDGER names commit $verified, which is not in this repository.
A rewritten history invalidates the claim — re-run the device suite."
fi

if ! git merge-base --is-ancestor "$verified" HEAD 2>/dev/null; then
  fail "FAIL: the verified commit ${verified:0:8} is not an ancestor of HEAD.
The verified work is not in what you are about to ship."
fi

# Only app/ can change the binary. Everything else may move freely without
# invalidating a device run, and pretending otherwise would make the gate so
# noisy it would be bypassed.
changed=$(git diff --name-only "$verified" HEAD -- app/ || true)
if [ -n "$changed" ]; then
  count=$(echo "$changed" | wc -l | tr -d ' ')
  fail "FAIL: $count file(s) under app/ have changed since the last device run (${verified:0:8}):

$(echo "$changed" | sed 's/^/  /' | head -20)

The device-only suite covers what a simulator cannot: whether the locks hold,
whether Bayer capture actually fires, whether a bracket splits at the seam.
None of that is known for this tree."
fi

echo "OK: HEAD is covered by the device run recorded at ${verified:0:8}"
python3 -c "
import json
d = json.load(open('$LEDGER'))
print('    device   %s (%s)' % (d.get('device'), d.get('systemVersion')))
print('    when     %s' % d.get('verifiedAt'))
print('    tests    %s executed, %s skipped' % (d.get('testsExecuted'), d.get('testsSkipped')))
"
