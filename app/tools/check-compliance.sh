#!/usr/bin/env bash
#
# Enforces the repository-level privacy and App Store compliance contract.
#
# Run from anywhere:
#
#   bash app/tools/check-compliance.sh
#
# Tests may point the checker at an absolute fixture root without copying this
# script by setting RAWFORGE_REPO_ROOT. The default root is always derived from
# this file, never from the caller's working directory.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
REQUESTED_REPO_ROOT="${RAWFORGE_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

case "$REQUESTED_REPO_ROOT" in
  /*) ;;
  *)
    echo "FAIL [repository-root] RAWFORGE_REPO_ROOT must be an absolute path: $REQUESTED_REPO_ROOT" >&2
    exit 1
    ;;
esac

if [ ! -d "$REQUESTED_REPO_ROOT" ]; then
  echo "FAIL [repository-root] repository root is not a directory: $REQUESTED_REPO_ROOT" >&2
  exit 1
fi

REPO_ROOT="$(cd -- "$REQUESTED_REPO_ROOT" && pwd -P)"
passed=0
failed=0

pass() {
  local label="$1"
  local message="$2"
  printf 'PASS [%s] %s\n' "$label" "$message"
  passed=$((passed + 1))
}

fail() {
  local label="$1"
  local message="$2"
  printf 'FAIL [%s] %s\n' "$label" "$message" >&2
  failed=$((failed + 1))
}

contains_fixed_string() {
  local label="$1"
  local relative_path="$2"
  local needle="$3"
  local success_message="$4"
  local failure_message="$5"
  local path="$REPO_ROOT/$relative_path"

  if [ ! -f "$path" ]; then
    fail "$label" "missing required file: $relative_path"
  elif grep -Fq -- "$needle" "$path"; then
    pass "$label" "$success_message"
  else
    fail "$label" "$failure_message"
  fi
}

omits_fixed_string() {
  local label="$1"
  local relative_path="$2"
  local needle="$3"
  local success_message="$4"
  local failure_message="$5"
  local path="$REPO_ROOT/$relative_path"

  if [ ! -f "$path" ]; then
    fail "$label" "missing required file: $relative_path"
  elif grep -Fq -- "$needle" "$path"; then
    fail "$label" "$failure_message"
  else
    pass "$label" "$success_message"
  fi
}

check_policy_copies() {
  local bundled="app/RAWForge/Resources/privacy-policy.md"
  local app_store="docs/app-store/privacy-policy.md"
  local hosted="docs/privacy/index.md"
  local relative_path

  for relative_path in "$bundled" "$app_store" "$hosted"; do
    if [ ! -f "$REPO_ROOT/$relative_path" ]; then
      fail "privacy-policy-copies" "missing required policy file: $relative_path"
      return
    fi
  done

  if cmp -s "$REPO_ROOT/$bundled" "$REPO_ROOT/$app_store" &&
     cmp -s "$REPO_ROOT/$bundled" "$REPO_ROOT/$hosted"; then
    pass "privacy-policy-copies" "bundled, App Store, and hosted policy files are byte-identical"
  else
    fail "privacy-policy-copies" "policy drift detected; make $bundled, $app_store, and $hosted byte-identical"
  fi
}

echo "==> RAWForge privacy/compliance contract"

SOURCE_DIR="app/RAWForge"
if [ ! -d "$REPO_ROOT/$SOURCE_DIR" ]; then
  fail "in-memory-system-uptime" "missing source directory: $SOURCE_DIR"
elif grep -R -Fq -- "ProcessInfo.processInfo.systemUptime" "$REPO_ROOT/$SOURCE_DIR"; then
  pass "in-memory-system-uptime" "source still uses systemUptime as the required positive control"
else
  fail "in-memory-system-uptime" "ProcessInfo.processInfo.systemUptime was not found under $SOURCE_DIR; the System Boot Time audit has lost its positive control"
fi

FRAME_RECORD="app/RAWForge/Session/FrameRecord.swift"
contains_fixed_string \
  "current-frame-relative-time" \
  "$FRAME_RECORD" \
  "capturedAtSegmentStartSeconds:" \
  "current FrameRecord declares capturedAtSegmentStartSeconds" \
  "current FrameRecord must declare capturedAtSegmentStartSeconds in $FRAME_RECORD"

omits_fixed_string \
  "current-frame-no-capturedAtUptime" \
  "$FRAME_RECORD" \
  "capturedAtUptime:" \
  "current FrameRecord does not declare capturedAtUptime" \
  "legacy capturedAtUptime is declared by the current FrameRecord in $FRAME_RECORD; keep legacy DTO fields inside the explicit migrator"

omits_fixed_string \
  "current-frame-no-uptimeAtDelivery" \
  "$FRAME_RECORD" \
  "uptimeAtDelivery:" \
  "current FrameRecord does not declare uptimeAtDelivery" \
  "legacy uptimeAtDelivery is declared by the current FrameRecord in $FRAME_RECORD; keep legacy DTO fields inside the explicit migrator"

MANIFEST="app/RAWForge/Resources/PrivacyInfo.xcprivacy"
contains_fixed_string \
  "manifest-disk-space-reason" \
  "$MANIFEST" \
  "E174.1" \
  "privacy manifest declares Disk Space reason E174.1" \
  "privacy manifest is missing required Disk Space reason E174.1 in $MANIFEST"

contains_fixed_string \
  "manifest-system-boot-time-reason" \
  "$MANIFEST" \
  "35F9.1" \
  "privacy manifest declares System Boot Time reason 35F9.1" \
  "privacy manifest is missing required System Boot Time reason 35F9.1 in $MANIFEST"

check_policy_copies

PROJECT="app/project.yml"
contains_fixed_string \
  "camera-purpose-string" \
  "$PROJECT" \
  "RAWForge uses the camera to preview your scene and save the RAW captures you choose to make." \
  "project.yml contains the approved Camera purpose string" \
  "project.yml is missing the approved Camera purpose string in $PROJECT"

contains_fixed_string \
  "motion-purpose-string" \
  "$PROJECT" \
  "RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held." \
  "project.yml contains the approved Motion purpose string" \
  "project.yml is missing the approved Motion purpose string in $PROJECT"

PRIVACY_ANSWERS="docs/app-store/privacy-answers.md"
contains_fixed_string \
  "privacy-data-not-collected" \
  "$PRIVACY_ANSWERS" \
  "- Data collection: **Data Not Collected**" \
  "App Store privacy answers state Data Not Collected" \
  "App Store privacy answers must state Data Not Collected in $PRIVACY_ANSWERS"

contains_fixed_string \
  "privacy-tracking-no" \
  "$PRIVACY_ANSWERS" \
  "- Tracking: **No**" \
  "App Store privacy answers state Tracking: No" \
  "App Store privacy answers must state Tracking: No in $PRIVACY_ANSWERS"

LICENSE_PATH="LICENSE"
if [ ! -f "$REPO_ROOT/$LICENSE_PATH" ]; then
  fail "apache-2-license" "missing required file: $LICENSE_PATH"
elif grep -Fq -- "Apache License" "$REPO_ROOT/$LICENSE_PATH" &&
     grep -Fq -- "Version 2.0" "$REPO_ROOT/$LICENSE_PATH"; then
  pass "apache-2-license" "LICENSE contains Apache License, Version 2.0"
else
  fail "apache-2-license" "LICENSE must contain Apache License and Version 2.0"
fi

printf '\nCompliance assertions: %d passed, %d failed.\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  echo "Compliance check failed; resolve every FAIL line above." >&2
  exit 1
fi

echo "Compliance check passed."
