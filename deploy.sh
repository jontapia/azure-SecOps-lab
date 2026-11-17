#!/usr/bin/env bash
# =============================================================================
# deploy.sh — builds the jontapia Azure SecOps lab end to end.
# Run in Azure Cloud Shell (Bash):  ./deploy.sh
# Takes about 30-40 minutes (Bastion + AD forest promotion + domain join).
# =============================================================================
set -euo pipefail

LOCATION="${LOCATION:-westus2}"   # East US was restricted on my free trial
RG="${RG:-rg-jontapia-secops-lab}"
# Sizes to try in order. Free-trial subscriptions often lose access to popular sizes,
# so the script validates each one and uses the first that Azure will actually accept.
CANDIDATE_SIZES="${VM_SIZE:-Standard_B1ms Standard_B2als_v2 Standard_B2s Standard_B2ms}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*"; exit 1; }

az account show --query "{subscription:name, tenant:tenantId}" -o table \
  || die "Not signed in. Run: az login"

read -rp "Email for security alerts: " ALERT_EMAIL
[[ "$ALERT_EMAIL" == *@*.* ]] || die "That doesn't look like an email address."

# --- Resource providers ----------------------------------------------------------
say "Registering resource providers"
for ns in Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.KeyVault \
          Microsoft.RecoveryServices Microsoft.OperationalInsights Microsoft.Insights \
          Microsoft.SecurityInsights Microsoft.OperationsManagement Microsoft.DevTestLab \
          Microsoft.PolicyInsights; do
  az provider register --namespace "$ns" --wait -o none
done

# --- Resolve built-in policy definitions by display name --------------------------
say "Looking up built-in Azure Policy definitions"
policy_id() {
  local id
  id=$(az policy definition list --query "[?policyType=='BuiltIn' && displayName=='$1'].name | [0]" -o tsv)
  [[ -n "$id" ]] || die "Built-in policy not found: $1"
  echo "$id"
}
POL_LOCATIONS=$(policy_id "Allowed locations")
POL_NIC_PIP=$(policy_id "Network interfaces should not have public IPs")
POL_BACKUP=$(policy_id "Azure Backup should be enabled for Virtual Machines")
echo "Allowed locations:      $POL_LOCATIONS"
echo "No public IPs on NICs:  $POL_NIC_PIP"
echo "Audit VM backup:        $POL_BACKUP"

# --- Identity + secrets -----------------------------------------------------------
DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv)
# Generated, never typed or saved locally. Stored in Key Vault by the deployment.
# On a rerun, reuse the password already in Key Vault: Azure won't let you change
# the admin password on a VM that already exists.
EXISTING_KV=$(az keyvault list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)
ADMIN_PASS=""
if [[ -n "$EXISTING_KV" ]]; then
  ADMIN_PASS=$(az keyvault secret show --vault-name "$EXISTING_KV" -n domain-admin-password \
    --query value -o tsv 2>/dev/null || true)
  [[ -n "$ADMIN_PASS" ]] && echo "Reusing admin password from $EXISTING_KV"
fi
[[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="Jt-$(openssl rand -hex 10)-Az9"

# --- Deploy -----------------------------------------------------------------------
say "Creating resource group $RG"
az group create -n "$RG" -l "$LOCATION" \
  --tags owner=jontapia project=azure-secops-lab environment=lab -o none

PARAMS=(
  adminPassword="$ADMIN_PASS"
  deployerObjectId="$DEPLOYER_ID"
  alertEmail="$ALERT_EMAIL"
  policyAllowedLocationsId="$POL_LOCATIONS"
  policyNoNicPublicIpId="$POL_NIC_PIP"
  policyAuditVmBackupId="$POL_BACKUP"
)

# --- Pick a VM size Azure will accept (preflight only, creates nothing) ----------
say "Finding a VM size with capacity in $LOCATION"
VM_SIZE=""
for size in $CANDIDATE_SIZES; do
  if az deployment group validate -g "$RG" --template-file main.bicep \
       --parameters "${PARAMS[@]}" vmSize="$size" -o none 2>/tmp/validate.err; then
    VM_SIZE="$size"; echo "Using $size"; break
  fi
  echo "$size: $(grep -o 'SkuNotAvailable\|QuotaExceeded\|InvalidTemplate[A-Za-z]*' /tmp/validate.err | head -1)"
done
[[ -n "$VM_SIZE" ]] || { cat /tmp/validate.err; die "No candidate size passed validation. Try another region: LOCATION=centralus ./deploy.sh"; }

# --- vCPU quota: two VMs of the chosen size --------------------------------------
VCPUS=$(az vm list-skus -l "$LOCATION" --size "$VM_SIZE" --resource-type virtualMachines \
  --query "[?name=='$VM_SIZE'] | [0].capabilities[?name=='vCPUs'] | [0].value" -o tsv)
NEED=$(( VCPUS * 2 ))
USED=$(az vm list-usage -l "$LOCATION" --query "[?name.value=='cores'] | [0].currentValue" -o tsv)
LIMIT=$(az vm list-usage -l "$LOCATION" --query "[?name.value=='cores'] | [0].limit" -o tsv)
echo "Regional vCPUs: $USED used of $LIMIT, need $NEED"
(( LIMIT - USED >= NEED )) || die "Not enough vCPUs. Tear down the other lab first."

say "Deploying main.bicep with $VM_SIZE (30-40 minutes; the AD forest builds itself)"
deploy() {
  az deployment group create \
    -g "$RG" \
    -n "secops-lab-$(date +%Y%m%d-%H%M%S)" \
    --template-file main.bicep \
    --parameters "${PARAMS[@]}" vmSize="$VM_SIZE" \
    --query "properties.outputs" -o jsonc
}
if ! deploy; then
  # Usually the Sentinel tables are still being created. Give Azure a few minutes.
  say "Deploy failed. Waiting 5 minutes, then retrying once"
  sleep 300
  deploy || die "Deploy failed twice. Screenshot the error above."
fi

unset ADMIN_PASS

KV=$(az keyvault list -g "$RG" --query "[0].name" -o tsv)
say "Done."
cat <<EOF
Get the domain admin password:
  az keyvault secret show --vault-name $KV -n domain-admin-password --query value -o tsv

Connect: Portal > jt-srv01 > Connect > Bastion
  Username: JONTAPIA\\jontapia

Tear down when finished:  ./teardown.sh
EOF
