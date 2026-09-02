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
SEARCH_STATUS=0
SEARCH_OUTPUT=""

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

run_fixed_search() {
  local match_mode="$1"
  local needle="$2"
  local path="$3"

  if [ "$match_mode" = "line" ]; then
    if grep -Fqx -- "$needle" "$path" 2>/dev/null; then
      SEARCH_STATUS=0
    else
      SEARCH_STATUS=$?
    fi
  else
    if grep -Fq -- "$needle" "$path" 2>/dev/null; then
      SEARCH_STATUS=0
    else
      SEARCH_STATUS=$?
    fi
  fi
}

collect_fixed_matches() {
  local needle="$1"
  local path="$2"

  if SEARCH_OUTPUT="$(grep -F -- "$needle" "$path" 2>/dev/null)"; then
    SEARCH_STATUS=0
  else
    SEARCH_STATUS=$?
  fi
}

fail_search_error() {
  local label="$1"
  local relative_path="$2"
  fail "$label" "fixed-string search failed for $relative_path (grep exit $SEARCH_STATUS); verify that the file is readable"
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
  else
    run_fixed_search "substring" "$needle" "$path"
    case "$SEARCH_STATUS" in
      0) pass "$label" "$success_message" ;;
      1) fail "$label" "$failure_message" ;;
      *) fail_search_error "$label" "$relative_path" ;;
    esac
  fi
}

contains_exact_line() {
  local label="$1"
  local relative_path="$2"
  local needle="$3"
  local success_message="$4"
  local failure_message="$5"
  local path="$REPO_ROOT/$relative_path"

  if [ ! -f "$path" ]; then
    fail "$label" "missing required file: $relative_path"
  else
    run_fixed_search "line" "$needle" "$path"
    case "$SEARCH_STATUS" in
      0) pass "$label" "$success_message" ;;
      1) fail "$label" "$failure_message" ;;
      *) fail_search_error "$label" "$relative_path" ;;
    esac
  fi
}

exact_answer_line() {
  local label="$1"
  local relative_path="$2"
  local answer_prefix="$3"
  local expected_line="$4"
  local success_message="$5"
  local path="$REPO_ROOT/$relative_path"

  if [ ! -f "$path" ]; then
    fail "$label" "missing required file: $relative_path"
    return
  fi

  run_fixed_search "line" "$expected_line" "$path"
  case "$SEARCH_STATUS" in
    1)
      fail "$label" "$relative_path must contain the exact unqualified answer line: $expected_line"
      return
      ;;
    0) ;;
    *)
      fail_search_error "$label" "$relative_path"
      return
      ;;
  esac

  collect_fixed_matches "$answer_prefix" "$path"
  case "$SEARCH_STATUS" in
    0)
      if [ "$SEARCH_OUTPUT" = "$expected_line" ]; then
        pass "$label" "$success_message"
      else
        fail "$label" "$relative_path contains a contradictory, duplicate, or qualified $answer_prefix answer"
      fi
      ;;
    1)
      fail "$label" "$relative_path is missing answer prefix: $answer_prefix"
      ;;
    *)
      fail_search_error "$label" "$relative_path"
      ;;
  esac
}

omits_exact_lines() {
  local label="$1"
  local relative_path="$2"
  local success_message="$3"
  local failure_message="$4"
  local path="$REPO_ROOT/$relative_path"
  local needle

  shift 4

  if [ ! -f "$path" ]; then
    fail "$label" "missing required file: $relative_path"
    return
  fi

  for needle in "$@"; do
    run_fixed_search "line" "$needle" "$path"
    case "$SEARCH_STATUS" in
      0)
        fail "$label" "$failure_message"
        return
        ;;
      1) ;;
      *)
        fail_search_error "$label" "$relative_path"
        return
        ;;
    esac
  done

  pass "$label" "$success_message"
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

UPTIME_SOURCE="app/RAWForge/Capture/StationController.swift"
contains_exact_line \
  "in-memory-system-uptime" \
  "$UPTIME_SOURCE" \
  "        uptime: { ProcessInfo.processInfo.systemUptime }," \
  "audited StationClock.live implementation reads systemUptime in memory" \
  "audited executable systemUptime line is missing from $UPTIME_SOURCE; comments, resources, and obsolete code do not satisfy the positive control"

FRAME_RECORD="app/RAWForge/Session/FrameRecord.swift"
contains_exact_line \
  "current-frame-relative-time" \
  "$FRAME_RECORD" \
  "    let capturedAtSegmentStartSeconds: TimeInterval" \
  "current FrameRecord declares capturedAtSegmentStartSeconds" \
  "current FrameRecord must declare capturedAtSegmentStartSeconds in $FRAME_RECORD"

omits_exact_lines \
  "current-frame-no-capturedAtUptime" \
  "$FRAME_RECORD" \
  "current FrameRecord does not declare capturedAtUptime" \
  "legacy capturedAtUptime is declared by the current FrameRecord in $FRAME_RECORD; keep legacy DTO fields inside the explicit migrator" \
  "    let capturedAtUptime: TimeInterval" \
  "    var capturedAtUptime: TimeInterval" \
  "    let capturedAtUptime: TimeInterval?" \
  "    var capturedAtUptime: TimeInterval?"

omits_exact_lines \
  "current-frame-no-uptimeAtDelivery" \
  "$FRAME_RECORD" \
  "current FrameRecord does not declare uptimeAtDelivery" \
  "legacy uptimeAtDelivery is declared by the current FrameRecord in $FRAME_RECORD; keep legacy DTO fields inside the explicit migrator" \
  "    let uptimeAtDelivery: TimeInterval" \
  "    var uptimeAtDelivery: TimeInterval" \
  "    let uptimeAtDelivery: TimeInterval?" \
  "    var uptimeAtDelivery: TimeInterval?"

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
contains_exact_line \
  "camera-purpose-string" \
  "$PROJECT" \
  "        NSCameraUsageDescription: \"RAWForge uses the camera to preview your scene and save the RAW captures you choose to make.\"" \
  "project.yml contains the approved Camera purpose string" \
  "project.yml is missing the exact approved NSCameraUsageDescription key/value line in $PROJECT"

contains_exact_line \
  "motion-purpose-string" \
  "$PROJECT" \
  "        NSMotionUsageDescription: \"RAWForge records device motion during a capture so each RAW frame includes evidence of how steadily the phone was held.\"" \
  "project.yml contains the approved Motion purpose string" \
  "project.yml is missing the exact approved NSMotionUsageDescription key/value line in $PROJECT"

PRIVACY_ANSWERS="docs/app-store/privacy-answers.md"
exact_answer_line \
  "privacy-data-not-collected" \
  "$PRIVACY_ANSWERS" \
  "- Data collection:" \
  "- Data collection: **Data Not Collected**" \
  "App Store privacy answers state only Data Not Collected"

exact_answer_line \
  "privacy-tracking-no" \
  "$PRIVACY_ANSWERS" \
  "- Tracking:" \
  "- Tracking: **No**" \
  "App Store privacy answers state only Tracking: No"

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
