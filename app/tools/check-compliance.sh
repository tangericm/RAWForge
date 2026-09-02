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
FRAME_SCAN_STATUS=0
FRAME_CURRENT_RELATIVE=0
FRAME_LEGACY_CAPTURED=0
FRAME_LEGACY_DELIVERY=0
ANSWER_SCAN_STATUS=0
ANSWER_SCAN_OUTPUT=""

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

fail_search_error() {
  local label="$1"
  local relative_path="$2"
  fail "$label" "fixed-string search failed for $relative_path (grep exit $SEARCH_STATUS); verify that the file exists, is regular, and is readable"
}

collect_answer_section_bullets() {
  local path="$1"
  local answer_prefix="$2"

  if ANSWER_SCAN_OUTPUT="$(LC_ALL=C awk -v prefix="$answer_prefix" '
    function without_html_comments(line, start, finish, output) {
      output = ""
      while (1) {
        if (html_comment) {
          finish = index(line, "-->")
          if (finish == 0) {
            return output
          }
          line = substr(line, finish + 3)
          html_comment = 0
        } else {
          start = index(line, "<!--")
          if (start == 0) {
            return output line
          }
          output = output substr(line, 1, start - 1)
          line = substr(line, start + 4)
          html_comment = 1
        }
      }
    }

    {
      line = without_html_comments($0)

      if (line ~ /^[[:space:]]*(```|~~~)/) {
        in_fence = !in_fence
        next
      }
      if (in_fence) {
        next
      }

      if (line == "## App Privacy") {
        in_section = 1
        next
      }
      if (in_section && line ~ /^##[[:space:]]+/) {
        in_section = 0
      }

      if (in_section && index(line, prefix) == 1) {
        print line
      }
    }

    END {
      if (html_comment || in_fence) {
        exit 3
      }
    }
  ' "$path" 2>/dev/null)"; then
    ANSWER_SCAN_STATUS=0
  else
    ANSWER_SCAN_STATUS=$?
  fi
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

  collect_answer_section_bullets "$path" "$answer_prefix"
  case "$ANSWER_SCAN_STATUS" in
    0)
      if [ "$ANSWER_SCAN_OUTPUT" = "$expected_line" ]; then
        pass "$label" "$success_message"
      elif [ -z "$ANSWER_SCAN_OUTPUT" ]; then
        fail "$label" "$relative_path must contain the exact unqualified answer line in ## App Privacy: $expected_line"
      else
        fail "$label" "$relative_path contains a contradictory, duplicate, or qualified $answer_prefix bullet in ## App Privacy"
      fi
      ;;
    *)
      fail "$label" "App Privacy answer scan failed for $relative_path (awk exit $ANSWER_SCAN_STATUS); verify that the file exists, is readable, and has complete HTML comments and code fences"
      ;;
  esac
}

scan_frame_record_declarations() {
  local path="$1"
  local scan_output

  if scan_output="$(LC_ALL=C awk '
    {
      line = $0 "\n"
      i = 1
      while (i <= length(line)) {
        c = substr(line, i, 1)
        two = substr(line, i, 2)
        three = substr(line, i, 3)

        if (block_depth > 0) {
          if (two == "/*") {
            block_depth++
            clean = clean "  "
            i += 2
          } else if (two == "*/") {
            block_depth--
            clean = clean "  "
            i += 2
          } else {
            clean = clean (c == "\n" ? "\n" : " ")
            i++
          }
          continue
        }

        if (line_comment) {
          if (c == "\n") {
            line_comment = 0
            clean = clean "\n"
          } else {
            clean = clean " "
          }
          i++
          continue
        }

        if (string_mode == 3) {
          if (three == "\"\"\"") {
            string_mode = 0
            clean = clean "   "
            i += 3
          } else {
            clean = clean (c == "\n" ? "\n" : " ")
            i++
          }
          continue
        }

        if (string_mode == 1) {
          if (c == "\\") {
            clean = clean " "
            if (i < length(line)) {
              clean = clean " "
              i += 2
            } else {
              i++
            }
          } else if (c == "\"") {
            string_mode = 0
            clean = clean " "
            i++
          } else {
            clean = clean (c == "\n" ? "\n" : " ")
            i++
          }
          continue
        }

        if (two == "//") {
          line_comment = 1
          clean = clean "  "
          i += 2
        } else if (two == "/*") {
          block_depth = 1
          clean = clean "  "
          i += 2
        } else if (three == "\"\"\"") {
          string_mode = 3
          clean = clean "   "
          i += 3
        } else if (c == "\"") {
          string_mode = 1
          clean = clean " "
          i++
        } else {
          clean = clean c
          i++
        }
      }
    }

    END {
      if (block_depth > 0 || string_mode > 0) {
        exit 3
      }

      if (!match(clean, /struct[[:space:]]+FrameRecord[[:space:]]*(:[^{]*)?{/)) {
        exit 4
      }

      start = RSTART + RLENGTH - 1
      depth = 0
      top = ""
      for (i = start; i <= length(clean); i++) {
        c = substr(clean, i, 1)
        if (c == "{") {
          depth++
          top = top " "
        } else if (c == "}") {
          if (depth == 1) {
            break
          }
          depth--
          top = top " "
        } else if (depth == 1) {
          top = top c
        } else {
          top = top " "
        }
      }

      if (depth != 1) {
        exit 5
      }

      gsub(/[[:space:]]+/, " ", top)
      current = top ~ /(^|[^[:alnum:]_])let[[:space:]]+capturedAtSegmentStartSeconds[[:space:]]*(:|=)/
      legacy_capture = top ~ /(^|[^[:alnum:]_])(let|var)[[:space:]]+capturedAtUptime[[:space:]]*(:|=)/
      legacy_delivery = top ~ /(^|[^[:alnum:]_])(let|var)[[:space:]]+uptimeAtDelivery[[:space:]]*(:|=)/
      print (current ? 1 : 0), (legacy_capture ? 1 : 0), (legacy_delivery ? 1 : 0)
    }
  ' "$path" 2>/dev/null)"; then
    FRAME_SCAN_STATUS=0
  else
    FRAME_SCAN_STATUS=$?
    return
  fi

  set -- $scan_output
  if [ "$#" -ne 3 ]; then
    FRAME_SCAN_STATUS=6
    return
  fi

  case "$1$2$3" in
    000|001|010|011|100|101|110|111)
      FRAME_CURRENT_RELATIVE="$1"
      FRAME_LEGACY_CAPTURED="$2"
      FRAME_LEGACY_DELIVERY="$3"
      ;;
    *) FRAME_SCAN_STATUS=6 ;;
  esac
}

fail_frame_scan_error() {
  local label="$1"
  local relative_path="$2"
  fail "$label" "Swift declaration scan failed for $relative_path (awk exit $FRAME_SCAN_STATUS); verify that the file exists, is readable, and has complete comments, strings, and braces"
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

check_apache_license() {
  local relative_path="LICENSE"
  local path="$REPO_ROOT/$relative_path"
  local name_status
  local version_status

  run_fixed_search "substring" "Apache License" "$path"
  name_status="$SEARCH_STATUS"
  run_fixed_search "substring" "Version 2.0" "$path"
  version_status="$SEARCH_STATUS"

  if [ "$name_status" -gt 1 ]; then
    SEARCH_STATUS="$name_status"
    fail_search_error "apache-2-license" "$relative_path"
  elif [ "$version_status" -gt 1 ]; then
    SEARCH_STATUS="$version_status"
    fail_search_error "apache-2-license" "$relative_path"
  elif [ "$name_status" -eq 0 ] && [ "$version_status" -eq 0 ]; then
    pass "apache-2-license" "LICENSE contains Apache License, Version 2.0"
  else
    fail "apache-2-license" "LICENSE must contain Apache License and Version 2.0"
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
scan_frame_record_declarations "$REPO_ROOT/$FRAME_RECORD"
if [ "$FRAME_SCAN_STATUS" -ne 0 ]; then
  fail_frame_scan_error "current-frame-relative-time" "$FRAME_RECORD"
  fail_frame_scan_error "current-frame-no-capturedAtUptime" "$FRAME_RECORD"
  fail_frame_scan_error "current-frame-no-uptimeAtDelivery" "$FRAME_RECORD"
else
  if [ "$FRAME_CURRENT_RELATIVE" -eq 1 ]; then
    pass "current-frame-relative-time" "current FrameRecord declares capturedAtSegmentStartSeconds"
  else
    fail "current-frame-relative-time" "current FrameRecord must declare stored let capturedAtSegmentStartSeconds in $FRAME_RECORD"
  fi

  if [ "$FRAME_LEGACY_CAPTURED" -eq 0 ]; then
    pass "current-frame-no-capturedAtUptime" "current FrameRecord does not declare capturedAtUptime"
  else
    fail "current-frame-no-capturedAtUptime" "legacy capturedAtUptime is declared by the current FrameRecord in $FRAME_RECORD; keep legacy DTO fields inside the explicit migrator"
  fi

  if [ "$FRAME_LEGACY_DELIVERY" -eq 0 ]; then
    pass "current-frame-no-uptimeAtDelivery" "current FrameRecord does not declare uptimeAtDelivery"
  else
    fail "current-frame-no-uptimeAtDelivery" "legacy uptimeAtDelivery is declared by the current FrameRecord in $FRAME_RECORD; keep legacy DTO fields inside the explicit migrator"
  fi
fi

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

check_apache_license

printf '\nCompliance assertions: %d passed, %d failed.\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  echo "Compliance check failed; resolve every FAIL line above." >&2
  exit 1
fi

echo "Compliance check passed."
