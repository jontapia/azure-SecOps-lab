#!/usr/bin/env bash
# =============================================================================
# teardown.sh — removes the lab so it stops costing money.
# Stops backup protection, deletes the resource group, purges the Key Vault.
# =============================================================================
set -euo pipefail

RG="${RG:-rg-jontapia-secops-lab}"
VAULT="jt-rsv-corp"

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

if [[ "$(az group exists -n "$RG")" != "true" ]]; then
  echo "Resource group $RG not found. Nothing to delete."
  exit 0
fi

KV=$(az keyvault list -g "$RG" --query "[0].name" -o tsv)

# A vault holding backup data blocks resource group deletion.
if az backup vault show -g "$RG" -n "$VAULT" -o none 2>/dev/null; then
  for VM in jt-dc01 jt-srv01; do
    say "Stopping backup and deleting recovery points for $VM"
    az backup protection disable \
      -g "$RG" --vault-name "$VAULT" \
      --container-name "$VM" --item-name "$VM" \
      --backup-management-type AzureIaasVM --workload-type VM \
      --delete-backup-data true --yes -o none 2>/dev/null || true
  done
  for _ in $(seq 1 20); do
    left=$(az backup item list -g "$RG" --vault-name "$VAULT" --query "length(@)" -o tsv)
    [[ "$left" == "0" ]] && break
    echo "Waiting for backup items to clear..."; sleep 15
  done
fi

say "Deleting resource group $RG (about 10-15 minutes, Bastion is slow to delete)"
az group delete -n "$RG" --yes

# Key Vault soft delete is mandatory; purge so the name is free for the next run.
if [[ -n "$KV" ]]; then
  say "Purging soft-deleted Key Vault $KV"
  az keyvault purge --name "$KV" -o none || true
fi

say "Teardown complete."
