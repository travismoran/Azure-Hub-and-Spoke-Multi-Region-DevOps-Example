# Secrets and Azure identity

Rule: **no secret is created by hand on a cluster, except one.** Every Azure identity is Terraform
in the infra repo ([Azure-Hub-and-Spoke-Multi-Region-Platform-Example](https://github.com/travismoran/Azure-Hub-and-Spoke-Multi-Region-Platform-Example)) (pattern: that repo's `docs/identity.md`); every secret a
workload needs is an Azure Key Vault secret that External Secrets Operator (ESO) syncs into a
Kubernetes Secret. This repo only carries identifiers (client ids, tenant, vault URLs).

## The one hand-made secret

`external-secrets/azure-kv-sp` holds the credential ESO uses to read the environment's vault.

| environment | ESO credential | created by | loaded by |
|---|---|---|---|
| `local` (local cluster) | service principal `sp-eso-local`, 24-month client secret | infra `live/dev/local/local-cluster` (also creates `rg-demo-local` + `kv-demo-local`) | `scripts/bootstrap-external-secrets.sh local` |
| `dev`/`stage`/`prod` (AKS) | workload identity `id-external-secrets-<stamp>` (stamp output `external_secrets_client_id`) | infra `modules/aks-spoke` + the vault from `live/<env>/keyvault` | nothing: the `external-secrets` ServiceAccount is annotated in the overlay |

The role is **Key Vault Secrets User** on that one vault. A second local environment is one more
`external_environments` entry in the infra repo plus `environments/<name>/` here.

## What lives in the vault

| Key Vault secret | consumer (Kubernetes Secret) | written by |
|---|---|---|
| `external-dns-azure-json` | `external-dns/azure-config-file` | Terraform (from `live/platform/dns-principals`) |
| `cert-manager-azuredns-client-secret` | `cert-manager/azuredns-sp` | Terraform (same) |
| `oauth2-proxy-cookie-secret` | `gateway/oauth2-proxy` | Terraform (`random_password`) |
| `google-oauth-client-id`, `google-oauth-client-secret` | `gateway/oauth2-proxy`, `argocd/argocd-google-oauth`, `app-a/app-a` (client id only) | **you**, once per environment: `az keyvault secret set --vault-name kv-demo-<env> -n google-oauth-client-id --value ...` |
| `app-a-session-secret` | `app-a/app-a` (`SESSION_SECRET`, signs the app's session cookie; ≥ 32 chars) | **you**, once per environment: `az keyvault secret set --vault-name kv-demo-<env> -n app-a-session-secret --value "$(openssl rand -base64 48)"` |
| `acr-login-server`, `acr-pull-username`, `acr-pull-password` | `app-a/acr-pull`, `app-b/acr-pull` (`kubernetes.io/dockerconfigjson` imagePullSecrets for `crdemolocal.azurecr.io/app-a` and `.../app-b/{api,reporting}`) | Terraform (`modules/local-cluster` `enable_acr`, ADR-026): a read-only, repository-scoped ACR token whose password Terraform rotates; the ExternalSecret templates the three into the docker config |

ExternalSecrets live next to their consumer (`apps/<name>/base/externalsecret.yaml`); the
ClusterSecretStore `azure-kv` and Argo CD's OAuth secret are in `apps/external-secrets-config`.
Refresh interval is one hour; `kubectl annotate externalsecret <name> force-sync=$(date +%s)` forces it.

## DNS: zone-scoped credentials

Each environment may write **only its own zone** `<env>.azure.example.com`. All zones live in
the **connectivity** subscription, resource group `rg-dns-public` (infra `live/platform/dns`; today
`dev`, `prod`, `local` exist, `stage` does not). Roles: **DNS Zone Contributor** on the zone
and **Reader** on `rg-dns-public`, nothing on the subscription.

| environment | principal | created by |
|---|---|---|
| `local` | service principal `sp-dns-local` (24-month secret, reaches the cluster through the vault) | infra `live/platform/dns-principals` |
| AKS | workload identity per component and stamp: `id-external-dns-<stamp>`, `id-cert-manager-<stamp>` (stamp outputs `external_dns_client_id`, `cert_manager_client_id`) | infra `modules/aks-spoke/identity.tf` |

cert-manager solves DNS-01 with those credentials (`ClusterIssuer` per environment, client id in
`environments/<env>/overlays/cert-manager-issuers/solver-patch.yaml`); on AKS it uses
`managedIdentity.clientID`. ExternalDNS publishes every HTTPRoute (and Ingress/Service) hostname with
`--domain-filter=<env>.azure.example.com` and owns records via TXT (`--txt-owner-id=<env>`).

## Web access: Envoy Gateway + Google login

One `Gateway` per cluster (`apps/gateway`, namespace `gateway`, class `eg` from Envoy Gateway) serves
`*.<env>.azure.example.com` with a wildcard Let's Encrypt certificate (DNS-01). Apps attach an
`HTTPRoute`; `:80` redirects to https. A Gateway-wide `SecurityPolicy` sends every request to
oauth2-proxy (`apps/oauth2-proxy`, Google provider, `email_domains = ["example.com"]`): no
session → 302 to Google; session → request continues with `X-Auth-Request-Email` et al. The
oauth2-proxy route `auth.<env>...` carries its own permissive policy so the callback can land.

Apps that authenticate users themselves may opt out with a route-level `SecurityPolicy`
(`authorization.defaultAction: Allow`), which replaces the Gateway-wide policy for that route:
App A does (`apps/app-a/base/securitypolicy.yaml`, Google ID-token sign-in verified in the app,
`ALLOWED_EMAILS` as the access list), so its users sign in once, not twice. The App B ingestion
API does too (`apps/app-b/base/access.yaml`): it is called by an SDK with a bearer JWT, not by a
browser, and verifies that token itself against the public JWKS in its ConfigMap (the private key
never leaves the operator's machine). Everything without its own login (Headlamp, podinfo) stays
behind oauth2-proxy.

The opposite refinement - the Gateway login *plus* a per-route allow-list - is a route-level
`SecurityPolicy` with `mergeType: StrategicMerge` and an `authorization` rule on the
`x-auth-request-email` header that oauth2-proxy sets (Envoy overwrites any client-supplied copy
of that header with its own). pgAdmin uses it (`apps/app-a/base/pgadmin-access.yaml`): every
example.com account passes the login, only the listed ones get past the 403. pgAdmin then
trusts the same header for its identity ("webserver" authentication), accepted only from the
environment's pod CIDR and only for the one pre-created user, and connects to `app-a-db` with a
pgpass file built from the CloudNativePG app secret at start-up; it stores no credentials.
The App B dashboard route uses the same allow-list pattern.

Argo CD additionally signs users in through Dex's Google connector (`hostedDomains: example.com`)
with the same OAuth client; `admin@example.com` is `role:platform-admin`, everyone else in the
domain read-only (`core/argocd/argocd-rbac-cm.yaml`).

### Creating the Google OAuth client (once per environment)

1. Google Cloud console → APIs & Services → OAuth consent screen: **Internal** (Workspace users only).
2. Credentials → Create credentials → OAuth client ID → **Web application**, name `platform-<env>`.
3. Authorised redirect URIs:
   * `https://auth.<env>.azure.example.com/oauth2/callback`
   * `https://argocd.<env>.azure.example.com/api/dex/callback`
   * `https://app-a.<env>.azure.example.com/api/v1/auth/google` (App A' own sign-in posts
     Google's ID token here)

   Authorised JavaScript origins: `https://app-a.<env>.azure.example.com` (Google Identity
   Services renders the sign-in button on that page).
4. Store it (the vault is in the environment's subscription):
   ```bash
   az keyvault secret set --vault-name kv-demo-<env> -n google-oauth-client-id     --value '<client id>'
   az keyvault secret set --vault-name kv-demo-<env> -n google-oauth-client-secret --value '<client secret>'
   ```
   ESO syncs within the hour (or force-sync the two ExternalSecrets).

## Local cluster networking (Rancher Desktop)

Traefik is disabled (`rdctl set --kubernetes.options.traefik=false`); Envoy's LoadBalancer Service
takes ports 80/443 and Rancher Desktop's `host-switch` forwards them from every Windows interface.
The internal LoadBalancer IP is unreachable from Windows, so ExternalDNS publishes the Windows LAN
address instead (`--default-targets` in `environments/local/overlays/external-dns`).
