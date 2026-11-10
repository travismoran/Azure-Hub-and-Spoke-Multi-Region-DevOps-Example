#!/usr/bin/env bash
# One-time bootstrap of an environment's cluster:
#   1. install Argo CD from environments/<env>/argocd-install
#   2. register the Git repo (SSH deploy key) so Argo CD can read a private fork (optional for a public one)
#   3. apply the root App-of-Apps; everything else flows from Git
#
# Usage: scripts/bootstrap.sh <env> [path-to-deploy-private-key]
# Env:   KUBECONTEXT (optional) kube context to target
set -euo pipefail
cd "$(dirname "$0")/.."

env="${1:?usage: bootstrap.sh <env> [deploy-key]}"
key="${2:-}"
ctx="${KUBECONTEXT:+--context=$KUBECONTEXT}"
repo='git@github.com:your-org/Azure-Hub-and-Spoke-Multi-Region-DevOps-Example.git'

[ -d "environments/$env" ] || { echo "unknown environment: $env"; exit 1; }

echo "== [$env] installing Argo CD"
# First pass may fail on AppProjects because the CRDs are not established yet; the second pass fixes that.
kubectl $ctx apply --server-side --force-conflicts -k "environments/$env/argocd-install" || true
kubectl $ctx wait --for=condition=established --timeout=120s \
  crd/applications.argoproj.io crd/appprojects.argoproj.io crd/applicationsets.argoproj.io
kubectl $ctx apply --server-side --force-conflicts -k "environments/$env/argocd-install"

echo "== [$env] waiting for Argo CD"
kubectl $ctx -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl $ctx -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl $ctx -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

if [ -n "$key" ]; then
  echo "== [$env] registering repo credentials"
  kubectl $ctx -n argocd create secret generic repo-gitops \
    --from-literal=type=git \
    --from-literal=url="$repo" \
    --from-file=sshPrivateKey="$key" \
    --dry-run=client -o yaml \
    | kubectl $ctx label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kubectl $ctx apply -f -
else
  echo "== [$env] no deploy key given; assuming repo credentials already exist"
fi

echo "== [$env] applying root app"
kubectl $ctx apply -f "environments/$env/root-app.yaml"

echo
echo "Done. Initial admin password:"
echo "  kubectl $ctx -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "UI (dev / insecure): kubectl $ctx -n argocd port-forward svc/argocd-server 8080:80"
