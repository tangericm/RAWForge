#!/bin/bash
# Stamps the built Info.plist with a build number and the commit it came from.
#
# Runs as a build phase, editing the *built* product rather than the source
# Info.plist — so a build never dirties the working tree, and the number cannot
# be committed by accident.
#
# The build number is a UTC date-time stamp (YYMMDDHHmm). It can never collide
# or go backwards, which is what App Store Connect requires, and reading it off
# a log tells you when that build was cut. The commit is carried separately
# because the number alone cannot say which source produced it.
set -euo pipefail

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$PLIST" ] || { echo "error: no built Info.plist at $PLIST"; exit 1; }

BUILD=$(date -u +%y%m%d%H%M)

cd "${SRCROOT}"
if SHA=$(git rev-parse --short HEAD 2>/dev/null); then
  # A dirty tree means the binary corresponds to no commit anyone else can
  # check out. Saying so is the whole point of carrying the SHA.
  if ! git diff --quiet HEAD 2>/dev/null; then SHA="${SHA}-dirty"; fi
else
  SHA="no-git"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :RAWForgeCommit $SHA" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :RAWForgeCommit string $SHA" "$PLIST"

echo "stamped build $BUILD from commit $SHA"
