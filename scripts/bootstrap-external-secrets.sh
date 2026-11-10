#!/usr/bin/env bash
# The ONE secret a cluster gets by hand: the credential External Secrets Operator uses to read the
# environment's Azure Key Vault. Everything else (DNS credentials, OAuth clients, cookie secrets)
# is a Key Vault secret that ESO syncs into the cluster.
#
#   scripts/bootstrap-external-secrets.sh <env>            e.g. local
#
# Local clusters: the principal sp-eso-<env> and the vault are Terraform in the infra repo
# (infra repo live/<subscription>/<env>/local-cluster). This script reads that unit's
# outputs (`terragrunt output -json`; needs the infra repo's .env or the same env vars) and writes
#   secret external-secrets/azure-kv-sp   keys ClientID, ClientSecret   (ClusterSecretStore azure-kv)
# The secret value never touches either repo. Re-run after Terraform rotates it.
# AKS clusters use workload identity instead and never need this script.
#
#   INFRA_REPO   path to a clone of the infra repo (default: ../Azure-Hub-and-Spoke-Multi-Region-Platform-Example next to this repo)
#   INFRA_UNIT   unit path inside it              (default: live/dev/<env>/local-cluster)
#   KUBECONTEXT  kubectl context                  (default: current)
set -euo pipefail
cd "$(dirname "$0")/.."

env="${1:?usage: bootstrap-external-secrets.sh <env>}"
infra="${INFRA_REPO:-$(cd .. && pwd)/Azure-Hub-and-Spoke-Multi-Region-Platform-Example}"
unit="$infra/${INFRA_UNIT:-live/dev/$env/local-cluster}"
ctx="${KUBECONTEXT:+--context=$KUBECONTEXT}"

[ -d "$unit" ] || { echo "infra unit not found: $unit (set INFRA_REPO / INFRA_UNIT)"; exit 1; }
if [ -z "${TG_STATE_STORAGE_ACCOUNT:-}" ] && [ -f "$infra/.env" ]; then
  # shellcheck disable=SC1091
  set -a; source "$infra/.env"; set +a
fi

echo "== reading Terraform outputs from $unit"
outputs=$(cd "$unit" && TG_NON_INTERACTIVE=true terragrunt output -json 2>/dev/null)
read_out() { printf '%s' "$outputs" | python3 -c 'import sys,json; print(json.load(sys.stdin).get(sys.argv[1],{}).get("value",""))' "$1"; }
client_id=$(read_out eso_client_id); secret=$(read_out eso_client_secret)
vault=$(read_out key_vault_uri); expiry=$(read_out eso_secret_end_date)
[ -n "$client_id" ] && [ -n "$secret" ] || { echo "no ESO principal in the outputs - has the unit been applied?"; exit 1; }
echo "   vault: $vault   clientId: $client_id   secret expires: $expiry"

echo "== secret external-secrets/azure-kv-sp"
kubectl $ctx create namespace external-secrets --dry-run=client -o yaml | kubectl $ctx apply -f - >/dev/null
kubectl $ctx -n external-secrets create secret generic azure-kv-sp \
  --from-literal=ClientID="$client_id" --from-literal=ClientSecret="$secret" \
  --dry-run=client -o yaml | kubectl $ctx apply -f - >/dev/null
echo "   written. ESO picks it up on its next reconcile; check: kubectl get clustersecretstore azure-kv"
