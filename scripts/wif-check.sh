#!/usr/bin/env bash
# Runs inside an AzureCLI@2 task that uses the WIF service connection, then checks what the rest of
# the job can reach. Writes wif-result.json and a summary. No token or secret is printed.
# Usage: wif-check.sh <resource-group> <inside|outside>
set -uo pipefail

resource_group="${1:?usage: wif-check.sh <resource-group> <inside|outside>}"
phase="${2:?usage: wif-check.sh <resource-group> <inside|outside>}"
out_dir="${BUILD_ARTIFACTSTAGINGDIRECTORY:-/tmp}/wif"
mkdir -p "$out_dir"
state="$out_dir/wif-state.json"

if [ "$phase" = "inside" ]; then
  # Signed in by AzureCLI@2 with a federated token for this job only.
  client_id="$(az account show --query user.name -o tsv 2>/dev/null || printf '?')"
  if az group show --name "$resource_group" --query name -o tsv >/dev/null 2>&1; then
    read_result="yes: read $resource_group"
  else
    read_result="no: read failed"
  fi
  # Least privilege, checked read-only: list the actions this identity is allowed on the resource group.
  subscription="$(az account show --query id -o tsv 2>/dev/null || true)"
  actions="$(az rest --method get \
    --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" \
    --query "value[].actions[]" -o tsv 2>/dev/null | sort -u | paste -sd, - || true)"
  if [ "$actions" = "*/read" ]; then
    write_result="*/read only: no write rights"
  elif [ -z "$actions" ]; then
    write_result="permissions check failed"
  else
    write_result="allowed: $actions"
  fi
  jq -n --arg who "service principal $client_id (federated, no secret)" --arg read "$read_result" --arg write "$write_result" \
    '{signedInAs: $who, readResult: $read, writeResult: $write}' > "$state"
  cat "$state"
  exit 0
fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' \
  2>/dev/null || true)"
case "$code" in
  200) outside="yes (HTTP 200)" ;;
  000 | "") outside="no (unreachable)" ;;
  *) outside="no (HTTP $code)" ;;
esac
jq --arg outside "$outside" '. + {imdsOutsideTask: $outside}' "$state" > "$out_dir/wif-result.json"
summary="$out_dir/summary-wif.md"
jq -r '"### WIF service connection on MDP\n\n| Check | Result |\n|---|---|",
  "| Azure sign-in inside the task | \(.signedInAs) |",
  "| Read the demo resource group | \(.readResult) |",
  "| Allowed actions on the resource group | \(.writeResult) |",
  "| Azure identity reachable outside the task (IMDS) | \(.imdsOutsideTask) |"' "$out_dir/wif-result.json" > "$summary"
cat "$summary"
echo "##vso[task.uploadsummary]$summary"
