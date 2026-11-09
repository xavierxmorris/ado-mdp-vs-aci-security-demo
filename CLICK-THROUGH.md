# Click-through: MDP vs ACI security demo

A clean, step-by-step plan for presenting this demo live. Each step says what to click, what to point at, what to say, and what it proves. It's the same demo as [RUN-SHEET.md](RUN-SHEET.md), which was rehearsed in a browser against the first instance, adapted for a second instance in another organisation. UI labels here follow that rehearsal.

Every step was run end to end on **9 November 2026** in the Azure DevOps organisation **xaviermorris0108**, with the Azure resources in resource group **rg-mdp-vs-aci-0108** (Australia East). The verified pipeline run is [run 6](https://dev.azure.com/xaviermorris0108/mdp-vs-aci-security/_build/results?buildId=6); its output is in [results/run-6-xaviermorris0108.md](results/run-6-xaviermorris0108.md). To build the same thing in another organisation, see [Build this instance](#build-this-instance).

## What the demo proves

| # | Claim | Step |
|---|---|---|
| C1 | Both pools are locked down the same way: one project, one authorised pipeline, no open access, no classic pipelines | 1 |
| C2 | The ACI agent registers with a PAT that lives inside the container. MDP needs no registration credential from you | 2, 3, 4 |
| C3 | Every job on the ACI agent can read that PAT and use it | 5 |
| C4 | ACI jobs share one long-lived container and see earlier jobs' files. Each MDP job gets a fresh machine | 5, 6 |
| C5 | An identity attached to the container group only to pull the image gives Azure tokens to jobs. The MDP agents have no identity | 3, 4, 5 |
| C6 | ACI runs an image you build and patch. MDP runs a Microsoft-maintained image | 3, 4, 5 |
| C7 | The trade-off, said out loud: MDP jobs have root on a machine that holds nothing reusable and is discarded after the job | 5 |

## The instance

| Where | What | Link or path |
|---|---|---|
| Azure DevOps | Organisation | <https://dev.azure.com/xaviermorris0108> |
| | Project `mdp-vs-aci-security` | <https://dev.azure.com/xaviermorris0108/mdp-vs-aci-security> |
| | Pipeline `security-probe` | <https://dev.azure.com/xaviermorris0108/mdp-vs-aci-security/_build?definitionId=3> |
| | Agent pools `aci-selfhosted-demo` and `mdp-security-demo` | <https://dev.azure.com/xaviermorris0108/_settings/agentpools> |
| Azure, Australia East | Resource group `rg-mdp-vs-aci-0108` | Azure portal > **Resource groups** |
| | Managed DevOps Pool `mdp-security-demo-0108`, shown in Azure DevOps as `mdp-security-demo` through a [pool alias](https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-security?view=azure-devops#configure-pool-aliases) | |
| | Container group `aci-azp-agent` (Microsoft's documented container agent) | |
| | Registry `acrmdpaci<suffix>`, identity `id-aci-acrpull-<suffix>`, Dev Center `dc-mdpaci-<suffix>` and Dev Center project `dcp-mdpaci-<suffix>` | |

Sign in to both with the account that deployed the demo: a Project Collection Administrator in the organisation and an Owner of the subscription, in the same Microsoft Entra tenant. Use one browser profile; if **Pick an account** appears, choose that account. Run the scripts from the clone that deployed this instance; its `.demo-state.json` (git-ignored) points at `xaviermorris0108`. `./scripts/demo-links.ps1` writes direct links for this instance, including the portal blades, to `DEMO-LINKS.local.md` (git-ignored).

## Before the meeting (15 minutes)

| # | Check | Where | Expect | If not |
|---|---|---|---|---|
| P1 | The ACI agent is online | Organization settings > Agent pools > `aci-selfhosted-demo` > **Agents** | `aci-agent-1`, **Online**, **Idle** | [T1](#if-something-goes-wrong) |
| P2 | An MDP standby machine is ready | Portal > `mdp-security-demo-0108` > **Settings** > **Agents** | One agent, status **Ready**. Standby runs 08:00 to 18:00 on weekdays, Sydney time | Outside those hours the first MDP job waits for a machine. Rely on the pre-run |
| P3 | A finished run to fall back on | Pipelines > `security-probe` | Run 6 (or a newer one) succeeded | `./scripts/run-probe.ps1 -ProofOfImpact` (about 7 minutes) |
| P4 | The ACI registration PAT hasn't expired | User settings > **Personal access tokens** | `aci-agent-registration (mdp-vs-aci-security demo)`, expires **16 Nov 2026** | Re-run `deploy.ps1` with `-RotateAciToken` ([T1](#if-something-goes-wrong)) |
| P5 | Tabs are open | See [Screen layout](#screen-layout) | | |

**Don't click:** **Connect** on the ACI container (it opens a shell), **Apply** on any MDP settings pane, **Revoke** or **Regenerate** on the PAT, or the pool names in the run panel.

## Screen layout

Azure DevOps on the left, the Azure portal on the right. Open these tabs in order:

1. Organization settings > Agent pools: <https://dev.azure.com/xaviermorris0108/_settings/agentpools>
2. Project settings > Agent pools: <https://dev.azure.com/xaviermorris0108/mdp-vs-aci-security/_settings/agentqueues>
3. Personal access tokens: <https://dev.azure.com/xaviermorris0108/_usersSettings/tokens>
4. The pipeline: <https://dev.azure.com/xaviermorris0108/mdp-vs-aci-security/_build?definitionId=3>
5. The pre-run, run 6: <https://dev.azure.com/xaviermorris0108/mdp-vs-aci-security/_build/results?buildId=6>
6. Portal: resource group `rg-mdp-vs-aci-0108`

## Step by step (about 14 minutes)

### Step 0. Start the live run first (1 min)

**Click:** tab 4, `security-probe` > **Run pipeline**. Under **Parameters**, tick **Proof of impact - make one read-only API call with any registration token a job finds**, and leave the pool names as they are. The panel has two pages: select **Next: Resources**, then **Run**.

**Point at:** the three stages: **ACI self-hosted agent**, **Managed DevOps Pool** and **Compare findings**. The organisation has one self-hosted parallel job, so the jobs run one at a time.

**Say:** "This runs the same read-only script twice on each pool. It reports file paths, variable names, yes or no, and HTTP codes, never a secret value. It takes about 7 minutes, longer when MDP is slow to hand over a machine, so we'll start it now and come back to it."

**Why first:** steps 1 to 4 take about 7 minutes, which gives the run time to finish. Step 5 reads the pre-run (run 6), so the demo doesn't depend on the live run.

### Step 1. Two pools, locked down the same way (2 min). Proves C1

**Click:** tab 1, **Organization settings** > **Pipelines** > **Agent pools**.

**Point at:** `aci-selfhosted-demo` and `mdp-security-demo`.

**Click:** `aci-selfhosted-demo` > **Agents**. One agent, `aci-agent-1`, **Online**: a long-lived container.

**Click:** back, then `mdp-security-demo`. Its tabs are **Jobs**, **Details**, **Security** and **Analytics**; there's no **Agents** tab, because MDP registers and manages the agents. **Jobs** shows each MDP job and how long it waited.

**Click:** **Security**. **Inheritance** is **Off**. The account that created the pool is the only **Administrator**; everyone else in the organisation is a **Reader**. MDP's *Creator only* setting did this. Now open `aci-selfhosted-demo` > **Security**: **Inheritance** is **On**. A pool you create yourself inherits organisation-level pool permissions until you turn that off.

**Click:** tab 2, **Project settings** > **Agent pools** > each pool > **Security**. Under **Pipeline permissions**, only `security-probe` is listed. Open access is off: **More actions** would offer **Open access**.

**Say:** "Both pools are private to this project, and only this pipeline may use them. Classic build and release pipeline creation is disabled too, and that matters, because pipeline permissions don't restrict classic pipelines. So everything you'll see comes from a job that was *allowed* to run, which is the real threat: any pipeline that can use a pool."

**Proves:** C1. The locked-down settings are identical, so the differences you'll see come from the agent design.

### Step 2. The PAT the ACI agent needs (1 min). Proves C2

**Click:** tab 3, **User settings** > **Personal access tokens**.

**Point at:** `aci-agent-registration (mdp-vs-aci-security demo)`. Its scope is **Agent Pools: Read & manage**, and it lasts 7 days. Don't click **Revoke** or **Regenerate**.

**Say:** "Microsoft's documented container agent needs a token like this inside the container. It uses it to download the agent, register, and deregister when the container stops. MDP has no equivalent: the MDP service registers its own agents."

**Proves:** C2, the ACI side.

### Step 3. ACI in the portal (2 min). Sets up C3 and C5; proves C6

**Click:** tab 6, resource group `rg-mdp-vs-aci-0108`. Point at the six resources.

**Click:** `aci-azp-agent` > **Settings** > **Properties**. **IP address** is `-`: there's no inbound endpoint. **Restart policy** is **Always**: a persistent agent.

**Click:** **Settings** > **Containers**. With `azp-agent` selected, open the **Properties** tab (next to **Events**) and scroll to **Environment variables**. `AZP_URL`, `AZP_POOL` and `AZP_AGENT_NAME` show values. `AZP_TOKEN`'s value is blank, because it's a [secure value](https://learn.microsoft.com/azure/container-instances/container-instances-environment-variables#secure-values).

**Say:** "Azure hides the PAT from the control plane. Microsoft's docs are explicit that secure values 'can be accessed only from within the container'. That's exactly where pipeline jobs run."

**Click:** **Settings** > **Identity** > **User assigned**: `id-aci-acrpull-<suffix>`. Open it, then **Azure role assignments**: **AcrPull** on the demo registry, and nothing else.

**Click:** the registry > **Settings** > **Access keys**. **Admin user** is off.

**Say:** "We did the right things: no registry password, a pull-only identity, no public IP, and an image built from Microsoft's own Dockerfile. It's still our image, so we patch and rebuild it."

**Proves:** C6, and the setup for C3 and C5.

### Step 4. MDP in the portal (2 min). Proves C2 and C6

**Click:** `mdp-security-demo-0108` > **Overview**: **Agent state: Stateless**, **Maximum agents: 2**, and the **Pool Usage** chart.

**Click:** **Settings** > **Scaling**: **Agent state: Fresh agent every time**. **Standby agent mode: Manual**, **Weekday Scheme**, **(UTC+10:00) Canberra, Melbourne, Sydney**, 08:00 to 18:00, count 1.

**Click:** **Settings** > **Security**: **Add pool to all projects: No** (only `mdp-vs-aci-security`). **Use pool in multiple organizations** and **Enable Interactive Mode** are off. **Alias** is `mdp-security-demo`: MDP pool names must be [globally unique in Azure](https://learn.microsoft.com/azure/devops/managed-devops-pools/quickstart-azure-portal?view=azure-devops#create-the-managed-devops-pools-resource), so this second instance keeps the Azure DevOps pool name through an alias.

**Click:** **Settings** > **Agents**. One machine, image `mmsubuntu24.04-g2`, **Status: Ready**.

**Click:** **Overview** > **JSON View**. There's no `identity` block: the pool has no managed identity.

**Say:** "No PAT, no identity, no image to patch. The machines run a Microsoft-maintained image in a Microsoft-managed subscription, and MDP registers them itself."

**Proves:** C2 (the MDP side) and C6.

### Step 5. Read the evidence (4 min). Proves C3 to C7

**Click:** tab 5, run 6 > **Extensions**. The table is titled **MDP vs ACI: what can a pipeline job reach?** Walk the rows from top to bottom:

| Row | ACI (both jobs) | MDP (both jobs) | Say | Claim |
|---|---|---|---|---|
| Registration token readable on disk | 🔴 `/azp/.token` | 🟢 none | "Any job can read the agent's PAT." | C3 |
| Registration secret in a process environment | 🔴 `AZP_TOKEN` in `start.sh` | 🟢 none | "`start.sh` unsets it for child processes, but its own environment still holds it." | C3 |
| Registration token usable from the job | 🔴 the read-only call listed **13 agent pools** | 🟢 no token | "Thirteen is every pool in this organisation, including `xt-demo-pool`, which belongs to another project. The token carries the rights of whoever deployed the agent." | C3 |
| Residue from an earlier job | 🔴 yes: job 1 found a file from the previous run, job 2 found job 1's | 🟢 no | "One pipeline can leave something behind for the next one." | C4 |
| Machine (hostname, boot ID) | the same for both jobs | different for each job | "The agent *name* on MDP is a slot. A new boot ID, and no residue, show a fresh machine for each job." | C4 |
| Azure managed identity token obtainable | 🔴 HTTP 200 | 🟢 HTTP 400 | "The pull-only identity gave a token to a pipeline job." | C5 |
| Root access for the job | no (runs as `agent`) | yes (passwordless sudo) | "On ACI you don't need root to steal the PAT. On MDP the job owns the machine, but the machine holds nothing reusable and is gone after the job." | C7 |
| Image ownership | customer-built | Microsoft-maintained `ubuntu24` | "Who patches what." | C6 |
| Docker available to jobs | no | yes | "ACI can't build containers; an MDP VM can." | |

**Click:** **aci job 1** > **Probe what this job can reach**. The log shows the same table: names and paths only, never values.

**Proves:** C3, C4, C5, C6 and C7.

### Step 6. Fresh machine compared with the same container (1 min). Proves C4

**Click:** portal > `mdp-security-demo-0108` > **Settings** > **Agents**, during or after the live run. In this instance, the machine that ran a job moves to **Allocated**, then **PendingReturn**, then **Returned**, and a new machine with a different name appears and becomes **Ready**. In run 6, the two MDP jobs ran on machines `efbc31fce000000` and `107366abe000000`, and MDP started another one for standby. The first instance reimages machines instead, so a name can repeat with a new boot ID. Either way, the job gets a fresh agent.

**Click:** portal > `aci-azp-agent` > **Settings** > **Containers** > `azp-agent` > **Events**: one **Started** event and no restarts. Then **Logs**: `Running job: aci job 1`, `aci job 2` and `Side-by-side summary`, run after run, all in the same container.

**Say:** "MDP throws the machine away. ACI keeps it and hands it to the next job."

### Step 7. Close (1 min)

**Say:** "For shared pools, use Managed DevOps Pools with fresh agents. Deploy through workload identity federation service connections, not identities on agents. If you must run container agents, use one pool per trust boundary, single-use agents, short-lived registration credentials, and no identity that jobs don't need." For the full reasoning, see the README's [Why the results differ](README.md#why-the-results-differ).

**Then:** go back to the live run from step 0. If it has finished, its **Extensions** tab shows the same table as run 6. If an MDP job is still queued, say so: MDP is waiting to hand over a machine ([T2](#if-something-goes-wrong)), and run 6 is the same probe.

## Exact strings

| Where | Text |
|---|---|
| Run panel parameter | `Proof of impact - make one read-only API call with any registration token a job finds` |
| Run panel parameters | `ACI self-hosted agent pool`, `Managed DevOps Pool` |
| Run panel buttons | **Next: Resources**, then **Run** |
| MDP pool tabs in Azure DevOps | **Jobs**, **Details**, **Security**, **Analytics** (no **Agents** tab) |
| Stages | `ACI self-hosted agent`, `Managed DevOps Pool`, `Compare findings` |
| Jobs | `aci job 1`, `aci job 2`, `mdp job 1`, `mdp job 2`, `Side-by-side summary` |
| Probe step | `Probe what this job can reach` |
| Extensions tab title | `MDP vs ACI: what can a pipeline job reach?` |
| Artifacts | `probe-aci-job1`, `probe-aci-job2`, `probe-mdp-job1`, `probe-mdp-job2`, `probe-comparison` |
| ACI registration PAT | `aci-agent-registration (mdp-vs-aci-security demo)` |
| Unauthorised pipeline | `This pipeline needs permission to access a resource before this run can continue` |

## Results from this instance

Run 6 on 9 November 2026, with **Proof of impact** on. Full output: [results/run-6-xaviermorris0108.md](results/run-6-xaviermorris0108.md).

| Check | ACI job 1 | ACI job 2 | MDP job 1 | MDP job 2 |
|---|---|---|---|---|
| Registration token readable on disk | 🔴 `/azp/.token` | 🔴 `/azp/.token` | 🟢 none | 🟢 none |
| Registration secret in a process environment | 🔴 `AZP_TOKEN` in `start.sh` | 🔴 `AZP_TOKEN` in `start.sh` | 🟢 none | 🟢 none |
| Registration token usable from the job | 🔴 listed 13 agent pools | 🔴 listed 13 agent pools | 🟢 no token | 🟢 no token |
| Residue from an earlier job | 🔴 from run 5 | 🔴 from ACI job 1 | 🟢 no | 🟢 no |
| Machine (hostname, boot ID) | `SandboxHost-…518`, `a4173a2c` | `SandboxHost-…518`, `a4173a2c` | `efbc31fce000000`, `6d50758b` | `107366abe000000`, `b6adcc90` |
| Azure managed identity token obtainable | 🔴 HTTP 200 | 🔴 HTTP 200 | 🟢 HTTP 400 | 🟢 HTTP 400 |
| Root access for the job | no | no | yes (sudo) | yes (sudo) |
| Image ownership | customer-built | customer-built | Microsoft `ubuntu24 20261025.353.1` | same |
| Docker available to jobs | no | no | yes | yes |

These match the first instance's [run 5](results/run-5.md): every row is exposed or clear in the same places. Only the details differ: the pool count (13 here, 12 there; each is the whole organisation's pools), the residue's source run, and the machine identifiers.

Runs 5 and 7 in this organisation were cancelled: see [T2](#if-something-goes-wrong). Even so, run 5's files were still in the ACI container for run 6 to find.

Timings: `deploy.ps1` took 531 seconds. Run 6 took 6.5 minutes from queue to finish, with one standby MDP agent and one self-hosted parallel job. MDP job 2 needed a new machine, which took about 2 minutes.

## If something goes wrong

| # | Symptom | Fix |
|---|---|---|
| T1 | The ACI agent is offline, or the PAT has expired | `az container restart -g rg-mdp-vs-aci-0108 -n aci-azp-agent`, then wait about 2 minutes (`az container logs -g rg-mdp-vs-aci-0108 -n aci-azp-agent` shows progress). After the PAT expires, re-run the [deploy command](#build-this-instance) with the same parameters plus `-RotateAciToken`; it creates a new PAT and revokes the old one. |
| T2 | An MDP job stays queued | Without a standby machine, MDP creates one per job, which [can take up to 15 minutes](https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-scaling?view=azure-devops#standby-agent-mode). In this instance, MDP jobs started 1 to 6 minutes after being queued. Twice (runs 5 and 7), the second MDP job never started. Azure DevOps assigned it to an agent slot, but its request to MDP was never sent (the agent cloud request had no provision time). The portal showed a **Ready** machine, and the pool's **Demand** metric stayed at 0. The stuck job also holds the organisation's only self-hosted parallel job, so the ACI job queued behind it waits too. **Cancel the run and queue it again**: run 6, queued straight after run 5 was cancelled, finished in 6.5 minutes. The first instance's 8 MDP jobs all started within 2.5 minutes. We haven't found the cause. This instance differs in its pool alias, its VM size (no local temp disk), how MDP recycles machines (it returns and replaces them; the first instance reimages them) and the time of day. In the meeting, rely on the pre-run. |
| T3 | `This pipeline needs permission to access a resource before this run can continue` | Select **Permit**. Or re-run `deploy.ps1`, which authorises the pipeline on both pools, or go to **Project settings** > **Agent pools** > the pool > **Security** > **Pipeline permissions** > **Add pipeline** > `security-probe`. |
| T4 | Jobs wait for each other | Expected. The organisation has one self-hosted parallel job, shared by every self-hosted pool, MDP included. |
| T5 | `deploy.ps1` warns about MDP quota | It prints the family, for example `standardDASv5Family: 0 of 5 cores used`. Choose a `-MdpSku` whose family has free cores, or request more quota. |
| T6 | The MDP pool name is taken | MDP names are global. Use a new `-MdpPoolName` and keep the Azure DevOps name with `-MdpPoolAlias`. |

## Questions you may get

- **"Isn't `secureValue` enough?"** No. It keeps the value out of the Azure control plane, but Microsoft documents that it's readable inside the container, and that's where jobs run.
- **"Would a service principal be better than a PAT?"** Microsoft's `start.sh` also accepts a client ID and secret. It un-exports the secret, but `start.sh`'s own shell still holds it, so we'd expect the same exposure. *(Our analysis; not tested.)*
- **"Why does MDP give jobs root?"** The model is to assume the job controls the machine, and to make the machine disposable and free of reusable secrets.
- **"Both MDP jobs say `mdp-security-demo 1`. Same machine?"** No. That's the slot name. Each job reports a different boot ID, and no residue. In this instance the hostnames differ too, because MDP replaced the machine.
- **"What could someone do with the PAT?"** The demo made one read-only call. A *read & manage* agent-pools token can register an agent into any pool its owner administers, and that agent would then receive other pipelines' jobs. *(Our analysis.)*
- **"Does private networking change this?"** No. Every option supports it, so it isn't a differentiator.
- **"What about AKS?"** It uses the same image and PAT as ACI. See the README's [AKS analysis](README.md#aks-analysis-not-measured).

## Cost and teardown

- **ACI** runs all the time (1 vCPU, 2 GB) until you remove it.
- **MDP** bills for agent VMs while they exist: during jobs, plus one standby `Standard_D2as_v5` from 08:00 to 18:00 on weekdays. Re-run the deploy command with `-MdpStandbyAgents 0` to pay only while jobs run.
- The **registry** (Basic) has a small daily charge.

To remove this instance, run this from the clone that deployed it:

```powershell
./scripts/teardown.ps1 -DeleteProject
```

It deletes `rg-mdp-vs-aci-0108` (the MDP pool, the ACI agent, the registry, the identity and the Dev Center), revokes the PAT, deletes the `aci-selfhosted-demo` pool and deletes the project. MDP removes its Azure DevOps pool with the Azure resource; the script warns if that pool remains. **Run it only from this instance's clone.** Another clone's `.demo-state.json` points at another instance.

## Build this instance

This instance shares a subscription with the first one (another organisation), so it needs a different resource group, a different MDP pool name, and a VM family with free quota:

```powershell
git clone https://github.com/xavierxmorris/ado-mdp-vs-aci-security-demo ado-mdp-vs-aci-security-demo-0108
cd ado-mdp-vs-aci-security-demo-0108
az login --tenant <tenant-id>   # Project Collection Administrator in the org, Owner on the subscription
./scripts/deploy.ps1 -Organization xaviermorris0108 -SubscriptionId <subscription-id> `
    -ResourceGroup rg-mdp-vs-aci-0108 -MdpPoolName mdp-security-demo-0108 `
    -MdpPoolAlias mdp-security-demo -MdpSku Standard_D2as_v5
./scripts/run-probe.ps1 -ProofOfImpact   # saves results/run-<id>-xaviermorris0108.md
```

| Parameter | Why |
|---|---|
| `-ResourceGroup rg-mdp-vs-aci-0108` | One resource group per instance, because teardown deletes the whole group. |
| `-MdpPoolName mdp-security-demo-0108` | MDP pool names are globally unique in Azure, and the first instance already uses `mdp-security-demo`. |
| `-MdpPoolAlias mdp-security-demo` | Keeps the Azure DevOps pool name, so the pipeline's default pool name works unchanged. |
| `-MdpSku Standard_D2as_v5` | The first instance's standby agent used 4 of the 5 default `standardDADSv5Family` cores in Australia East. `standardDASv5Family` had all 5 free. |

The organisation must use the same Microsoft Entra tenant as the subscription. The run also needs at least one self-hosted parallel job; the free tier includes one.
