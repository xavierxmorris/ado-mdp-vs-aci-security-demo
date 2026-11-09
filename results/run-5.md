## MDP vs ACI: what can a pipeline job reach?

Same read-only probe, two jobs per pool, run 20261109.3. 🔴 = exposed to every job on that agent, 🟢 = not found.

| Check | ACI job1 | ACI job2 | MDP job1 | MDP job2 |
|---|---|---|---|---|
| Registration token readable on disk | 🔴 /azp/.token | 🔴 /azp/.token | 🟢 none | 🟢 none |
| Registration secret in a process environment | 🔴 AZP_TOKEN in start.sh (checked 7 readable process environments; PID 1 is pause) | 🔴 AZP_TOKEN in start.sh (checked 7 readable process environments; PID 1 is pause) | 🟢 none (checked 6 readable process environments; PID 1 is systemd) | 🟢 none (checked 6 readable process environments; PID 1 is systemd) |
| Registration token usable from the job (read-only proof) | 🔴 yes: the agent's registration token works from this job (read-only call listed 12 agent pools) | 🔴 yes: the agent's registration token works from this job (read-only call listed 12 agent pools) | 🟢 no registration token found | 🟢 no registration token found |
| Residue from an earlier job | 🔴 yes: left by run 20261109.2 (aci job2) on agent aci-agent-1 at 2026-11-09T02:58:45Z | 🔴 yes: left by run 20261109.3 (aci job1) on agent aci-agent-1 at 2026-11-09T03:01:44Z | 🟢 no | 🟢 no |
| Machine (hostname, boot ID) | SandboxHost-639297892372119353, boot c8532ac0 | SandboxHost-639297892372119353, boot c8532ac0 | 958a090ae000000, boot dcc98662 | e6879b07e000000, boot deff28a5 |
| Azure managed identity token obtainable | 🔴 yes (HTTP 200: a token was issued to this job) | 🔴 yes (HTTP 200: a token was issued to this job) | 🟢 no (HTTP 400) | 🟢 no (HTTP 400) |
| Agent session credential files readable | .credentials, .credentials_rsaparams | .credentials, .credentials_rsaparams | .credentials | .credentials |
| Root access for the job | no (job runs as agent) | no (job runs as agent) | yes (passwordless sudo for AzDevOps) | yes (passwordless sudo for AzDevOps) |
| Image ownership | Customer-built image (Ubuntu 24.04.5 LTS): you patch and rebuild it | Customer-built image (Ubuntu 24.04.5 LTS): you patch and rebuild it | Microsoft-maintained image ubuntu24 20261025.353.1 (Ubuntu 24.04.5 LTS) | Microsoft-maintained image ubuntu24 20261025.353.1 (Ubuntu 24.04.5 LTS) |
| Docker available to jobs | no | no | yes | yes |

Agents: aci job1 = `aci-agent-1`, aci job2 = `aci-agent-1`, mdp job1 = `mdp-security-demo 1`, mdp job2 = `mdp-security-demo 1`
