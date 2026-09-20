#!/usr/bin/env bash
# verify:number: 5
# verify:name: container image references resolve via crane manifest
# verify:requires-aws: false
# verify:implements: 2.3
#
# Check 5 (task 2.3; Requirement 10.5; Property 13).
#
# For every container image reference in the domain of Property 13 - the image
# fields of the apps-manifests prod/staging overlays, the kubectl helper image
# in the Crossplane Kubernetes provider config, and add-on auxiliary image
# overrides (e.g. the kubecost auxiliary images) - confirm the reference,
# including its tag or digest, resolves via `crane manifest`. Only references
# that actually carry a tag or digest are resolved; a bare repository has no
# version to resolve and is skipped. Each call goes through verify_retry so an
# unreachable registry becomes UNVERIFIED, never a false UNRESOLVED. Absent
# crane the references are reported via verify_info and the module degrades.
source "${VERIFY_LIB:?VERIFY_LIB not set - run via verify/run.sh}"

ROOT="${VERIFY_REPO_ROOT:?VERIFY_REPO_ROOT not set - run via verify/run.sh}"
REPOS="$ROOT/repos"

have_crane=0
command -v crane >/dev/null 2>&1 && have_crane=1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pairs="$work/pairs"     # file<TAB>ref
: > "$pairs"

# emit_refs <file> : print every image reference declared in <file>.
emit_refs() {
    local f="$1"
    [ -f "$f" ] || return 0
    grep -hoE '(image|fullImageName|repository):[[:space:]]*"?[^"[:space:]]+"?' "$f" 2>/dev/null \
        | sed -E 's/^[A-Za-z]+:[[:space:]]*//; s/"//g'
}

# A reference is versioned when the last path segment has a ':' tag or the whole
# reference carries an '@sha256:' digest.
ref_has_version() {
    local ref="$1" last
    case "$ref" in *"@sha256:"*) return 0 ;; esac
    last="${ref##*/}"
    case "$last" in *:*) return 0 ;; *) return 1 ;; esac
}

registry_of() { printf '%s' "${1%%/*}"; }

add_file_refs() {
    local f="$1" rel ref
    [ -f "$f" ] || return 0
    rel="${f#$ROOT/}"
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        ref_has_version "$ref" || continue
        printf '%s\t%s\n' "$rel" "$ref" >> "$pairs"
    done < <(emit_refs "$f")
}

# Domain 1: apps-manifests prod & staging overlays.
if [ -d "$REPOS/apps-manifests" ]; then
    while IFS= read -r f; do add_file_refs "$f"; done < <(
        find "$REPOS/apps-manifests" -type f \( -name '*.yaml' -o -name '*.yml' \) -path '*overlays*' 2>/dev/null
    )
fi
# Domain 2: the kubectl helper image in the Crossplane k8s provider config.
while IFS= read -r f; do add_file_refs "$f"; done < <(
    grep -rlE 'kubectl' --include='*.yaml' "$REPOS" 2>/dev/null | grep -i 'provider' 
)
# Domain 3: add-on auxiliary image overrides (kubecost et al.).
while IFS= read -r f; do add_file_refs "$f"; done < <(
    grep -rlE 'fullImageName:' --include='*.yaml' "$REPOS" 2>/dev/null
)

# De-duplicate (file,ref) pairs.
sort -u "$pairs" -o "$pairs"

if [ ! -s "$pairs" ]; then
    verify_info "no versioned container image references found in the check-5 domain"
    exit 0
fi

while IFS=$'\t' read -r rel ref; do
    [ -n "$ref" ] || continue
    reg="$(registry_of "$ref")"
    if [ "$have_crane" -eq 0 ]; then
        verify_info "crane unavailable; image not resolved: $ref ($rel, registry $reg)"
        continue
    fi
    if verify_retry -- crane manifest "$ref" >/dev/null 2>&1; then
        verify_pass "image reference resolved via crane" "$ref" "$rel"
    elif [ $? -eq "$VERIFY_RC_UNREACHABLE" ]; then
        verify_unverified "$rel" "$ref" "$reg (registry unreachable after retries)"
    else
        verify_unresolved "$rel" "$ref" "$reg (crane manifest: no such image/tag)"
    fi
done < "$pairs"
exit 0
