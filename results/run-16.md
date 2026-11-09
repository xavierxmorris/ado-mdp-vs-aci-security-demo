## MDP vs ACI: what can a pipeline job reach?

Same read-only probe, two jobs per pool, run 20261109.5. 🔴 = exposed to every job on that agent, 🟢 = not found.
ACI-ONCE = ACI agent run with `--once`; MDP-STATEFUL = MDP with "Same agent can be reused". Full values are in each job's section below.

| Check | ACI job1 | ACI job2 | ACI-ONCE job1 | ACI-ONCE job2 | MDP job1 | MDP job2 | MDP-STATEFUL job1 | MDP-STATEFUL job2 |
|---|---|---|---|---|---|---|---|---|
| Registration token readable on disk | 🔴 /azp/.token | 🔴 /azp/.token | 🔴 /azp/.token | 🔴 /azp/.token | 🟢 none | 🟢 none | 🟢 none | 🟢 none |
| Registration secret in a process environment | 🔴 AZP_TOKEN in start.sh | 🔴 AZP_TOKEN in start.sh | 🔴 AZP_TOKEN in start.sh | 🔴 AZP_TOKEN in start.sh | 🟢 none | 🟢 none | 🟢 none | 🟢 none |
| Registration token usable from the job (read-only proof) | 🔴 yes: listed 15 pools | 🔴 yes: listed 15 pools | 🔴 yes: listed 15 pools | 🔴 yes: listed 15 pools | 🟢 no token | 🟢 no token | 🟢 no token | 🟢 no token |
| Residue from an earlier job | 🔴 yes: from aci job2 | 🔴 yes: from aci job1 | 🟢 no | 🟢 no | 🟢 no | 🟢 no | 🟢 no | 🔴 yes: from mdp-stateful job1 |
| Machine (hostname, boot ID) | SandboxHost…9353, boot c8532ac0 | SandboxHost…9353, boot c8532ac0 | SandboxHost…0976, boot 7ce9df49 | SandboxHost…0976, boot 7ce9df49 | 958a090ae000000, boot 0de8d509 | 958a090ae000000, boot a2528c7e | 16583d6ee000000, boot 88e62c19 | 16583d6ee000000, boot 88e62c19 |
| Azure managed identity token obtainable | 🔴 yes (HTTP 200) | 🔴 yes (HTTP 200) | 🔴 yes (HTTP 200) | 🔴 yes (HTTP 200) | 🟢 no (HTTP 400) | 🟢 no (HTTP 400) | 🟢 no (HTTP 400) | 🟢 no (HTTP 400) |
| Agent session credential files readable | .credentials, .credentials_rsaparams | .credentials, .credentials_rsaparams | .credentials, .credentials_rsaparams | .credentials, .credentials_rsaparams | .credentials | .credentials | .credentials | .credentials |
| Root access for the job | no (agent) | no (agent) | no (agent) | no (agent) | yes (sudo) | yes (sudo) | yes (sudo) | yes (sudo) |
| Image ownership | customer-built | customer-built | customer-built | customer-built | Microsoft-maintained | Microsoft-maintained | Microsoft-maintained | Microsoft-maintained |
| Docker available to jobs | no | no | no | no | yes | yes | yes | yes |

Agents: aci job1 = `aci-agent-1`, aci job2 = `aci-agent-1`, aci-once job1 = `aci-once-1`, aci-once job2 = `aci-once-1`, mdp job1 = `mdp-security-demo 1`, mdp job2 = `mdp-security-demo 1`, mdp-stateful job1 = `mdp-stateful-demo 1`, mdp-stateful job2 = `mdp-stateful-demo 1`

### Deploying the recommended way: WIF service connection on MDP

| Check | Result |
|---|---|
| Azure sign-in inside the task | servicePrincipal via workload identity federation (no secret; client ID removed) |
| Read the demo resource group | yes: read rg-mdp-vs-aci-security |
| Allowed actions on the resource group | */read only: no write rights |
| Azure identity reachable outside the task (IMDS) | no (HTTP 400) |
