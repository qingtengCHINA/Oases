#!/usr/bin/env bash

# Static guard against the interrupted User-Agent helper rename regressing.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

fail() {
    printf 'namespace convergence check failed: %s\n' "$*" >&2
    exit 1
}

canonical="$repo_root/OasesChat/Services/Shared/AppUserAgent.swift"
llm_factory="$repo_root/OasesChat/Services/Providers/LLMProviderFactory.swift"
gemini_provider="$repo_root/OasesChat/Services/Providers/Gemini/GeminiProvider.swift"

[[ -f "$canonical" ]] || fail "missing canonical helper: $canonical"
[[ -f "$llm_factory" ]] || fail "missing LLM provider factory: $llm_factory"
[[ -f "$gemini_provider" ]] || fail "missing Gemini provider: $gemini_provider"

if ! rg --pcre2 -q '^\s*(?:public\s+)?enum\s+AppUserAgent\s*\{' "$canonical"; then
    fail "$canonical must declare enum AppUserAgent"
fi

# These names must not reappear in Swift, including comments and compatibility
# shims. The check intentionally covers every Swift file in the repository.
forbidden_names='\b(?:OasesUserAgent|MinisUserAgent)\b'
if forbidden_matches=$(rg --pcre2 -n --glob '*.swift' "$forbidden_names" "$repo_root" 2>/dev/null); then
    fail "forbidden User-Agent helper name/reference found:
$forbidden_matches"
fi

# A typealias that introduces or targets a UA helper is just as likely to hide
# the duplicate as the old concrete names, so reject those aliases too.
ua_alias_pattern='^\s*(?:(?:public|private|internal|fileprivate)\s+)?typealias\s+\w*(?:UserAgent|UA)\w*\s*=|^\s*(?:(?:public|private|internal|fileprivate)\s+)?typealias\s+\w+\s*=[^\n]*\b(?:UserAgent|UA)\w*\b'
if ua_alias_matches=$(rg --pcre2 -n --glob '*.swift' "$ua_alias_pattern" "$repo_root" 2>/dev/null); then
    fail "UA typealias found; use AppUserAgent directly:
$ua_alias_matches"
fi

llm_count=$(rg --pcre2 -F -c 'AppUserAgent.default' "$llm_factory" || true)
[[ "$llm_count" == 2 ]] || fail "expected 2 AppUserAgent.default references in LLMProviderFactory.swift, found $llm_count"

gemini_count=$(rg --pcre2 -F -c 'AppUserAgent.default' "$gemini_provider" || true)
[[ "$gemini_count" == 1 ]] || fail "expected 1 AppUserAgent.default reference in GeminiProvider.swift, found $gemini_count"

printf 'namespace convergence check passed: AppUserAgent is canonical; live references are LLMProviderFactory.swift=2, GeminiProvider.swift=1.\n'
