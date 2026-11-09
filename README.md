# MDP vs ACI vs AKS: what can a pipeline job reach?

A live, evidence-based security comparison of self-hosted Azure Pipelines agents:

- **Managed DevOps Pools (MDP)**: Microsoft's recommended managed agent pools, with a fresh agent for every job. *Measured.*
- **Azure Container Instances (ACI)**: [Microsoft's documented Docker agent](https://learn.microsoft.com/azure/devops/pipelines/agents/docker), unchanged, running in ACI. *Measured.*
- **Azure Kubernetes Service (AKS)**: the same agent image with [Microsoft's documented Kubernetes deployment](https://learn.microsoft.com/azure/devops/pipelines/agents/docker#use-azure-kubernetes-service-cluster). *Analysed, not measured:* see [AKS](#aks-analysis-not-measured).

VMSS agent pools aren't included: Microsoft describes MDP as their evolution. Q2 of the briefing pack compares all four options from documentation.

An optional, measured [deep dive](#deep-dive-measured) adds ACI with `--once`, MDP with agent reuse, an Azure Policy baseline, pool access control, a WIF deployment and audit-log detection.

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
- **MDP gave each job a fresh agent.** In run 5, the two MDP jobs reported agent name `mdp-security-demo 1` but different hostnames and boot IDs. In run 15, started from the UI, both used machine `958a090ae000000` with different boot IDs. With standby agents, MDP reimages a machine from a clean image after each job, so the name can repeat; the new boot ID and the empty residue check show the agent is fresh. Full output: [results/run-15.md](results/run-15.md).
- **MDP jobs have root on a short-lived machine.** The job account has passwordless sudo. The machine holds no registration token or Azure identity, and MDP reimages or removes it after the job.

## AKS (analysis, not measured)

We tried to measure AKS in the same subscription, but cluster creation was blocked: the subscription doesn't allow public IP addresses (`SubscriptionNotRegisteredForFeature` for `Microsoft.Network/AllowBringYourOwnPublicIpAddress`), so the nodes couldn't get outbound access to Azure DevOps. We chose not to register that subscription-wide exception. The expectations below come from Microsoft's documented AKS steps, which use **the same image and `start.sh` measured on ACI**.

| Check | Expected for Microsoft's AKS deployment | Basis |
|---|---|---|
| Registration token readable on disk | 🔴 Yes: `/azp/.token` | Same image and `start.sh` as ACI (measured above). |
| Registration secret in a process environment | 🔴 Yes: `AZP_TOKEN` in `start.sh` | The PAT is injected from the `azdevops` secret as an environment variable, as on ACI. |
| Registration token usable from the job | 🔴 Yes | Same PAT and scope as ACI. |
| PAT also stored as a Kubernetes secret | 🔴 Yes: secret `azdevops` | Microsoft's step 1: `kubectl create secret generic azdevops`. Anyone who can read secrets in that namespace can read the PAT. |
| Residue from an earlier job | 🔴 Yes | The manifest runs a persistent Deployment (`replicas: 1`, no `--once`). |
| Azure managed identity token obtainable | 🔴 Expected yes | Microsoft: by default, all pods can reach IMDS. Pods can then request tokens for the node's managed identities, including the kubelet identity that the steps grant `AcrPull` with `--attach-acr`. Blocking pod access to IMDS is in preview. |
| Host access | 🔴 The example mounts the node's `/var/run/docker.sock` | The documented manifest uses a `hostPath` volume. AKS nodes use containerd, so there is no Docker socket, but `hostPath` mounts weaken pod isolation. Remove the mount. |
| Docker available to jobs | No | Microsoft: Docker tasks don't work on AKS 1.19 or later. |
| Image ownership | Customer-built; you also patch the nodes | Same image as ACI, plus node image upgrades. |

*(Our analysis. Check the expectations by running [scripts/probe.sh](scripts/probe.sh) on an AKS agent in a subscription that allows outbound IP addresses.)*

## Deep dive (measured)

Run 16 on 9 November 2026 added two variants and a deployment using the recommended pattern ([results/run-16.md](results/run-16.md)). Scenes 6 to 10 of the [run sheet](RUN-SHEET.md) show them.

| What a job could reach | ACI | ACI with `--once` | MDP, *Fresh agent every time* | MDP, *Same agent can be reused* |
|---|---|---|---|---|
| The registration PAT (on disk, in the `start.sh` environment, and usable) | 🔴 yes | 🔴 yes | 🟢 no | 🟢 no |
| Files left by an earlier job | 🔴 yes | 🟢 no | 🟢 no | 🔴 yes |
| An Azure identity token | 🔴 yes | 🔴 yes | 🟢 no | 🟢 no |
| Machine for job 1 and job 2 | Same container | Same host, restarted container | Same name, new boot ID (reimaged) | Same machine and boot ID |

- **`--once` fixes leftover files, not credentials.** ACI restarted the container after each job, giving a fresh filesystem. But every job could still read and use the PAT and get the identity's token. The agent re-registers with the PAT after every job, so the PAT must stay valid for as long as the agent runs; the audit log shows **Removed agent** and **Added agent** for each job.
- **MDP's protection depends on one setting.** With **Same agent can be reused by multiple builds**, job 2 ran on the same machine (same boot ID) and found job 1's file.
- **Azure Policy can enforce that setting.** MDP publishes policy aliases. In audit mode, the demo's baseline flagged `mdp-stateful-demo` under "Managed DevOps Pools should give every job a fresh agent". It also flagged both pools under "Managed DevOps Pools should run in your own virtual network".
- **Pool access is granted per pipeline.** `unapproved-pipeline` stopped at "This pipeline needs permission to access a resource before this run can continue" (agent pool `mdp-security-demo`, **Permission needed**). Pipeline permissions don't cover classic pipelines, so disable classic pipeline creation.
- **A WIF deployment on MDP needs no secret.** Inside the task, the job signed in as a service principal through workload identity federation, read the resource group, and had `*/read` only. Outside the task, it had no Azure identity (IMDS HTTP 400).
- **Detection needs auditing on.** **Log audit events** was off in this organisation; Azure DevOps turns it off by default. With it on, **Organization settings** > **Auditing** shows every agent registration (`Library.AgentAdded`) with the PAT owner and the source IP address ([results/audit-2026-11-09.md](results/audit-2026-11-09.md)).

## Why the results differ

AKS entries are *analysis* (see above); ACI and MDP entries are measured.

| Area | ACI with Microsoft's container agent | AKS with Microsoft's Kubernetes manifest *(analysis)* | Managed DevOps Pools |
|------|--------------------------------------|------------------------------------------------------|----------------------|
| Agent registration | Needs a **PAT** (or a service principal secret) with *Agent Pools (read & manage)*. Microsoft's `start.sh` keeps the PAT in `/azp/.token` so the agent can deregister itself on exit. | Same image, so the same PAT requirement. Microsoft's steps also store the PAT as a Kubernetes secret. | The MDP service registers agents. No registration credential is placed on the agent. |
| Who can read it | Every job on the agent, because jobs run as the same `agent` account as `start.sh`. `unset AZP_TOKEN` stops child processes inheriting the PAT, but `start.sh` still holds it in its own environment. | Every job on the agent, as on ACI, plus anyone who can read secrets in the namespace. | Not applicable. |
| Platform secret protection | ACI `secureValue` hides the PAT from the Azure control plane only. | Kubernetes secrets block users without `get secrets`, not processes in the pod. | Not applicable. |
| What a stolen registration PAT allows | It can register agents into any pool its owner administers. An attacker-controlled agent could then receive other pipelines' jobs and their secrets. *(Our analysis; the demo made one read-only call.)* | Same. | Not applicable. |
| Isolation between jobs | Persistent agent: files from one pipeline remain for the next, including pipelines from other projects that use the pool. | Persistent Deployment: same as ACI. Per-job pods need extra tooling, such as KEDA (a community project). | Stateless (*Fresh agent every time*): each job gets a fresh agent. With standby agents, MDP reimages the machine after the job; without them, it shuts the machine down and removes it. |
| Root on the agent | No (Microsoft's Dockerfile runs as `agent`), but root isn't needed to read the PAT. | No (same image); root isn't needed to read the PAT. | Yes, passwordless sudo, on a machine that holds no reusable secret and is reimaged or removed after one job. |
| Azure identities | Any identity on the container group, even one used only for image pulls, issues tokens to jobs. | By default every pod can reach IMDS, so jobs can request the node's identity tokens. Blocking this is in preview. | The demo pool has no identity. If you add one, jobs can use it too, so prefer workload identity federation service connections. |
| Image patching | You build, patch and rebuild the image. The agent downloads itself at start-up by using the PAT. | You patch the image and upgrade the nodes and cluster. | Microsoft-maintained Azure Pipelines images (or your own gallery images), with optional version pinning. |
| Container builds | No Docker daemon in ACI. | No Docker on AKS 1.19 or later; Microsoft's example still mounts `docker.sock` from the node, which should be removed. | Docker is available on the VM. |
| Outbound access | Platform-managed. | You design it (load balancer IP, NAT gateway or firewall). It blocked our AKS test. | Microsoft-managed, or through your VNet with VNet injection. |
| Inbound exposure | None here: the container group has no IP address. | The agent needs none; cluster endpoints depend on your design. | None: agent VMs run in a Microsoft-managed subscription. |
| Private networking | All three support private networking. It is **not** a differentiator and isn't deployed here. | | |

### If you must run container agents

*(Our analysis.)* These reduce, but don't remove, the exposures above:

- Use a separate pool per trust boundary. Never share one pool between production deployments and build or pull request pipelines.
- Run single-use agents (`--once`) with an orchestrator that replaces the container after every job. **Measured:** this removed leftover files, but not the PAT or identity exposure.
- Keep registration credentials short-lived and narrowly scoped, and rotate them automatically.
- Attach no Azure identity that jobs don't need. Use workload identity federation service connections for deployments.

## Controls this demo supports

*(Our analysis, mapped to the evidence above: a starting point for an architecture governance control set.)*

| Control | How | Evidence |
|---|---|---|
| Run pipelines on Managed DevOps Pools with **Fresh agent every time** | Azure Policy on `Microsoft.DevOpsInfrastructure/pools/agentProfile.kind`: Audit first, then Deny | Scenes 3 and 7 |
| Keep agents on a private network | VNet injection, checked by Azure Policy on `fabricProfile.Vmss.networkProfile.subnetId` | Scene 7 (VNet injection isn't possible in this subscription) |
| No registration credentials or identities on agents | MDP instead of container agents; no managed identity on pools | Scenes 2, 5 and 6 |
| Deploy through WIF service connections with least privilege | Manual WIF connection, narrowly scoped role, pipeline permissions, approvals and checks | Scene 9 |
| Restrict which pipelines can use each pool | Pipeline permissions per pool (no open access), approvals and checks, and classic pipelines disabled | Scene 8 |
| Restrict PATs | Tenant and organisation PAT policies. **Restrict personal access token (PAT) creation** was off in this organisation. | **Organization settings** > **Policies** |
| Detect unexpected agents | **Log audit events** on, streamed to Microsoft Sentinel, with alerts on `Library.AgentAdded` for production pools | Scene 10 |

## What gets deployed

| Where | Resource | Purpose |
|-------|----------|---------|
| Azure DevOps | Project `mdp-vs-aci-security` | Isolated from other projects; holds the repo and pipeline. |
| Azure DevOps | Agent pool `aci-selfhosted-demo` | Self-hosted pool the ACI container registers into. `autoProvision` is off, so only this project gets it. |
| Azure DevOps | Pipeline `security-probe` | Explicitly authorised on each pool; no open access. |
| Azure DevOps | 7-day PAT, *Agent Pools (read & manage)* | The ACI agent's registration token, as Microsoft's container agent requires. Revoked by `teardown.ps1`. |
| Azure | Dev Center and project | Required parent for Managed DevOps Pools. |
| Azure | Managed DevOps Pool `mdp-security-demo` | Stateless, `Standard_D2ads_v5`, Ubuntu 24.04 Gen 2 Azure Pipelines image, up to 2 agents, `CreatorOnly` admin. One standby agent 08:00 to 18:00 on weekdays (Sydney time). |
| Azure | Container registry (Basic), admin user disabled | Hosts the agent image, built with ACR Tasks from Microsoft's Dockerfile. |
| Azure | User-assigned identity with `AcrPull` | Lets ACI pull the image without registry passwords. |
| Azure | Container group `aci-azp-agent` (1 vCPU, 2 GB) | Microsoft's documented container agent; persistent; no public IP. |
| Deep dive | Container group `aci-azp-agent-once`, pool `aci-once-demo` and a second 7-day PAT | The same agent run with `--once` and restart policy **Always**. |
| Deep dive | Managed DevOps Pool `mdp-stateful-demo` | **Same agent can be reused** (maximum lifetime 1 day, 30-minute grace period), `Standard_E2as_v4` (separate MDP quota), no standby. |
| Deep dive | Pipeline `unapproved-pipeline` | Targets `mdp-security-demo` but is deliberately not authorised. |
| Deep dive | Identity `id-wif-deployer-…` and service connection `sc-wif-demo` | Workload identity federation (manual), Reader on the demo resource group only; only `security-probe` may use the connection. |
| Deep dive | Two custom policy definitions (subscription) and assignments (demo resource group, Audit) | MDP pools should use fresh agents and run in your own virtual network. |

Region: **Australia East**. MDP is available in Australia East and Australia Southeast, not Australia Central.

## Prerequisites

- PowerShell 7.2 or later, and Azure CLI with Bicep.
- An Azure DevOps organisation connected to the **same Microsoft Entra tenant** as the subscription. You must be a **Project Collection Administrator**.
- **Owner** on the subscription, or **Contributor** plus **Role Based Access Control Administrator** and **Resource Policy Contributor**. The templates assign `AcrPull` and `Reader`, and create policy definitions.
- MDP quota: Microsoft grants 5 cores per VM family per supported region by default. That allows two `Standard_D2ads_v5` agents (`standardDADSv5Family`), and the deep dive's agent-reuse pool uses `standardEASv4Family`.
- At least one self-hosted parallel job. The free tier includes one; jobs then run one at a time.
- Use `-SkipDeepDive` with `deploy.ps1` to deploy only the core demo.

## Run it

```powershell
az login --tenant <tenant-id>
./scripts/deploy.ps1 -Organization <org> -SubscriptionId <subscription-id>
./scripts/run-probe.ps1 -ProofOfImpact     # saves results/run-<id>.md
./scripts/run-probe.ps1 -ProofOfImpact -DeepDive   # also ACI --once, MDP agent reuse and WIF (about 10 minutes)
./scripts/audit-evidence.ps1               # saves results/audit-<date>.md
./scripts/teardown.ps1 -DeleteProject      # removes everything the demo created
```

- `deploy.ps1` is safe to re-run. It uses Microsoft Entra tokens from the Azure CLI for Azure DevOps, so you need no PAT to run it.
- `-ProofOfImpact` lets a probe job make **one read-only** API call (list agent pools) with any registration token it finds. Leave it off for a purely passive run.
- For a live walkthrough, see [RUN-SHEET.md](RUN-SHEET.md). `./scripts/demo-links.ps1` writes your deployment's direct links to `DEMO-LINKS.local.md` (git-ignored).

## Cost

- **ACI** runs continuously until removed: billed per second for 1 vCPU and 2 GB.
- **MDP** bills only for agent VMs and disks while they exist: during jobs, plus one standby agent on weekdays from 08:00 to 18:00. Set `-MdpStandbyAgents 0` to pay only while jobs run; each job then waits a few minutes for a VM.
- The container registry (Basic) has a small daily charge.
- Deep dive: the second ACI container group also runs continuously, and the agent-reuse pool keeps its VM for 30 minutes after each job.
- Azure DevOps: each concurrent self-hosted job uses a self-hosted parallel job (the free tier includes one).

Run `teardown.ps1` after the demo.

## Honesty notes

- **Scope of the evidence.** Measured on 9 November 2026 in one demo tenant in Australia East. Pipeline runs 3 to 5, and run 15 started from the Azure DevOps UI, showed the same exposures. [results/run-5.md](results/run-5.md) and [results/run-15.md](results/run-15.md) have the full output. An earlier probe version checked only PID 1 and the agent listener, so it missed the PAT in `start.sh`'s environment. In ACI, PID 1 is the `pause` process.
- **The ACI side is Microsoft's documented container agent, unchanged, using a PAT.** The deep dive also tested `--once`. Not tested: service principal registration, VNet injection, and Windows agents. A hardened custom design could reduce some exposures, but a registration credential must still reach the container. *(Our analysis.)*
- **AKS wasn't measured.** The subscription blocks public IP addresses, so the cluster couldn't be created, and we didn't register the subscription-wide exception. The AKS entries are analysis based on Microsoft's documentation and the shared image; the probe hasn't confirmed them.
- **MDP isn't safe in every respect.** Jobs get root on the machine and can read the agent's own session credentials while the job runs. The protection comes from stateless agents that hold no reusable secret and are reimaged or removed after each job.
- **The proof of impact made one read-only call.** "Listed 12 agent pools" is the count that call returned; later runs listed 13 and 15 as the organisation gained pools. The demo never used the PAT to change anything.
- **Deep-dive guardrails are deliberately mild.** The policies use Audit and are assigned only to the demo resource group. The private-network policy flags both pools because VNet injection wasn't possible here. The WIF identity has Reader on the demo resource group only. `wif-check.sh` no longer prints its client ID, and the ID is removed from the saved run-16 results. The `unapproved-pipeline` run was cancelled, never permitted.
- **Auditing was turned on for the demo.** **Log audit events** was off in this organisation, so the Auditing page was hidden, although the audit API still returned the day's events. We turned it on for scene 10; `teardown.ps1` leaves it on.
- **The ACI identity in this demo has only `AcrPull`** on the demo registry. The finding is about reachability: any role granted to that identity is available to every job.
- **The probe never outputs secret values.** A local test with a fake token confirmed that values don't appear in logs or artifacts.
- **API versions differ from the docs.** On 9 November 2026, the PAT Lifecycle Management API required `api-version=7.1-preview.1`, although Microsoft Learn shows `7.1`. The MDP usage (quota) API required `2024-04-04-preview`.
- **This is a technical demonstration, not a security assessment.** Assess agent hosting against your own controls.

## Repository layout

```text
agent/        Microsoft's documented Dockerfile and start.sh (unchanged apart from an attribution header)
infra/        main.bicep (Dev Center, MDP pools, registry, identities), aci.bicep (ACI agents),
              policy.bicep and policy-assignments.bicep (MDP policy baseline)
pipelines/    security-probe.yml, the two-job probe template, and unapproved.yml
scripts/      probe.sh, compare.sh, wif-check.sh, deploy.ps1, run-probe.ps1, audit-evidence.ps1,
              demo-links.ps1, teardown.ps1, common.ps1
results/      Comparison tables and audit evidence from real runs
```

## Sources

Retrieved 9 November 2026.

- Run a self-hosted agent in Docker: <https://learn.microsoft.com/azure/devops/pipelines/agents/docker?view=azure-devops>
- Managed DevOps Pools prerequisites (roles, providers, quota): <https://learn.microsoft.com/azure/devops/managed-devops-pools/prerequisites?view=azure-devops>
- Configure scaling (stateless agents, standby schedules): <https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-scaling?view=azure-devops>
- Configure images (`ubuntu-24.04-g2`): <https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-images?view=azure-devops>
- `Microsoft.DevOpsInfrastructure/pools` template reference: <https://learn.microsoft.com/azure/templates/microsoft.devopsinfrastructure/pools>
- PAT Lifecycle Management API: <https://learn.microsoft.com/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate?view=azure-devops#manage-pats-with-the-lifecycle-management-apis>
- Run the agent on AKS (secret, Deployment manifest, Docker caution): <https://learn.microsoft.com/azure/devops/pipelines/agents/docker?view=azure-devops#use-azure-kubernetes-service-cluster>
- Block pod access to IMDS on AKS (preview; by default all pods can reach IMDS): <https://learn.microsoft.com/azure/aks/imds-restriction>
- Agent pool security (pipeline permissions don't restrict classic pipelines): <https://learn.microsoft.com/azure/devops/pipelines/agents/pools-queues?view=azure-devops#security-of-agent-pools>
- Disable creation of classic pipelines: <https://learn.microsoft.com/azure/devops/pipelines/security/approach?view=azure-devops#disable-creation-of-classic-pipelines>
- Auditing (off by default; 90-day retention): <https://learn.microsoft.com/azure/devops/organizations/audit/azure-devops-auditing?view=azure-devops>
- Audit streaming: <https://learn.microsoft.com/azure/devops/organizations/audit/auditing-streaming?view=azure-devops>
