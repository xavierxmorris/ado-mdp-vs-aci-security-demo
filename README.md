# MDP vs ACI: what can a pipeline job reach?

A live, evidence-based security comparison of two ways to run self-hosted Azure Pipelines agents:

- **Managed DevOps Pools (MDP)**: Microsoft's recommended managed agent pools, with a fresh VM for every job.
- **Azure Container Instances (ACI)**: [Microsoft's documented Docker agent](https://learn.microsoft.com/azure/devops/pipelines/agents/docker), unchanged, running in ACI.

One pipeline runs the same **read-only probe** twice on each pool and reports what any job on that agent can reach. Examples include the agent's registration credential, files left by earlier jobs, and Azure identities. The probe never prints secret values. It reports only paths, variable names, machine identifiers, yes/no results and HTTP status codes.

Built to support Q2 of the [Services Australia Azure DevOps briefing pack](https://github.com/xavierxmorris/services-au-azure-devops-guide/blob/main/docs/02-self-hosted-agent-pools.md).

## Results

Run 5 on 9 November 2026 in Australia East, with **Proof of impact** on. Full output: [results/run-5.md](results/run-5.md).

| Check | ACI job 1 | ACI job 2 | MDP job 1 | MDP job 2 |
|---|---|---|---|---|
| Registration token readable on disk | 🔴 `/azp/.token` | 🔴 `/azp/.token` | 🟢 none | 🟢 none |
| Registration secret in a process environment | 🔴 `AZP_TOKEN` in `start.sh` | 🔴 `AZP_TOKEN` in `start.sh` | 🟢 none | 🟢 none |
| Registration token usable from the job (read-only proof) | 🔴 yes: listed 12 agent pools | 🔴 yes: listed 12 agent pools | 🟢 no token found | 🟢 no token found |
| Residue from an earlier job | 🔴 yes: from the previous run | 🔴 yes: from ACI job 1 | 🟢 no | 🟢 no |
| Machine (hostname, boot ID) | `SandboxHost-…353`, `c8532ac0` | `SandboxHost-…353`, `c8532ac0` | `958a090ae000000`, `dcc98662` | `e6879b07e000000`, `deff28a5` |
| Azure managed identity token obtainable | 🔴 yes (HTTP 200) | 🔴 yes (HTTP 200) | 🟢 no (HTTP 400) | 🟢 no (HTTP 400) |
| Agent session credential files readable | `.credentials`, `.credentials_rsaparams` | same | `.credentials` | `.credentials` |
| Root access for the job | no (runs as `agent`) | no (runs as `agent`) | yes (passwordless sudo) | yes (passwordless sudo) |
| Image ownership | Customer-built, Ubuntu 24.04.5 | same | Microsoft-maintained, `ubuntu24 20261025.353.1` | same |
| Docker available to jobs | no | no | yes | yes |

🔴 = reachable by every job on that agent. 🟢 = not found.

What the evidence shows:

- **Every ACI job can read the agent's registration PAT** from `/azp/.token` and from the environment of the `start.sh` process. With that PAT, a job made a read-only call that listed the organisation's 12 agent pools.
- **ACI jobs share one machine.** Both jobs ran in the same container (same hostname and boot ID). Job 1 found a file left by the previous run, and job 2 found job 1's file.
- **The ACI image-pull identity issues tokens to jobs.** The identity attached to the container group only for `AcrPull` returned an Azure token to a pipeline job.
- **MDP gave each job a new VM.** Both MDP jobs reported agent name `mdp-security-demo 1`, but different hostnames and boot IDs, and neither found residue.
- **MDP jobs have root on a disposable VM.** The job account has passwordless sudo. The VM holds no registration token or Azure identity and is discarded after the job.

## Why the results differ

| Area | ACI with Microsoft's container agent | Managed DevOps Pools |
|------|--------------------------------------|----------------------|
| Agent registration | Needs a **PAT** (or a service principal secret) with *Agent Pools (read & manage)*. Microsoft's `start.sh` keeps the PAT in `/azp/.token` so the agent can deregister itself on exit. | The MDP service registers agents. No registration credential is placed on the agent. |
| Who can read it | Every job on the agent, because jobs run as the same `agent` account as `start.sh`. `unset AZP_TOKEN` stops child processes inheriting the PAT, but `start.sh` still holds it in its own environment. | Not applicable. |
| ACI `secureValue` | Hides the PAT from the Azure control plane only. | Not applicable. |
| What a stolen registration PAT allows | It can register agents into any pool its owner administers. An attacker-controlled agent could then receive other pipelines' jobs and their secrets. *(Our analysis; the demo made one read-only call.)* | Not applicable. |
| Isolation between jobs | Persistent agent: files from one pipeline remain for the next, including pipelines from other projects that use the pool. | Stateless: each job gets a new VM, which is discarded afterwards. |
| Root on the agent | No (Microsoft's Dockerfile runs as `agent`), but root isn't needed to read the PAT. | Yes, passwordless sudo, on a VM that holds no reusable secret and lasts one job. |
| Azure identities | Any identity on the container group, even one used only for image pulls, issues tokens to jobs. | The demo pool has no identity. If you add one, jobs can use it too, so prefer workload identity federation service connections. |
| Image patching | You build, patch and rebuild the image. The agent downloads itself at start-up by using the PAT. | Microsoft-maintained Azure Pipelines images (or your own gallery images), with optional version pinning. |
| Container builds | No Docker daemon in ACI. | Docker is available on the VM. |
| Inbound exposure | None here: the container group has no IP address. | None: agent VMs run in a Microsoft-managed subscription. |
| Private networking | Both support VNet injection. It is **not** a differentiator and is not deployed here. | |

### If you must run container agents

*(Our analysis.)* These reduce, but don't remove, the exposures above:

- Use a separate pool per trust boundary. Never share one pool between production deployments and build or pull request pipelines.
- Run single-use agents (`--once`) with an orchestrator that replaces the container after every job.
- Keep registration credentials short-lived and narrowly scoped, and rotate them automatically.
- Attach no Azure identity that jobs don't need. Use workload identity federation service connections for deployments.

## What gets deployed

| Where | Resource | Purpose |
|-------|----------|---------|
| Azure DevOps | Project `mdp-vs-aci-security` | Isolated from other projects; holds the repo and pipeline. |
| Azure DevOps | Agent pool `aci-selfhosted-demo` | Self-hosted pool the ACI container registers into. `autoProvision` is off, so only this project gets it. |
| Azure DevOps | Pipeline `security-probe` | Explicitly authorised on both pools; no open access. |
| Azure DevOps | 7-day PAT, *Agent Pools (read & manage)* | The ACI agent's registration token, as Microsoft's container agent requires. Revoked by `teardown.ps1`. |
| Azure | Dev Center and project | Required parent for Managed DevOps Pools. |
| Azure | Managed DevOps Pool `mdp-security-demo` | Stateless, `Standard_D2ads_v5`, Ubuntu 24.04 Gen 2 Azure Pipelines image, up to 2 agents, `CreatorOnly` admin. One standby agent 08:00 to 18:00 on weekdays (Sydney time). |
| Azure | Container registry (Basic), admin user disabled | Hosts the agent image, built with ACR Tasks from Microsoft's Dockerfile. |
| Azure | User-assigned identity with `AcrPull` | Lets ACI pull the image without registry passwords. |
| Azure | Container group `aci-azp-agent` (1 vCPU, 2 GB) | Microsoft's documented container agent; persistent; no public IP. |

Region: **Australia East**. MDP is available in Australia East and Australia Southeast, not Australia Central.

## Prerequisites

- PowerShell 7.2 or later, and Azure CLI with Bicep.
- An Azure DevOps organisation connected to the **same Microsoft Entra tenant** as the subscription. You must be a **Project Collection Administrator**.
- **Owner** on the subscription, or **Contributor** plus **Role Based Access Control Administrator**. The template assigns `AcrPull`.
- MDP quota: Microsoft grants 5 `standardDADSv5Family` cores per supported region by default. That allows two `Standard_D2ads_v5` agents.
- At least one self-hosted parallel job. The free tier includes one; jobs then run one at a time.

## Run it

```powershell
az login --tenant <tenant-id>
./scripts/deploy.ps1 -Organization <org> -SubscriptionId <subscription-id>
./scripts/run-probe.ps1 -ProofOfImpact     # saves results/run-<id>.md
./scripts/teardown.ps1 -DeleteProject      # removes everything the demo created
```

- `deploy.ps1` is safe to re-run. It uses Microsoft Entra tokens from the Azure CLI for Azure DevOps, so you need no PAT to run it.
- `-ProofOfImpact` lets a probe job make **one read-only** API call (list agent pools) with any registration token it finds. Leave it off for a purely passive run.
- For a live walkthrough, see [RUN-SHEET.md](RUN-SHEET.md).

## Cost

- **ACI** runs continuously until removed: billed per second for 1 vCPU and 2 GB.
- **MDP** bills only for agent VMs and disks while they exist: during jobs, plus one standby agent on weekdays from 08:00 to 18:00. Set `-MdpStandbyAgents 0` to pay only while jobs run; each job then waits a few minutes for a VM.
- The container registry (Basic) has a small daily charge.
- Azure DevOps: each concurrent self-hosted job uses a self-hosted parallel job (the free tier includes one).

Run `teardown.ps1` after the demo.

## Honesty notes

- **Scope of the evidence.** Measured on 9 November 2026 in one demo tenant in Australia East. Pipeline runs 3 to 5 showed the same exposures; [results/run-5.md](results/run-5.md) has the full output of run 5. An earlier probe version checked only PID 1 and the agent listener, so it missed the PAT in `start.sh`'s environment. In ACI, PID 1 is the `pause` process.
- **The ACI side is Microsoft's documented container agent, unchanged, using a PAT.** Not tested: service principal registration, `--once` with automatic replacement, VNet injection, and Windows agents. A hardened custom design could reduce some exposures, but a registration credential must still reach the container. *(Our analysis.)*
- **MDP isn't safe in every respect.** Jobs get root on the VM and can read the agent's own session credentials while the job runs. The protection comes from stateless VMs that hold no reusable secret.
- **The proof of impact made one read-only call.** "Listed 12 agent pools" is the count that call returned. The demo never used the PAT to change anything.
- **The ACI identity in this demo has only `AcrPull`** on the demo registry. The finding is about reachability: any role granted to that identity is available to every job.
- **The probe never outputs secret values.** A local test with a fake token confirmed that values don't appear in logs or artifacts.
- **API versions differ from the docs.** On 9 November 2026, the PAT Lifecycle Management API required `api-version=7.1-preview.1`, although Microsoft Learn shows `7.1`. The MDP usage (quota) API required `2024-04-04-preview`.
- **This is a technical demonstration, not a security assessment.** Assess agent hosting against your own controls.

## Repository layout

```text
agent/        Microsoft's documented Dockerfile and start.sh (unchanged apart from an attribution header)
infra/        main.bicep (Dev Center, MDP pool, registry, identity) and aci.bicep (ACI agent)
pipelines/    security-probe.yml and the two-job probe template
scripts/      probe.sh, compare.sh, deploy.ps1, run-probe.ps1, teardown.ps1, common.ps1
results/      Comparison tables from real runs
```

## Sources

Retrieved 9 November 2026.

- Run a self-hosted agent in Docker: <https://learn.microsoft.com/azure/devops/pipelines/agents/docker?view=azure-devops>
- Managed DevOps Pools prerequisites (roles, providers, quota): <https://learn.microsoft.com/azure/devops/managed-devops-pools/prerequisites?view=azure-devops>
- Configure scaling (stateless agents, standby schedules): <https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-scaling?view=azure-devops>
- Configure images (`ubuntu-24.04-g2`): <https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-images?view=azure-devops>
- `Microsoft.DevOpsInfrastructure/pools` template reference: <https://learn.microsoft.com/azure/templates/microsoft.devopsinfrastructure/pools>
- PAT Lifecycle Management API: <https://learn.microsoft.com/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate?view=azure-devops#manage-pats-with-the-lifecycle-management-apis>
