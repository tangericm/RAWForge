#!/usr/bin/env bash
#
# Builds Release and proves the developer-only code is not in it.
#
# Two separate jobs, and both have caught something real:
#
#   1. Release had never been built at all until late in this project. Debug
#      and Release differ in whole-module optimisation, and that is exactly
#      where a latent problem surfaces — a build that only ever runs Debug is
#      not a build that is known to ship.
#
#   2. The instrument checks were still in a Release binary after a commit
#      claimed they had been removed. The NavigationLink was gated; the view
#      behind it was not. The diff looked right. `strings` did not.
#
# App Store guideline 2.3.1(a) forbids shipping hidden or undocumented
# features, so this is a review exposure and not only tidiness.
#
# ## Why every check carries a positive control
#
# The first version of this script checked six literal strings and reported six
# passes. Two of them — "RAWFORGE_DEMO" and "focus-point" — are absent from the
# *Debug* binary too, so those checks could never have failed. Swift stores
# short string literals inline in the String struct rather than in __TEXT, and
# `strings` cannot see them at any optimisation level.
#
# A check that cannot fail is worse than no check: it reports safety it has not
# established. So each token must be **found in Debug** before its absence from
# Release means anything, and a token that cannot be seen in Debug fails the
# run as a broken check rather than passing as a clean result.
#
# Symbol names are the reliable half — type metadata survives where a short
# literal does not — so the tokens are mostly types.
#
# Invoked through bash everywhere (CI, hooks, by hand): this repo has
# core.fileMode = false, so git never records the executable bit and a fresh
# clone gets "Permission denied" from anything run directly.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DERIVED="${DERIVED_DATA:-/tmp/rawforge-release-check}"
SIM="${SIM_NAME:-iPhone 17 Pro}"

# Must be present in Debug and absent from Release.
FORBIDDEN=(
  "DemoSeed"                        # simulator demo seeding (#23, #18)
  "InstrumentChecksView"            # the developer probe screen (#14)
  "zoom-probe-stages.json"          # its zoom-enforcement run
  "item3 white-balance pixel path"  # its white-balance pixel-path run
)

# Must be present in BOTH. If one of these ever reads zero the tooling is
# broken — wrong binary, stripped symbols, a `nm` that failed silently — and
# every "absent from Release" result above is meaningless.
CONTROLS=( "CaptureModel" "BenchModel" )

seen() {  # seen <binary> <token> -> count across strings and symbols
  local bin="$1" tok="$2" a b
  a=$(strings "$bin" 2>/dev/null | grep -cF "$tok" || true)
  b=$(nm "$bin" 2>/dev/null | grep -cF "$tok" || true)
  echo $(( a + b ))
}

echo "==> generating the project (.xcodeproj is not committed)"
xcodegen generate >/dev/null

echo "==> building Debug (the positive control)"
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$DERIVED" -quiet build

echo "==> building Release"
xcodebuild -project RAWForge.xcodeproj -scheme RAWForge \
  -configuration Release \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$DERIVED" -quiet build

DBG="$DERIVED/Build/Products/Debug-iphonesimulator/RAWForge.app/RAWForge"
REL="$DERIVED/Build/Products/Release-iphonesimulator/RAWForge.app/RAWForge"
for b in "$DBG" "$REL"; do
  [ -f "$b" ] || { echo "FAIL: no binary at $b" >&2; exit 1; }
done

failed=0

echo
echo "==> controls (must appear in both binaries)"
for t in "${CONTROLS[@]}"; do
  d=$(seen "$DBG" "$t"); r=$(seen "$REL" "$t")
  if [ "$d" -gt 0 ] && [ "$r" -gt 0 ]; then
    printf "  ok      %-32s debug=%-5s release=%s\n" "$t" "$d" "$r"
  else
    printf "  BROKEN  %-32s debug=%-5s release=%s\n" "$t" "$d" "$r" >&2
    echo "          the inspection itself is not working; ignore every result below" >&2
    failed=1
  fi
done

echo
echo "==> developer-only code (must appear in Debug, never in Release)"
for t in "${FORBIDDEN[@]}"; do
  d=$(seen "$DBG" "$t"); r=$(seen "$REL" "$t")
  if [ "$d" -eq 0 ]; then
    printf "  BLIND   %-32s not visible in Debug either — this check proves nothing\n" "$t" >&2
    failed=1
  elif [ "$r" -gt 0 ]; then
    printf "  LEAK    %-32s debug=%-5s release=%s\n" "$t" "$d" "$r" >&2
    failed=1
  else
    printf "  ok      %-32s debug=%-5s release=0\n" "$t" "$d"
  fi
done

if [ "$failed" -ne 0 ]; then
  echo >&2
  echo "FAIL: see above. A LEAK means developer-only code reached Release —" >&2
  echo "gating the navigation to a view is not the same as gating the view." >&2
  echo "A BLIND means the check cannot see its own token and must be replaced." >&2
  exit 1
fi

echo
echo "==> Release builds, and carries none of the developer-only code"
