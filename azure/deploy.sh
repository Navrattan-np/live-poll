#!/usr/bin/env bash
# One-shot Azure deploy for LivePoll (Azure Container Apps, student-subscription friendly).
#
#   ./azure/deploy.sh                # deploy everything
#   LOCATION=westeurope ./azure/deploy.sh
#   ./azure/deploy.sh github-oidc    # set up GitHub Actions OIDC (after the first deploy)
#
# Prerequisites: Azure CLI (Cloud Shell has it preinstalled) and an active login
# on your Azure for Students subscription.
set -euo pipefail

cd "$(dirname "$0")/.."

RG="${RESOURCE_GROUP:-rg-livepoll}"
LOCATION="${LOCATION:-eastus}"
BASE="${BASE_NAME:-livepoll}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
DEPLOY_NAME="livepoll-infra"
KEYFILE="azure/.hostkey"

if ! az account show --query id -o tsv >/dev/null 2>&1; then
  echo "Not logged in to Azure. Run: az login   (or use Azure Cloud Shell)" >&2
  exit 1
fi

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "Subscription: $SUB_NAME ($SUB_ID)"
az account set --subscription "$SUB_ID"

# Reuse the host key across re-runs so the /host password stays stable.
if [[ -z "${HOST_KEY:-}" ]]; then
  if [[ -f "$KEYFILE" ]]; then
    HOST_KEY=$(cat "$KEYFILE")
  else
    HOST_KEY=$(openssl rand -hex 16)
    printf '%s' "$HOST_KEY" > "$KEYFILE"
    chmod 600 "$KEYFILE"
  fi
fi

get_output() { # get_output <deployment> <name>
  az deployment group show -g "$RG" -n "$1" --query "properties.outputs.$2.value" -o tsv
}

deploy() { # deploy <name> <extra params...>
  local name="$1"; shift
  az deployment group create --resource-group "$RG" --name "$name" \
    --template-file azure/main.bicep \
    --parameters baseName="$BASE" hostKey="$HOST_KEY" "$@" \
    --output none
}

if [[ "${1:-}" == "github-oidc" ]]; then
  # Creates an app registration + federated credential for GitHub Actions OIDC
  # (no client secrets). Requires GH_REPO like "yourname/live-poll".
  : "${GH_REPO:?Set GH_REPO=owner/repo, e.g. GH_REPO=nitin/live-poll ./azure/deploy.sh github-oidc}"
  APP_ID=$(az ad app create --display-name "livepoll-gha" --query appId -o tsv)
  az ad sp create --id "$APP_ID" >/dev/null
  SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
  az role assignment create --assignee-object-id "$SP_OID" --assignee-type ServicePrincipal \
    --role contributor --scope "/subscriptions/$SUB_ID/resourceGroups/$RG" >/dev/null
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"main\", \"audiences\": [\"api://AzureADTokenExchange\"],
    \"subject\": \"repo:${GH_REPO}:ref:refs/heads/main\"
  }" >/dev/null
  TENANT=$(az account show --query tenantId -o tsv)
  cat <<EOF

GitHub OIDC is ready. In your repo -> Settings -> Secrets and variables -> Actions, add:

Secrets:
  AZURE_CLIENT_ID       = $APP_ID
  AZURE_TENANT_ID       = $TENANT
  AZURE_SUBSCRIPTION_ID = $SUB_ID

Variables:
  RESOURCE_GROUP        = $RG
  ACR_NAME              = $(get_output "$DEPLOY_NAME" acrName)
  APP_A                 = $(get_output "$DEPLOY_NAME-peers" appAName)
  APP_B                 = $(get_output "$DEPLOY_NAME-peers" appBName)

Push to main afterwards and the CI/CD workflow (".github/workflows/ci.yml")
builds the image in ACR and rolls it out to both servers.
EOF
  exit 0
fi

echo "==> Pass 1/3: resource group, ACR, Container Apps environment, Redis"
az group create --name "$RG" --location "$LOCATION" --output none
deploy "$DEPLOY_NAME" deployApps=false

ACR_NAME=$(get_output "$DEPLOY_NAME" acrName)

echo "==> Pass 2/3: building image livepoll:$IMAGE_TAG in ACR ($ACR_NAME) — cloud build, no local Docker needed"
az acr build --registry "$ACR_NAME" --image "livepoll:$IMAGE_TAG" .

echo "==> Pass 3/3: servers A and B (PEERS wired to their public URLs)"
deploy "$DEPLOY_NAME-apps" deployApps=true imageTag="$IMAGE_TAG"

APP_A=$(get_output "$DEPLOY_NAME-apps" appAName)
APP_B=$(get_output "$DEPLOY_NAME-apps" appBName)
URL_A=$(get_output "$DEPLOY_NAME-apps" urlA)
URL_B=$(get_output "$DEPLOY_NAME-apps" urlB)

deploy "$DEPLOY_NAME-peers" deployApps=true imageTag="$IMAGE_TAG" peers="$URL_A,$URL_B"

echo
echo "Done. Give everything ~30s for the first image pull, then:"
echo "  Audience join link (QR code): $URL_A/join  and  $URL_B/join"
echo "  Projector:   $URL_A/screen"
echo "  Host:        $URL_A/host"
echo "  Host key:    $HOST_KEY   (also saved in $KEYFILE)"
echo
echo "Optional: wire up GitHub Actions CD with:  GH_REPO=you/live-poll ./azure/deploy.sh github-oidc"
echo "Cost: ~\$0 at demo scale (Container Apps free grant covers it). Teardown: az group delete -n $RG"
