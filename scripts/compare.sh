#!/usr/bin/env bash
# Combines the probe findings from every job into one comparison table (no secrets are involved).
# Usage: compare.sh <directory containing downloaded probe artifacts> <output directory>
set -euo pipefail

source_dir="${1:?usage: compare.sh <artifact dir> <output dir>}"
out_dir="${2:?usage: compare.sh <artifact dir> <output dir>}"
mkdir -p "$out_dir"

mapfile -t files < <(find "$source_dir" -type f -name 'findings-*.json' | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "##vso[task.logissue type=error]No probe findings found under $source_dir"
  exit 1
fi
wif_file="$(find "$source_dir" -type f -name 'wif-result.json' | head -n 1)"

out="$out_dir/comparison.md"
{
  printf '## MDP vs ACI: what can a pipeline job reach?\n\n'
  printf 'Same read-only probe, two jobs per pool, run %s. 🔴 = exposed to every job on that agent, 🟢 = not found.\n' "${BUILD_BUILDNUMBER:-?}"
  printf 'ACI-ONCE = ACI agent run with `--once`; MDP-STATEFUL = MDP with "Same agent can be reused". Full values are in each job'"'"'s section below.\n\n'
  jq -rs '
    def icon: if .status == "exposed" then "🔴 " elif .status == "clear" then "🟢 " else "" end;
    sort_by(.pool, .job) as $runs
    | ("| Check | " + ($runs | map("\(.pool | ascii_upcase) \(.job)") | join(" | ")) + " |"),
      ("|---|" + ($runs | map("---") | join("|")) + "|"),
      ($runs[0].checks[] as $c
        | "| \($c.name) | "
          + ($runs | map(.checks[] | select(.id == $c.id) | icon + ((.short // .value) | gsub("\\|"; "/"))) | join(" | "))
          + " |"),
      "",
      ("Agents: " + ($runs | map("\(.pool) \(.job) = `\(.agent)`") | join(", ")))
  ' "${files[@]}"
  if [ -n "$wif_file" ]; then
    printf '\n### Deploying the recommended way: WIF service connection on MDP\n\n'
    jq -r '"| Check | Result |", "|---|---|",
      "| Azure sign-in inside the task | \(.signedInAs) |",
      "| Read the demo resource group | \(.readResult) |",
      "| Allowed actions on the resource group | \(.writeResult) |",
      "| Azure identity reachable outside the task (IMDS) | \(.imdsOutsideTask) |"' "$wif_file"
  fi
} > "$out"

cat "$out"
echo "##vso[task.uploadsummary]$out"
