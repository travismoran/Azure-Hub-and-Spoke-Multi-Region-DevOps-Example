# Azure Hub-and-Spoke Multi-Region DevOps Example

GitOps monorepo for Kubernetes clusters, reconciled by [Argo CD](https://argo-cd.readthedocs.io/).
One Argo CD per cluster, one environment root per cluster, shared blueprints for everything
that runs on them.

This is the GitOps (cluster-side) half of a pair. The Azure side (hub-and-spoke networking, AKS
stamps, Key Vaults, DNS zones, every identity referenced here) is Terraform/Terragrunt in the
companion repo
[Azure-Hub-and-Spoke-Multi-Region-Platform-Example](https://github.com/travismoran/Azure-Hub-and-Spoke-Multi-Region-Platform-Example),
referred to below as "the infra repo".

> **Everything account-specific is a placeholder.** Before bootstrapping, replace:
> `example.com` / `azure.example.com` (your DNS parent zone), `your-org/Azure-Hub-and-Spoke-Multi-Region-DevOps-Example`
> (your fork, in `environments/*/root-app.yaml`, `environments/*/apps/*.yaml`, `core/argocd/projects.yaml`,
> `scripts/bootstrap.sh`), `REPLACE_WITH_TENANT_ID`, `REPLACE_WITH_CONNECTIVITY_SUBSCRIPTION_ID`,
> `REPLACE_WITH_CLIENT_ID_OF_*` (Terraform outputs from the infra repo), `kv-demo-<env>` / `crdemolocal`
> (your vault and registry names), `admin@example.com` (your admin account) and `192.168.1.100`
> (the local host's LAN address). `app-a` and `app-b` are sample workloads showing the patterns
> (CloudNativePG database, private ACR images, own-login vs. Gateway-login routes, allow-lists);
> their images do not exist publicly, so drop them from `environments/local/apps/` or point them at your own.

## Layout

```
Azure-Hub-and-Spoke-Multi-Region-DevOps-Example/
├── core/
│   └── argocd/                  # Argo CD base: pinned upstream install + global config + AppProjects
├── apps/                        # Shared blueprints (no environment specifics)
│   ├── podinfo/base/            #   plain Kustomize manifests
│   ├── headlamp/base/           #   Headlamp (Kubernetes UI) Helm chart behind the Gateway login
│   ├── cloudnative-pg/base/     #   CloudNativePG operator (PostgreSQL for the apps that declare a Cluster)
│   ├── app-a/base/             #   sample app with its own Google sign-in + pgAdmin: CloudNativePG Postgres, image from the environment's ACR
│   ├── app-b/base/          #   sample API (own bearer-token auth) + dashboard, CloudNativePG
│   ├── cert-manager/base/       #   Helm chart rendered via kustomize `helmCharts`
│   ├── cert-manager-issuers/    #   Let's Encrypt ClusterIssuers (DNS-01 on Azure DNS)
│   └── external-dns/base/       #   ExternalDNS Helm chart, Azure DNS provider
├── environments/
│   ├── dev/
│   │   ├── argocd-install/      # core/argocd + dev config (url, insecure, SSO...)
│   │   ├── root-app.yaml        # dev root App-of-Apps -> environments/dev/apps
│   │   ├── apps/                # one Argo CD Application per component (the inventory)
│   │   └── overlays/<app>/      # dev-specific Kustomize overlay of apps/<app>/base
│   ├── local/            # same shape + Argo CD ingress; the Rancher Desktop cluster
│   ├── stage/                   # same shape
│   └── prod/                    # same shape
├── scripts/
│   ├── bootstrap.sh             # one-time: install Argo CD, register repo, apply root app
│   ├── bootstrap-external-secrets.sh  # the one hand-made secret: ESO's Key Vault credential (local clusters)
│   └── validate.sh              # offline: render every kustomization + kubeconform
├── docs/secrets-and-identity.md # Key Vault + ESO, DNS credentials, Envoy Gateway + Google login
└── .github/workflows/validate.yaml
```

Each environment is an independent root. Nothing under `environments/prod` references
`environments/stage`; they only share `core/` and `apps/`. A change to a blueprint is
promoted by bumping it in each environment's overlay, so dev, stage and prod can pin
different versions of the same blueprint at the same time.

## How reconciliation flows

```
bootstrap.sh ──► environments/<env>/argocd-install   (kubectl apply, once)
             └─► environments/<env>/root-app.yaml    (kubectl apply, once)
                       │
                       ▼  Application "root" (project: platform)
                 environments/<env>/apps/*.yaml
                       │
      ┌────────────┬──────────┼───────────────┬──────────────┐
      ▼            ▼          ▼               ▼              ▼
 argocd (-10)  cert-manager  external-dns  cert-manager-   podinfo, headlamp, app-a, app-b (10)
 self-managed  (0)           (1)           issuers (1)     workloads + UI
```

* **Argo CD manages itself.** After bootstrap, `environments/<env>/argocd-install` is synced
  by the `argocd` Application, so config changes and version bumps are plain Git commits.
* **Sync waves** order platform pieces before workloads. `core/argocd/argocd-cm.yaml` adds a
  health check for `Application` resources so the root app reports child health.
* **AppProjects** (`core/argocd/projects.yaml`): `platform` may create cluster-scoped resources;
  `workloads` is limited to namespaced resources plus its own Namespace.
* **Helm** blueprints render through kustomize `helmCharts` (enabled by
  `kustomize.buildOptions: --enable-helm`), so every path in the repo is a kustomization and
  environments patch the rendered output the same way they patch plain manifests.

## Bootstrapping a cluster

If your fork is private, Argo CD needs a read-only deploy key (for a public fork, switch the
`repoURL`s to `https://github.com/<you>/<repo>.git` and skip the key).

```bash
# 1. create a deploy key for this cluster and add the public half to the GitHub repo (read-only)
ssh-keygen -t ed25519 -N '' -C "argocd-dev" -f ~/.ssh/argocd-dev
gh repo deploy-key add ~/.ssh/argocd-dev.pub --repo your-org/Azure-Hub-and-Spoke-Multi-Region-DevOps-Example --title argocd-dev

# 2. install Argo CD, register the repo, apply the root app
KUBECONTEXT=my-dev-cluster scripts/bootstrap.sh dev ~/.ssh/argocd-dev

# 4. log in
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:80     # or http://argocd.local.azure.example.com once DNS resolves
```

Re-running `bootstrap.sh` is safe; it is a server-side apply of what Argo CD already manages.

## Day-to-day

**Validate before pushing** (CI runs the same script on every PR):

```bash
scripts/validate.sh          # all environments
scripts/validate.sh prod     # one environment
```

Needs `kustomize`, a Helm 3 binary (`helm3` or `helm`) and `kubeconform` on `PATH`. Helm 4
is not compatible with kustomize's `helmCharts` yet, which is why the script looks for `helm3` first.

**Add a blueprint**

1. `apps/<name>/base/kustomization.yaml` (plain manifests, or `helmCharts` + `values.yaml`).
2. For each environment that should run it: `environments/<env>/overlays/<name>/kustomization.yaml`
   referencing `../../../../apps/<name>/base`, plus `environments/<env>/apps/<name>.yaml`
   (copy an existing Application, set `path`, `project`, `sync-wave`, destination namespace)
   and list it in `environments/<env>/apps/kustomization.yaml`.
3. Commit. The root app picks up the new Application; no `kubectl` needed.

**Promote a change** by editing the overlay (or bumping the pinned chart/image in the base and
letting each environment's overlay opt in). Merge to `main` is the deployment.

**Add an environment**: copy `environments/local` (or `dev` for a cloud cluster), change
the zone in the hostnames and the replicas, create the GitHub environment, then run
`scripts/bootstrap.sh <env> <deploy-key>` against the new cluster.

**Upgrade Argo CD**: bump the tag in `core/argocd/kustomization.yaml`. Every environment's
`argocd` Application rolls the upgrade out on its next sync (server-side apply handles the CRDs).

## Environments and DNS

Every environment owns a DNS zone under `azure.example.com`, and host records for that
cluster live in its zone (zones and delegations are managed outside this repo):

| environment    | zone                                   | cluster                       |
|----------------|----------------------------------------|-------------------------------|
| `local`        | `local.azure.example.com`          | Rancher Desktop (local k3s)   |
| `dev`          | `dev.azure.example.com`            | cloud dev (not yet created)   |
| `stage`        | `stage.azure.example.com`          | cloud stage (not yet created) |
| `prod`         | `prod.azure.example.com`           | cloud prod (not yet created)  |

ExternalDNS publishes every Ingress host into the environment's zone and cert-manager issues
Let's Encrypt certificates for it via DNS-01; each environment's credentials can write only its
own zone. Every Azure identity is Terraform in the infra repo ([Azure-Hub-and-Spoke-Multi-Region-Platform-Example](https://github.com/travismoran/Azure-Hub-and-Spoke-Multi-Region-Platform-Example)) and every
secret reaches the cluster from Azure Key Vault through External Secrets Operator; see
[docs/secrets-and-identity.md](docs/secrets-and-identity.md). Web frontends sit behind one Envoy
Gateway per cluster with Google login restricted to `example.com` (oauth2-proxy), and Argo CD
signs in through the same Google client via Dex.

Hostnames follow `<service>.<environment>.azure.example.com`, e.g.
`argocd.local.azure.example.com`, `headlamp.local.azure.example.com` (Kubernetes
UI; everyone who passes the Google login acts as Headlamp's cluster-admin service account, see
`apps/headlamp/base/values.yaml`), `app-a.local.azure.example.com` (sample app A,
image from the environment's Azure Container Registry pushed by its repo's GitHub
Actions through OIDC, PostgreSQL from a CloudNativePG `Cluster` in its namespace; it does its own
Google sign-in and is exempt from the Gateway login), `pgadmin.local.azure.example.com`
(pgAdmin for the App A database: Gateway login plus an account allow-list, see
`docs/secrets-and-identity.md`), `app-b.local.azure.example.com` (sample app B:
`/v1/telemetry` is an ingestion API with its own bearer-token auth, exempt from the
Gateway login; the rest is the dashboard behind the Gateway login plus an allow-list) and
`podinfo.local.azure.example.com`.
Each environment also has a matching GitHub environment of the same name on this repo,
restricted to deployments from `main`, for environment-scoped variables and future OIDC.
Additional local environments follow the same pattern: add `environments/<name>/`, a
`<name>.azure.example.com` zone, and a GitHub environment `<name>`.

## Conventions

* `main` is the only deployed branch; all three environments track it. Use branch protection
  and the validate workflow as the gate.
* Pin everything: Argo CD tag, chart versions, image tags. No `latest`.
* No secrets in Git. Repo credentials are created out-of-band by `bootstrap.sh`; application
  secrets should come from an operator such as External Secrets or Sealed Secrets added as a
  blueprint under `apps/`.
* Hostnames are set per environment in `environments/<env>/argocd-install/argocd-cm.yaml`
  and `environments/<env>/overlays/podinfo/ingress-patch.yaml`.
* Automated sync with `prune` and `selfHeal` is on everywhere. If prod should require a manual
  gate, remove `syncPolicy.automated` from the prod Application files.
