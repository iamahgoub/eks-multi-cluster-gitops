#!/usr/bin/env bash
# verify:number: 2
# verify:name: schema validation with kubeconform against cached CRD schemas
# verify:requires-aws: false
# verify:implements: 2.2
#
# Check 2 (design Testing Strategy; Properties 1, 2, 4, 5, 7): validate every
# manifest under repos/ against the schema of its declared API version, using
# kubeconform with --schema-location covering the built-in Kubernetes schemas
# plus a locally cached CRD schema set.
#
# The CRD cache is populated from the pinned artifacts themselves, so a
# manifest declaring a group-version the pinned artifacts do not serve has no
# schema and is surfaced rather than silently passing:
#   - Flux CRDs            <- the pinned gotk-components.yaml (the same file the
#                             Flux resources are validated against)
#   - Karpenter CRDs       <- rendered from the pinned Karpenter chart
#   - Crossplane CRDs      <- extracted from the pinned provider package images
#   - EKSCluster composite <- the repository's own compositeresourcedefinition.yaml
#
# A manifest whose schema cannot be located is reported with
#   verify_unvalidated "<path>" "<declared apiVersion>" "<reason>"
# (reported, non-failing). A manifest that fails validation is reported with
# verify_fail. Requirements 10.1, 10.2, 10.15.
#
# Degrades cleanly: a missing tool (kubeconform, and optionally helm/crane for
# populating the cache) is reported with verify_info rather than crashing, and
# a CRD source that is not yet resolvable in the current tree is noted and its
# resources fall through to unvalidated rather than failing the run.

source "${VERIFY_LIB:?VERIFY_LIB not set - run via verify/run.sh}"

repo_root="${VERIFY_REPO_ROOT:?VERIFY_REPO_ROOT not set}"
repos_dir="$repo_root/repos"

if [ ! -d "$repos_dir" ]; then
    verify_info "no repos/ directory at $repo_root; nothing to validate"
    exit 0
fi

if ! command -v kubeconform >/dev/null 2>&1; then
    verify_info "kubeconform is not installed in this environment; schema validation (check 2) skipped. Install kubeconform to run this check."
    exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
    verify_info "yq is not installed; cannot extract CRD schemas for the cache. Schema validation (check 2) skipped."
    exit 0
fi

# --------------------------------------------------------------------------
# Working directory: CACHE holds the extracted CRD JSON schemas; the two Python
# helpers live alongside it. The helpers are written to files (rather than fed
# via a here-doc) so their stdin stays connected to the piped data.
# --------------------------------------------------------------------------
WORK="$(mktemp -d)"
CACHE="$WORK/cache"
mkdir -p "$CACHE"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# conv.py: read a JSON array (or object) of CRD / XRD definitions on stdin and
# write one JSON schema per (group, kind, version) into
#   $CACHE/<group>/<kind-lower>_<version>.json
# matching the kubeconform template
#   {{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
# Prints the number of schema files written.
cat >"$WORK/conv.py" <<'PY'
import json, os, sys
cache = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
if isinstance(data, dict):
    data = [data]
written = 0
for crd in data or []:
    try:
        spec = crd["spec"]
        group = spec["group"]
        kind = spec["names"]["kind"].lower()
        versions = spec.get("versions") or []
    except (KeyError, TypeError):
        continue
    for v in versions:
        name = v.get("name")
        schema = (v.get("schema") or {}).get("openAPIV3Schema")
        if not name or not schema:
            continue
        d = os.path.join(cache, group)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "%s_%s.json" % (kind, name)), "w") as fh:
            json.dump(schema, fh)
        written += 1
print(written)
PY

# parse.py: read kubeconform JSON on stdin and emit one record per resource that
# needs reporting, as  <status>\x1f<file>\x1f<resource>\x1f<message> .
cat >"$WORK/parse.py" <<'PY'
import json, sys
repo_root = sys.argv[1].rstrip("/") + "/"
FS = "\x1f"
def clean(s):
    return (s or "").replace("\x1f", " ").replace("\n", " ").replace("\t", " ").strip()
try:
    doc = json.load(sys.stdin)
except Exception as e:
    sys.stdout.write(FS.join(["INFO", "", "", "could not parse kubeconform output: %s" % clean(str(e))]) + "\n")
    sys.exit(0)
valid = skipped = invalid = errored = 0
for r in doc.get("resources", []):
    status = r.get("status", "")
    fn = r.get("filename", "")
    if fn.startswith(repo_root):
        fn = fn[len(repo_root):]
    kind = r.get("kind", "")
    name = r.get("name", "")
    ver = r.get("version", "")
    res = ("%s/%s" % (kind, name)).strip("/")
    msg = clean(r.get("msg", ""))
    if status == "statusValid":
        valid += 1
    elif status == "statusSkipped":
        skipped += 1
        sys.stdout.write(FS.join(["UNVALIDATED", clean(fn), clean(ver),
            "no schema located for %s (built-in set and CRD cache)" % clean(ver or "declared apiVersion")]) + "\n")
    elif status == "statusInvalid":
        invalid += 1
        sys.stdout.write(FS.join(["FAIL", clean(fn), clean(res),
            msg or "manifest does not validate against its schema"]) + "\n")
    elif status == "statusError":
        errored += 1
        sys.stdout.write(FS.join(["FAIL", clean(fn), clean(res),
            msg or "kubeconform error validating manifest"]) + "\n")
sys.stdout.write(FS.join(["INFO", "", "",
    "kubeconform: %d valid, %d unvalidated (no schema), %d invalid, %d error"
    % (valid, skipped, invalid, errored)]) + "\n")
PY

# yaml_crds_to_cache <yaml-file-or-"-"> : select CRD/XRD docs from a YAML stream
# and load their schemas into the cache. Prints the number written.
yaml_crds_to_cache() {
    yq ea -o=json \
        '[select(.kind == "CustomResourceDefinition" or .kind == "CompositeResourceDefinition")]' \
        "$1" 2>/dev/null | python3 "$WORK/conv.py" "$CACHE"
}

# --------------------------------------------------------------------------
# Populate the cache from the pinned artifacts.
# --------------------------------------------------------------------------
total_schemas=0

# 1) Flux CRDs from the pinned gotk-components.yaml twins.
for twin in \
    "$repos_dir/gitops-system/clusters/mgmt/flux-system/gotk-components.yaml" \
    "$repos_dir/gitops-system/clusters/template/flux-system/gotk-components.yaml"; do
    if [ -f "$twin" ]; then
        n="$(yaml_crds_to_cache "$twin")"
        total_schemas=$((total_schemas + ${n:-0}))
    fi
done

# 2) EKSCluster composite from the repository's own XRD.
xrd="$repos_dir/gitops-system/tools-config/crossplane-eks-composition/compositeresourcedefinition.yaml"
if [ -f "$xrd" ]; then
    n="$(yaml_crds_to_cache "$xrd")"
    total_schemas=$((total_schemas + ${n:-0}))
fi

# 3) Karpenter CRDs rendered from the pinned chart (needs helm + network).
krelease="$repos_dir/gitops-system/tools/karpenter/karpenter-release.yaml"
krepo="$repos_dir/gitops-system/tools/karpenter/karpenter-repo.yaml"
if [ -f "$krelease" ] && [ -f "$krepo" ]; then
    if command -v helm >/dev/null 2>&1; then
        kver="$(yq e '.spec.chart.spec.version' "$krelease" 2>/dev/null | tr -d "\"' ")"
        kurl="$(yq e '.spec.url' "$krepo" 2>/dev/null | tr -d "\"' ")"
        # HelmRepository url is an OCI registry root; the chart is <url>/karpenter.
        if [ -n "$kver" ] && [ "$kver" != "null" ] && [ -n "$kurl" ] && [ "$kurl" != "null" ]; then
            chart_ref="${kurl%/}/karpenter"
            if crds_out="$(verify_retry -- helm show crds "$chart_ref" --version "$kver" 2>/dev/null)" \
                && [ -n "$crds_out" ]; then
                n="$(printf '%s' "$crds_out" | yaml_crds_to_cache -)"
                total_schemas=$((total_schemas + ${n:-0}))
                verify_info "cached Karpenter CRDs from ${chart_ref} version ${kver} (${n:-0} schema(s))"
            else
                verify_info "could not render Karpenter CRDs from ${chart_ref} version ${kver} (chart unreachable or not yet resolvable); Karpenter resources will be reported unvalidated"
            fi
        else
            verify_info "Karpenter chart version/url not resolvable in current tree; Karpenter resources will be reported unvalidated"
        fi
    else
        verify_info "helm not installed; cannot render Karpenter CRDs. Karpenter resources will be reported unvalidated"
    fi
fi

# 4) Crossplane provider CRDs extracted from the pinned provider package images
#    (needs crane + network). Package refs live in the provider manifests.
crossplane_pkgs=()
while IFS= read -r ref; do
    [ -n "$ref" ] && crossplane_pkgs+=("$ref")
done < <(
    find "$repos_dir/gitops-system/tools/crossplane" -type f -name '*.yaml' -print0 2>/dev/null \
        | xargs -0 yq ea '.spec.package | select(. != null)' 2>/dev/null | tr -d "\"' " | sort -u
)
if [ "${#crossplane_pkgs[@]}" -gt 0 ]; then
    if command -v crane >/dev/null 2>&1; then
        for ref in "${crossplane_pkgs[@]}"; do
            # Crossplane packages are OCI images carrying package.yaml (the CRD
            # set) in their filesystem.
            if pkg_out="$(verify_retry -- crane export "$ref" - 2>/dev/null | tar -xO package.yaml 2>/dev/null)" \
                && [ -n "$pkg_out" ]; then
                n="$(printf '%s' "$pkg_out" | yaml_crds_to_cache -)"
                total_schemas=$((total_schemas + ${n:-0}))
                verify_info "cached Crossplane CRDs from ${ref} (${n:-0} schema(s))"
            else
                verify_info "could not extract CRDs from Crossplane package ${ref} (unreachable or package layout differs); its managed resources will be reported unvalidated"
            fi
        done
    else
        verify_info "crane not installed; cannot extract Crossplane provider CRDs. Crossplane managed resources will be reported unvalidated"
    fi
fi

verify_info "CRD schema cache populated with ${total_schemas} schema(s) from pinned artifacts"

# --------------------------------------------------------------------------
# Enumerate manifests and validate. Kustomize config files (kind Kustomization
# on kustomize.config.k8s.io) are covered by check 1, so they are excluded here
# to avoid noise; Flux Kustomization CRs live in differently-named files and
# are still validated.
# --------------------------------------------------------------------------
files=()
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(
    find "$repos_dir" -type f -name '*.yaml' \
        ! -name 'kustomization.yaml' ! -name 'kustomization.yml' ! -name 'Kustomization' \
        -print0 | sort -z
)

if [ "${#files[@]}" -eq 0 ]; then
    verify_info "no manifests to validate under repos/"
    exit 0
fi

json_out="$(
    kubeconform \
        -ignore-missing-schemas \
        -verbose \
        -output json \
        -schema-location default \
        -schema-location "$CACHE/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
        "${files[@]}" 2>/dev/null
)"

if [ -z "$json_out" ]; then
    verify_info "kubeconform produced no output; nothing validated"
    exit 0
fi

records="$(printf '%s' "$json_out" | python3 "$WORK/parse.py" "$repo_root")"

# Dispatch the parsed records into the harness helpers.
while IFS=$'\037' read -r status file resource message; do
    [ -z "$status" ] && continue
    case "$status" in
        FAIL)        verify_fail        "$file" "$resource" "$message" ;;
        UNVALIDATED) verify_unvalidated "$file" "$resource" "$message" ;;
        INFO)        verify_info        "$message" ;;
    esac
done <<EOF
$records
EOF

exit 0
