#!/usr/bin/env bash

# Verify the privacy manifest of every target against the expectation below:
# the required-reason API categories and reasons, and the collected data types
# and tracking declarations (the main app declares the QingTeng account's User ID
# and payout address since f47712e; extensions declare none). Any other
# top-level key is rejected, so a change to a manifest has to update this file.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

fail() {
    printf 'privacy manifest verification failed: %s\n' "$*" >&2
    exit 1
}

command -v plutil >/dev/null 2>&1 || fail "plutil is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v rg >/dev/null 2>&1 || fail "rg is required"

verify_manifest() {
    local manifest=$1
    local target=$2
    local expected_json=$3

    [[ -f "$manifest" ]] || fail "$target: missing $manifest"
    plutil -lint "$manifest" >/dev/null || fail "$target: plutil -lint failed for $manifest"

    if ! python3 - "$manifest" "$expected_json" "$target" <<'PY'
import json
import plistlib
import sys

path, expected_json, target = sys.argv[1:]

try:
    with open(path, "rb") as stream:
        actual = plistlib.load(stream)
    expected = json.loads(expected_json)
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    print(f"{target}: cannot parse {path}: {error}", file=sys.stderr)
    raise SystemExit(1)

ALLOWED_TOP_LEVEL = {
    "NSPrivacyAccessedAPITypes",
    "NSPrivacyCollectedDataTypes",
    "NSPrivacyTracking",
    "NSPrivacyTrackingDomains",
}


def canonical_apis(entries):
    if not isinstance(entries, list):
        raise ValueError("NSPrivacyAccessedAPITypes must be an array")
    normalized = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise ValueError(f"API entry {index} must be a dictionary")
        required_keys = {
            "NSPrivacyAccessedAPIType",
            "NSPrivacyAccessedAPITypeReasons",
        }
        if set(entry) != required_keys:
            raise ValueError(
                f"API entry {index} has unexpected keys: {sorted(entry)}"
            )
        api_type = entry["NSPrivacyAccessedAPIType"]
        reasons = entry["NSPrivacyAccessedAPITypeReasons"]
        if not isinstance(api_type, str):
            raise ValueError(f"API entry {index} type must be a string")
        if not isinstance(reasons, list) or not all(
            isinstance(reason, str) for reason in reasons
        ):
            raise ValueError(f"API entry {index} reasons must be an array of strings")
        normalized.append(
            {
                "NSPrivacyAccessedAPIType": api_type,
                "NSPrivacyAccessedAPITypeReasons": sorted(reasons),
            }
        )
    normalized.sort(key=lambda entry: entry["NSPrivacyAccessedAPIType"])
    return normalized


def canonical_collected(entries):
    if not isinstance(entries, list):
        raise ValueError("NSPrivacyCollectedDataTypes must be an array")
    normalized = []
    for index, entry in enumerate(entries):
        required_keys = {
            "NSPrivacyCollectedDataType",
            "NSPrivacyCollectedDataTypeLinked",
            "NSPrivacyCollectedDataTypeTracking",
            "NSPrivacyCollectedDataTypePurposes",
        }
        if not isinstance(entry, dict) or set(entry) != required_keys:
            raise ValueError(
                f"collected data entry {index} must have exactly {sorted(required_keys)}"
            )
        purposes = entry["NSPrivacyCollectedDataTypePurposes"]
        if not isinstance(purposes, list) or not all(isinstance(p, str) for p in purposes):
            raise ValueError(f"collected data entry {index} purposes must be an array of strings")
        if not isinstance(entry["NSPrivacyCollectedDataTypeLinked"], bool) or not isinstance(
            entry["NSPrivacyCollectedDataTypeTracking"], bool
        ):
            raise ValueError(f"collected data entry {index} linked/tracking must be booleans")
        normalized.append(
            {
                "NSPrivacyCollectedDataType": entry["NSPrivacyCollectedDataType"],
                "NSPrivacyCollectedDataTypeLinked": entry["NSPrivacyCollectedDataTypeLinked"],
                "NSPrivacyCollectedDataTypeTracking": entry["NSPrivacyCollectedDataTypeTracking"],
                "NSPrivacyCollectedDataTypePurposes": sorted(purposes),
            }
        )
    normalized.sort(key=lambda entry: entry["NSPrivacyCollectedDataType"])
    return normalized


def canonical(value, label):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a dictionary")
    unexpected = set(value) - ALLOWED_TOP_LEVEL
    if unexpected:
        raise ValueError(f"{label} has unexpected top-level keys: {sorted(unexpected)}")
    if "NSPrivacyAccessedAPITypes" not in value:
        raise ValueError(f"{label} has no NSPrivacyAccessedAPITypes")
    tracking = value.get("NSPrivacyTracking", False)
    domains = value.get("NSPrivacyTrackingDomains", [])
    if not isinstance(tracking, bool):
        raise ValueError("NSPrivacyTracking must be a boolean")
    if not isinstance(domains, list) or not all(isinstance(d, str) for d in domains):
        raise ValueError("NSPrivacyTrackingDomains must be an array of strings")
    return {
        "NSPrivacyAccessedAPITypes": canonical_apis(value["NSPrivacyAccessedAPITypes"]),
        "NSPrivacyCollectedDataTypes": canonical_collected(value.get("NSPrivacyCollectedDataTypes", [])),
        "NSPrivacyTracking": tracking,
        "NSPrivacyTrackingDomains": sorted(domains),
    }

try:
    actual_canonical = canonical(actual, target)
    expected_canonical = canonical(expected, "verifier expectation")
except ValueError as error:
    print(f"{target}: {error}", file=sys.stderr)
    raise SystemExit(1)

if actual_canonical != expected_canonical:
    print(
        f"{target}: declarations do not match the expected categories/reasons",
        file=sys.stderr,
    )
    print(f"  expected: {json.dumps(expected_canonical, sort_keys=True)}", file=sys.stderr)
    print(f"  actual:   {json.dumps(actual_canonical, sort_keys=True)}", file=sys.stderr)
    raise SystemExit(1)

print(f"privacy manifest verified: {target} ({path})")
PY
    then
        fail "$target: declaration check failed"
    fi
}

verify_manifest \
    "$repo_root/OasesChat/Resources/PrivacyInfo.xcprivacy" \
    "main app" \
    '{"NSPrivacyTracking":false,"NSPrivacyTrackingDomains":[],"NSPrivacyCollectedDataTypes":[{"NSPrivacyCollectedDataType":"NSPrivacyCollectedDataTypeUserID","NSPrivacyCollectedDataTypeLinked":true,"NSPrivacyCollectedDataTypeTracking":false,"NSPrivacyCollectedDataTypePurposes":["NSPrivacyCollectedDataTypePurposeAppFunctionality"]},{"NSPrivacyCollectedDataType":"NSPrivacyCollectedDataTypeOtherFinancialInfo","NSPrivacyCollectedDataTypeLinked":true,"NSPrivacyCollectedDataTypeTracking":false,"NSPrivacyCollectedDataTypePurposes":["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}],"NSPrivacyAccessedAPITypes":[{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryUserDefaults","NSPrivacyAccessedAPITypeReasons":["CA92.1","1C8F.1"]},{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryFileTimestamp","NSPrivacyAccessedAPITypeReasons":["C617.1","3B52.1"]},{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryDiskSpace","NSPrivacyAccessedAPITypeReasons":["E174.1"]},{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategorySystemBootTime","NSPrivacyAccessedAPITypeReasons":["35F9.1"]}]}'

verify_manifest \
    "$repo_root/Extensions/FileProvider/PrivacyInfo.xcprivacy" \
    "File Provider extension" \
    '{"NSPrivacyAccessedAPITypes":[{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryUserDefaults","NSPrivacyAccessedAPITypeReasons":["1C8F.1"]},{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryFileTimestamp","NSPrivacyAccessedAPITypeReasons":["C617.1"]}]}'

verify_manifest \
    "$repo_root/Extensions/ShareExtension/PrivacyInfo.xcprivacy" \
    "Share extension" \
    '{"NSPrivacyAccessedAPITypes":[{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryUserDefaults","NSPrivacyAccessedAPITypeReasons":["1C8F.1"]}]}'

verify_manifest \
    "$repo_root/Extensions/AgentWidget/PrivacyInfo.xcprivacy" \
    "Widget extension" \
    '{"NSPrivacyAccessedAPITypes":[{"NSPrivacyAccessedAPIType":"NSPrivacyAccessedAPICategoryUserDefaults","NSPrivacyAccessedAPITypeReasons":["1C8F.1"]}]}'

# Source-scope check, per target: every required-reason API category the
# target's sources reference must be declared in that target's manifest.
# Extensions compile a few host-app files, so those count toward the
# extension. Keep these scopes in sync with `targets.<name>.sources` in
# project.yml.
category_patterns=(
    'NSPrivacyAccessedAPICategoryUserDefaults=\b(?:UserDefaults|NSUserDefaults)\b|@AppStorage'
    'NSPrivacyAccessedAPICategoryFileTimestamp=\b(?:creationDate|modificationDate|contentModificationDate|fileModificationDate|attributesOfItem|getattrlist)\b'
    'NSPrivacyAccessedAPICategoryDiskSpace=\b(?:volumeAvailableCapacity\w*|systemFreeSize|systemSize|statfs|statvfs)\b'
    'NSPrivacyAccessedAPICategorySystemBootTime=\b(?:systemUptime|mach_absolute_time)\b|kern\.boottime'
)

check_scope() {
    local target=$1
    local manifest=$2
    shift 2
    local declared
    declared=$(python3 -c 'import plistlib,sys; print("\n".join(e["NSPrivacyAccessedAPIType"] for e in plistlib.load(open(sys.argv[1],"rb")).get("NSPrivacyAccessedAPITypes",[])))' "$manifest")
    local entry category pattern hits
    for entry in "${category_patterns[@]}"; do
        category=${entry%%=*}
        pattern=${entry#*=}
        hits=$(rg --pcre2 -n --glob '*.swift' --glob '*.m' --glob '*.c' "$pattern" "$@" 2>/dev/null || true)
        if [[ -n "$hits" ]] && ! grep -qx "$category" <<<"$declared"; then
            fail "$target: sources use $category but $manifest does not declare it:
$hits"
        fi
    done
    printf 'privacy manifest scope verified: %s\n' "$target"
}

check_scope "main app" "$repo_root/OasesChat/Resources/PrivacyInfo.xcprivacy" \
    "$repo_root/OasesChat" "$repo_root/vendor/iSH"
check_scope "File Provider extension" "$repo_root/Extensions/FileProvider/PrivacyInfo.xcprivacy" \
    "$repo_root/Extensions/FileProvider" \
    "$repo_root/OasesChat/Services/Shared/AppGroup.swift" \
    "$repo_root/OasesChat/Services/FileProvider/SharedFolderVisibility.swift"
check_scope "Share extension" "$repo_root/Extensions/ShareExtension/PrivacyInfo.xcprivacy" \
    "$repo_root/Extensions/ShareExtension" \
    "$repo_root/OasesChat/Services/Shared/AppGroup.swift" \
    "$repo_root/OasesChat/Services/Shared/SharedContainerStore.swift" \
    "$repo_root/OasesChat/Services/Shared/PendingShare.swift"
check_scope "Widget extension" "$repo_root/Extensions/AgentWidget/PrivacyInfo.xcprivacy" \
    "$repo_root/Extensions/AgentWidget" \
    "$repo_root/OasesChat/Services/Agent/Background/AgentActivityAttributes.swift" \
    "$repo_root/OasesChat/Services/Shared/AudioTogglePlaybackIntent.swift"

printf 'privacy manifest verification passed: 4 manifests, source scopes checked per target.\n'
