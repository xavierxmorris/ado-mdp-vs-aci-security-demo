#!/usr/bin/env bash
# Read-only security probe for an Azure Pipelines agent.
#
# Records what ANY pipeline job that runs on this agent can reach. It never prints
# secret values: only file paths, variable names, yes/no results, counts and HTTP codes.
#
# Usage: probe.sh <pool-label> <job-label> [proof-of-impact: true|false]
set -uo pipefail

label="${1:?usage: probe.sh <pool-label> <job-label> [true|false]}"
job="${2:?usage: probe.sh <pool-label> <job-label> [true|false]}"
proof="$(printf '%s' "${3:-false}" | tr '[:upper:]' '[:lower:]')"

out_dir="${BUILD_ARTIFACTSTAGINGDIRECTORY:-/tmp}/probe"
mkdir -p "$out_dir"
agent_home="${AGENT_HOMEDIRECTORY:-}"
marker="${HOME:-/tmp}/.agent-security-probe-marker"

list() {
  if [ "$#" -eq 0 ]; then printf 'none'; return; fi
  local first=1 item
  for item in "$@"; do
    if [ "$first" -eq 1 ]; then first=0; else printf ', '; fi
    printf '%s' "$item"
  done
}

# 1. Agent registration token stored on disk and readable by this job.
token_files=()
for candidate in "${agent_home:+$agent_home/.token}" /azp/.token; do
  [ -n "$candidate" ] && [ -f "$candidate" ] && [ -r "$candidate" ] && [ -s "$candidate" ] || continue
  resolved="$(readlink -f "$candidate")"
  case " ${token_files[*]} " in *" $resolved "*) ;; *) token_files+=("$resolved") ;; esac
done

# 2. Registration secrets still in the environment of the container entrypoint (PID 1) or the
#    agent listener. Only exact variable NAMES are matched and reported; values are never output.
secret_env=()
for proc in /proc/[0-9]*; do
  pid="${proc#/proc/}"
  comm="$(cat "$proc/comm" 2>/dev/null || true)"
  [ "$pid" = "1" ] || [ "$comm" = "Agent.Listener" ] || continue
  [ -r "$proc/environ" ] || continue
  while IFS= read -r name; do
    secret_env+=("$name in pid $pid ($comm)")
  done < <(tr '\0' '\n' < "$proc/environ" 2>/dev/null | cut -d= -f1 | grep -E '^(AZP_TOKEN|AZP_CLIENTSECRET)$' || true)
done

# 3. The agent's own session credentials (every self-hosted agent has them).
agent_creds=()
for f in .credentials .credentials_rsaparams; do
  [ -n "$agent_home" ] && [ -r "$agent_home/$f" ] && agent_creds+=("$f")
done

# 4. Residue left on this machine by an earlier job.
if [ -f "$marker" ]; then
  residue="yes: $(head -n 1 "$marker" | cut -c1-160)"
else
  residue="no"
fi
printf 'left by run %s (%s %s) on agent %s at %s\n' "${BUILD_BUILDNUMBER:-?}" "$label" "$job" \
  "${AGENT_NAME:-?}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"

# 5. Can this job get an Azure managed identity token? The token is discarded, only the status is kept.
mi_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' \
  2>/dev/null || true)"
case "$mi_code" in
  200) identity="yes (HTTP 200: a token was issued to this job)" ;;
  000 | "") identity="no (identity endpoint unreachable)" ;;
  *) identity="no (HTTP $mi_code)" ;;
esac

# 6. Root on the machine.
if [ "$(id -u)" = "0" ]; then
  root="yes (job runs as root)"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  root="yes (passwordless sudo)"
else
  root="no"
fi

# 7. Who maintains and patches the image.
os_name="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown OS}")"
if [ -n "${ImageVersion:-}" ]; then
  image="Microsoft-maintained image ${ImageOS:-} ${ImageVersion} ($os_name)"
elif [ -f /imagegeneration/imagedata.json ]; then
  image="Microsoft-maintained image ($os_name)"
else
  image="Customer-built image ($os_name): you patch and rebuild it"
fi

# 8. Docker available to jobs (needs VM-level isolation; not available in ACI).
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then docker_ok="yes"; else docker_ok="no"; fi

# 9. Optional proof of impact: one read-only API call with a discovered registration token.
#    The token is passed to curl on stdin, so it never appears in a command line or in the log.
impact="not attempted"
if [ "$proof" = "true" ]; then
  if [ "${#token_files[@]}" -gt 0 ]; then
    response="$(printf 'user = ":%s"\n' "$(cat "${token_files[0]}")" | curl -s -K - --max-time 15 -w '\n%{http_code}' \
      "${SYSTEM_COLLECTIONURI%/}/_apis/distributedtask/pools?api-version=7.1" 2>/dev/null || true)"
    code="${response##*$'\n'}"
    if [ "$code" = "200" ]; then
      count="$(printf '%s' "${response%$'\n'*}" | jq -r '.count // "?"' 2>/dev/null || printf '?')"
      impact="yes: the agent's registration token works from this job (read-only call listed $count agent pools)"
    elif [ -z "$code" ] || [ "$code" = "000" ]; then
      impact="no: Azure DevOps was unreachable"
    else
      impact="no: token rejected (HTTP $code)"
    fi
  else
    impact="no registration token found"
  fi
fi

findings="$out_dir/findings-$label-$job.json"
jq -n \
  --arg pool "$label" --arg job "$job" --arg agent "${AGENT_NAME:-?}" --arg user "$(id -un)" \
  --arg tokenFiles "$(list "${token_files[@]}")" \
  --arg secretEnv "$(list "${secret_env[@]}")" \
  --arg agentCreds "$(list "${agent_creds[@]}")" \
  --arg residue "$residue" --arg identity "$identity" --arg root "$root" \
  --arg image "$image" --arg docker "$docker_ok" --arg impact "$impact" '
  def flag(exposed): if exposed then "exposed" else "clear" end;
  {
    pool: $pool, job: $job, agent: $agent, user: $user,
    checks: [
      {id: "token_file", name: "Registration token readable on disk", value: $tokenFiles, status: flag($tokenFiles != "none")},
      {id: "secret_env", name: "Registration secret in agent process environment", value: $secretEnv, status: flag($secretEnv != "none")},
      {id: "impact", name: "Registration token usable from the job (read-only proof)", value: $impact,
       status: (if $impact == "not attempted" then "info" else flag($impact | startswith("yes")) end)},
      {id: "residue", name: "Residue from an earlier job", value: $residue, status: flag($residue | startswith("yes"))},
      {id: "identity", name: "Azure managed identity token obtainable", value: $identity, status: flag($identity | startswith("yes"))},
      {id: "agent_creds", name: "Agent session credential files readable", value: $agentCreds, status: "info"},
      {id: "root", name: "Root access for the job", value: $root, status: "info"},
      {id: "image", name: "Image ownership", value: $image, status: "info"},
      {id: "docker", name: "Docker available to jobs", value: $docker, status: "info"}
    ]
  }' > "$findings"

summary="$out_dir/summary-$label-$job.md"
{
  printf '### %s %s on agent `%s`\n\n| Check | Result |\n|---|---|\n' "$label" "$job" "${AGENT_NAME:-?}"
  jq -r '.checks[] | "| \(.name) | \(if .status == "exposed" then "🔴 " elif .status == "clear" then "🟢 " else "" end)\(.value | gsub("\\|"; "/")) |"' "$findings"
} > "$summary"

cat "$summary"
echo "##vso[task.uploadsummary]$summary"
