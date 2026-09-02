#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
CHECKER="$REPO_ROOT/app/tools/check-compliance.sh"
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$FIXTURE_ROOT"' EXIT

required_paths=(
  "LICENSE"
  "app/project.yml"
  "app/RAWForge/Capture/StationController.swift"
  "app/RAWForge/Session/FrameRecord.swift"
  "app/RAWForge/Resources/PrivacyInfo.xcprivacy"
  "app/RAWForge/Resources/privacy-policy.md"
  "docs/app-store/privacy-answers.md"
  "docs/app-store/privacy-policy.md"
  "docs/privacy/index.md"
)

reset_fixture() {
  local relative_path
  for relative_path in "${required_paths[@]}"; do
    mkdir -p -- "$FIXTURE_ROOT/$(dirname -- "$relative_path")"
    cp -- "$REPO_ROOT/$relative_path" "$FIXTURE_ROOT/$relative_path"
  done
}

expect_rejection() {
  local expected_label="$1"
  local expected_message="$2"
  local output
  local status

  set +e
  output="$(RAWFORGE_REPO_ROOT="$FIXTURE_ROOT" bash "$CHECKER" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    printf 'FAIL: checker accepted fixture that should fail [%s]\n%s\n' \
      "$expected_label" "$output" >&2
    exit 1
  fi
  if ! grep -Fq -- "FAIL [$expected_label]" <<<"$output"; then
    printf 'FAIL: checker rejected fixture without [%s]\n%s\n' \
      "$expected_label" "$output" >&2
    exit 1
  fi
  if grep -Fq -- "Swift declaration scan failed" <<<"$output"; then
    printf 'FAIL: checker rejected [%s] because its source scan failed\n%s\n' \
      "$expected_label" "$output" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected_message" <<<"$output"; then
    printf 'FAIL: checker rejected [%s] without the expected behavior message\n%s\n' \
      "$expected_label" "$output" >&2
    exit 1
  fi
  printf 'PASS: checker rejected [%s]\n' "$expected_label"
}

reset_fixture
perl -0pi -e \
  's/(let photoTimestampAtSegmentStartSeconds: TimeInterval\?)/$1\n    let photoTimestampSeconds: Double?/' \
  "$FIXTURE_ROOT/app/RAWForge/Session/FrameRecord.swift"
expect_rejection \
  "current-frame-no-photoTimestampSeconds" \
  "legacy photoTimestampSeconds appears in the current FrameRecord durable contract"

reset_fixture
perl -0pi -e \
  's/photoTimestampAtSegmentStartSeconds/photoTimestampAtSomeOtherOriginSeconds/g' \
  "$FIXTURE_ROOT/app/RAWForge/Session/FrameRecord.swift"
expect_rejection \
  "current-frame-photo-relative-time" \
  "current FrameRecord must declare stored let photoTimestampAtSegmentStartSeconds"

echo "Compliance checker behavior fixtures passed."
