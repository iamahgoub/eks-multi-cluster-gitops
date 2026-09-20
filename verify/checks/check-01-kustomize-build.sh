#!/usr/bin/env bash
# verify:number: 1
# verify:name: kustomize build over every kustomization under repos/
# verify:requires-aws: false
# verify:implements: 2.2
#
# Check 1 (design Testing Strategy, Property 7): run `kustomize build` over
# every Kustomize base and overlay directory under repos/. A directory is a
# build root when it holds a kustomization.yaml / kustomization.yml /
# Kustomization file. Each build failure is reported with the file path, the
# resource (the build target), and the observed kustomize error via
# verify_fail. Requirements 10.1, 10.15.
#
# Degrades cleanly: if kustomize is not installed in this environment the
# module reports the situation with verify_info (non-scoring) and exits 0
# rather than crashing or emitting false failures.

source "${VERIFY_LIB:?VERIFY_LIB not set - run via verify/run.sh}"

repo_root="${VERIFY_REPO_ROOT:?VERIFY_REPO_ROOT not set}"
repos_dir="$repo_root/repos"

if [ ! -d "$repos_dir" ]; then
    verify_info "no repos/ directory at $repo_root; nothing to build"
    exit 0
fi

if ! command -v kustomize >/dev/null 2>&1; then
    verify_info "kustomize is not installed in this environment; kustomize build (check 1) skipped. Install kustomize to run this check."
    exit 0
fi

# Per-build wall-clock cap so a pathological build cannot consume the whole
# credential-free budget on its own. The harness still bounds the module as a
# whole.
BUILD_TIMEOUT="${VERIFY_KUSTOMIZE_TIMEOUT:-120}"

# Enumerate every directory that carries a kustomization file. Sort for stable,
# reproducible reporting order. NUL-delimited to tolerate unusual paths.
build_dirs=()
while IFS= read -r -d '' f; do
    build_dirs+=("$(dirname "$f")")
done < <(
    find "$repos_dir" -type f \
        \( -name 'kustomization.yaml' -o -name 'kustomization.yml' -o -name 'Kustomization' \) \
        -print0 | sort -z
)

if [ "${#build_dirs[@]}" -eq 0 ]; then
    verify_info "no kustomization.yaml found under repos/; nothing to build"
    exit 0
fi

built=0
for dir in "${build_dirs[@]}"; do
    rel="${dir#"$repo_root"/}"
    out="$(run_with_timeout "$BUILD_TIMEOUT" kustomize build "$dir" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        verify_pass "kustomize build succeeded" "kustomize build" "$rel"
        built=$((built + 1))
    elif [ "$rc" -eq 124 ]; then
        verify_fail "$rel/kustomization.yaml" "kustomize build" \
            "build did not complete within ${BUILD_TIMEOUT}s"
    else
        verify_fail "$rel/kustomization.yaml" "kustomize build" \
            "$(printf '%s' "$out" | tr -s ' ')"
    fi
done

verify_info "kustomize build ran over ${#build_dirs[@]} kustomization director(ies); ${built} built cleanly"
exit 0
