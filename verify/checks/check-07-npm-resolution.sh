#!/usr/bin/env bash
# verify:number: 7
# verify:name: npm package pins resolve on the npm registry
# verify:requires-aws: false
# verify:implements: 2.3
#
# Check 7 (task 2.3; Requirement 10.7; Property 12).
#
# For every dependency/devDependency in a package.json under repos/ or
# initial-setup/, confirm it resolves on the npm registry as an EXACT version.
# Only an exact semver string (optionally a bare leading '=') is a resolution;
# any range or wildcard - a caret/tilde range, a comparator, an `x`/`*`
# wildcard, `latest`, a hyphen range, or a git/url spec - is reported
# UNRESOLVED. The exact pin is confirmed by GETting
# https://registry.npmjs.org/<name>/<version> through verify_retry, so an
# unreachable registry becomes UNVERIFIED rather than a false UNRESOLVED; a
# definite 404 is UNRESOLVED. Property 12 asks for an exact-STRING match, so the
# pin is confirmed only when the registry's `.version` equals the pinned string
# verbatim (a normalized mismatch, e.g. a stray `v` prefix, is UNRESOLVED).
source "${VERIFY_LIB:?VERIFY_LIB not set - run via verify/run.sh}"

ROOT="${VERIFY_REPO_ROOT:?VERIFY_REPO_ROOT not set - run via verify/run.sh}"

if ! command -v curl >/dev/null 2>&1; then
    verify_info "curl not available; npm resolution skipped"
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    verify_info "jq not available; cannot parse package.json - npm resolution skipped"
    exit 0
fi

files="$(
    for d in "$ROOT/repos" "$ROOT/initial-setup"; do
        [ -d "$d" ] || continue
        find "$d" -type f -name 'package.json' -not -path '*/node_modules/*' 2>/dev/null
    done | sort -u
)"

if [ -z "$files" ]; then
    verify_info "no package.json files found under repos/ or initial-setup/"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s\n' "$files" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$ROOT/}"
    jq -r '((.dependencies // {}) + (.devDependencies // {})) | to_entries[] | "\(.key)\t\(.value)"' "$f" 2>/dev/null \
    | while IFS=$'\t' read -r name spec; do
        [ -n "$name" ] || continue
        if printf '%s' "$spec" | grep -qE '^=?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
            ver="${spec#=}"
            enc="$(printf '%s' "$name" | sed 's#/#%2f#')"
            url="https://registry.npmjs.org/$enc/$ver"
            body="$work/npm.json"
            rm -f "$body"
            if verify_retry -- curl -fsSL -o "$body" "$url"; then
                got="$(jq -r '.version // empty' "$body" 2>/dev/null)"
                if [ "$got" = "$ver" ]; then
                    verify_pass "resolved on the npm registry as an exact version" "$name@$ver" "$rel"
                else
                    verify_unresolved "$rel" "$name@$ver" "npm registry publishes this as '$got'; pin is not the exact version string"
                fi
            elif [ $? -eq "$VERIFY_RC_UNREACHABLE" ]; then
                verify_unverified "$rel" "$name@$spec" "npm registry (unreachable after retries)"
            else
                verify_unresolved "$rel" "$name@$ver" "npm registry ($url) - no such version"
            fi
            rm -f "$body"
        else
            verify_unresolved "$rel" "$name@$spec" "npm registry - not an exact version (range/wildcard/spec)"
        fi
    done
done
exit 0
