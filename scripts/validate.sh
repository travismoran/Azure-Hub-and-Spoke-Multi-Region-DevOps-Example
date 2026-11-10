#!/usr/bin/env bash
# Offline validation: render every kustomization and check it against Kubernetes + CRD schemas.
# Usage: scripts/validate.sh            # all environments
#        scripts/validate.sh dev        # one environment
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_VERSION="${KUBE_VERSION:-1.34.0}"
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
OUT="${OUT_DIR:-$(mktemp -d)}"

# kustomize `helmCharts` needs Helm 3 (Argo CD bundles Helm 3; Helm 4 removed flags kustomize calls).
# Prefer a standalone kustomize and a `helm3` binary when present, else fall back to kubectl's.
KUSTOMIZE="${KUSTOMIZE:-$(command -v kustomize || echo 'kubectl kustomize')}"
HELM_BIN="${HELM_BIN:-$(command -v helm3 || command -v helm)}"

# OCI charts (Envoy Gateway) are public, but helm still consults Docker's credential helpers and
# fails if one is broken (Rancher Desktop ships helpers that need Windows or libsecret). Point it
# at an empty Docker config and keep Rancher Desktop's helper directory off PATH while rendering.
EMPTY_DOCKER_CONFIG="$(mktemp -d)"; echo '{}' > "$EMPTY_DOCKER_CONFIG/config.json"
export DOCKER_CONFIG="$EMPTY_DOCKER_CONFIG"
PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'Rancher Desktop' | paste -sd:)"; export PATH

envs=("$@")
[ ${#envs[@]} -eq 0 ] && envs=(local dev stage prod)

render() { # <kustomization dir> <output file>
  $KUSTOMIZE build --enable-helm --helm-command "$HELM_BIN" "$1" > "$2"
}

check() { # <rendered file> <label>
  kubeconform -strict -summary \
    -kubernetes-version "$KUBE_VERSION" \
    -schema-location default \
    -schema-location "$CRD_CATALOG" \
    -ignore-missing-schemas \
    "$1" | sed "s/^/  [$2] /"
}

fail=0
for env in "${envs[@]}"; do
  echo "== $env"
  for dir in environments/$env/argocd-install environments/$env/apps environments/$env/overlays/*; do
    name="$env-$(basename "$dir")"
    if render "$dir" "$OUT/$name.yaml"; then
      check "$OUT/$name.yaml" "$name" || fail=1
    else
      echo "  [$name] kustomize build FAILED"; fail=1
    fi
  done
  cp environments/$env/root-app.yaml "$OUT/$env-root-app.yaml"
  check "$OUT/$env-root-app.yaml" "$env-root-app" || fail=1
done

echo
if [ $fail -eq 0 ]; then echo "OK: all manifests render and validate (rendered output in $OUT)"; else echo "FAILED"; exit 1; fi
