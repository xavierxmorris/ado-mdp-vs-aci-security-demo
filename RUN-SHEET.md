# Demo script: MDP vs ACI, click by click (about 12 minutes, plus an optional 10-minute deep dive)

Every click below was rehearsed in a browser on 9 November 2026, including starting the pipeline from the UI. The core run took 3 minutes 39 seconds; the deep-dive run took about 10 minutes.

**Get your exact links first:** run `./scripts/demo-links.ps1`. It writes `DEMO-LINKS.local.md` (git-ignored) with a direct link for each scene.

## Before the demo (15 minutes before)

| # | Check | Where | Expected |
|---|-------|-------|----------|
| 1 | Sign in once | One browser profile: `dev.azure.com` and `portal.azure.com` with the demo account. If **Pick an account** appears, choose the demo account, not an administrator or corporate account. | Both open without prompts |
| 2 | ACI agent is online | Azure DevOps: **Organization settings** > **Agent pools** > `aci-selfhosted-demo` > **Agents** | `aci-agent-1`, **Online**, **Idle** |
| 3 | MDP standby is ready | Azure portal: `mdp-security-demo` > **Settings** > **Agents** | One machine, **Status: Ready** (weekdays 08:00 to 18:00, Sydney time) |
| 4 | Warm-up run | Do scene 4 once | All three stages green |
| 5 | Deep-dive run (if you'll show scenes 6 to 10) | Scene 4, but also tick **Include deep-dive variants (ACI --once, MDP agent reuse, WIF deployment) - adds several minutes** | Six stages green, about 10 minutes |
| 6 | Auditing is on (scene 10) | **Organization settings** > **Policies** > **Log audit events** | **On**, and **Auditing** appears under **General** |
| 7 | Open tabs | One tab per scene, from `DEMO-LINKS.local.md` | |

Outside the standby window, the first MDP job waits a few minutes for a machine. Show the warm-up run instead.

**Don't click:** **Connect** on the ACI container (it opens a shell), **Apply** on any MDP settings blade, or edit the pool names in the run panel.

## Scene 1: two pools, one pipeline (Azure DevOps, 2 minutes)

1. Open **Organization settings** (bottom left) > **Pipelines** > **Agent pools**. Point out `aci-selfhosted-demo` and `mdp-security-demo`.
2. Select `aci-selfhosted-demo` > **Agents** tab. `aci-agent-1` is **Online** and **Idle**.
   > "This agent is a container built from Microsoft's documented Dockerfile. It registered itself with a personal access token (PAT)."
3. Go back and select `mdp-security-demo`. Its tabs are **Jobs**, **Details**, **Security** and **Analytics**: there is no **Agents** tab. **Jobs** shows waits of under a minute.
   > "No PAT here. Managed DevOps Pools registers and manages the agents for us."
4. Open project `mdp-vs-aci-security` > **Project settings** > **Pipelines** > **Agent pools**. Both pools are available to this project only.

## Scene 2: the ACI agent in Azure (Azure portal, 2 minutes)

1. Open resource group `rg-mdp-vs-aci-security` > `aci-azp-agent`.
2. **Settings** > **Containers**. With `azp-agent` selected, open the **Properties** tab (next to **Events**) and scroll to **Environment variables**: `AZP_URL`, `AZP_POOL`, `AZP_AGENT_NAME` and `AZP_TOKEN`, whose value is blank.
   > "Azure hides the PAT here because it's a secure value. Let's see what a pipeline job can see."
3. **Settings** > **Identity** > **User assigned** tab: `id-aci-acrpull-…`, attached only so ACI can pull the image.
4. **Settings** > **Properties**: **IP address** is `-` (no inbound endpoint), and **Restart policy** is **Always** (a persistent agent).

## Scene 3: the MDP pool in Azure (Azure portal, 2 minutes)

1. Open `mdp-security-demo` > **Overview**: **Agent state: Stateless**, **Maximum agents: 2**, and the **Pool Usage** chart.
2. **Settings** > **Scaling**: **Agent state: Fresh agent every time**. **Standby agent mode: Manual**, **Weekday Scheme**, **(UTC+10:00) Canberra, Melbourne, Sydney**, 08:00 to 18:00, count 1.
3. **Settings** > **Security**: **Add pool to all projects: No** (only `mdp-vs-aci-security`). **Use pool in multiple organizations** and **Enable Interactive Mode** are off.
4. **Settings** > **Agents**: the standby machine, image `mmsubuntu24.04-g2`, **Status: Ready**.
   > "Microsoft maintains this image. After each job, MDP reimages the machine, or removes it when standby is off."

## Scene 4: run the probe (Azure DevOps, 1 minute, then about 4 minutes of running)

1. Project `mdp-vs-aci-security` > **Pipelines** > `security-probe` > **Run pipeline** (top right).
2. Under **Parameters**, tick **Proof of impact - make one read-only API call with any registration token a job finds**. Leave both pool names as they are.
3. Select **Next: Resources**; the panel has two pages. Then select **Run**.
4. The run shows three stages: **ACI self-hosted agent**, **Managed DevOps Pool** and **Compare findings**.
   > "Each pool runs the same read-only probe twice. It shows names and yes/no results, never secret values. With one free self-hosted parallel job, the jobs run one at a time."

## Scene 5: read the results (Azure DevOps, 3 minutes)

1. When all three stages are green, select the **Extensions** tab on the run's summary page.
2. The first section, **MDP vs ACI: what can a pipeline job reach?**, compares two jobs on each pool. Walk the red rows:
   - **Registration token readable on disk**, and **Registration secret in a process environment** (ACI): every job can read the agent's PAT, in `/azp/.token` and in the `start.sh` environment. `unset` stops child processes inheriting it, but `start.sh` keeps it.
   - **Registration token usable from the job** (ACI): with *Proof of impact*, a job used that PAT for one read-only call that listed the organisation's agent pools. A stolen PAT could register an attacker-controlled agent into pools that receive other teams' jobs. *(Our analysis; the demo changes nothing.)*
   - **Residue from an earlier job** (ACI): job 1 found a file left by the previous run, and job 2 found job 1's file.
   - **Azure managed identity token obtainable** (ACI): the identity attached only for image pulls issued a token to the job.
   - **Machine (hostname, boot ID)**: both ACI jobs used the same container. On MDP, the machine name can repeat, but the boot ID changes and no residue is found: the machine was reimaged between jobs.
   - Info rows: MDP jobs have root (passwordless sudo) on a machine that holds no reusable secret and is reimaged or removed after one job.
3. Further down, each job has its own section with the same checks.

## Close (1 minute)

> "Container agents on ACI or AKS put an organisation-level registration credential, and any attached identity, within reach of every job. Managed DevOps Pools removes the credential and gives every job a fresh agent from a Microsoft-maintained image. Recommendation: MDP with **Fresh agent every time**, no identities on agents, and workload identity federation service connections for deployments."

AKS: the same agent design, analysed but not measured (see the README).

## Deep dive (optional, about 10 minutes)

Show the deep-dive run from the checklist (item 5) rather than running it live. Its **Extensions** tab adds ACI-ONCE and MDP-STATEFUL columns and a WIF section.

### Scene 6: "Can't we just make ACI ephemeral?" (2 minutes)

1. Azure portal: `aci-azp-agent-once` > **Settings** > **Containers**: a **Restart events detected** banner, and **Restart count** goes up by one after each job. The **Properties** tab shows **Commands** `[ "/azp/start.sh", "--once" ]`. On the **Events** tab, the **Killing** and **Started** counts grow with each job.
2. Deep-dive run > **Extensions**, ACI-ONCE columns: **Residue from an earlier job** is 🟢 no, because each restart gives a fresh container. The registration token is still 🔴 on disk, 🔴 in the `start.sh` environment and 🔴 usable, and the Azure identity still answers (🔴).
   > "`--once` fixes leftover files, not the credential. And the PAT must stay valid, because the agent re-registers with it after every job; you'll see that in the audit log."

### Scene 7: "MDP is only as safe as its settings" (2 minutes)

1. Azure portal: `mdp-stateful-demo` > **Settings** > **Scaling**: **Agent state: Same agent can be reused by multiple builds**, **Standby agent mode: Off**, **Max time to live** `1.00:00:00`, **Grace period** `00:30:00`.
2. **Extensions**, MDP-STATEFUL columns: both jobs show the same machine **and** the same boot ID, and job 2 finds job 1's file (🔴).
3. Azure portal: resource group `rg-mdp-vs-aci-security` > **Settings** > **Policies** (opens **Policy | Compliance** for this resource group). The demo's two rows start with **Managed DevOps Pools should**; the other rows are the tenant's own assignments.
   - **Managed DevOps Pools should give every job a fresh agent**: **Non-compliant**, **50% (1 out of 2)**: `mdp-stateful-demo` is flagged.
   - **Managed DevOps Pools should run in your own virtual network**: **Non-compliant**, **0% (0 out of 2)**: VNet injection isn't possible in this subscription.
   > "Make **Fresh agent every time** and private networking a policy, not a convention. Start with Audit, then switch to Deny."

### Scene 8: "Only approved pipelines can use a pool" (2 minutes)

1. Azure DevOps: **Pipelines** > `unapproved-pipeline` > **Run pipeline** > **Run**.
2. The run shows **This pipeline needs permission to access a resource before this run can continue**, and the stage shows **Waiting** and **Permission needed**. Select **View**: **Waiting for review** lists **Permission**, **Agent pool** `mdp-security-demo`, with a **Permit** button. **Don't select Permit.** Close the panel and cancel the run.
3. **Project settings** > **Agent pools** > `mdp-security-demo` > **Security** tab: **Pipeline permissions** lists only `security-probe`. Point out the page's own note: "All Classic pipelines can use this resource."
   > "Restrict production pools to named pipelines, add **Approvals and checks**, and disable classic pipelines: they aren't covered by this list."

### Scene 9: "Deploy without secrets" (2 minutes)

1. **Project settings** > **Service connections** > `sc-wif-demo`: **Azure Resource Manager using workload identity federation with openid connect**, with the **Issuer** and **Subject identifier**. Tabs: **Usage history** and **Approvals and checks**.
2. Deep-dive run > **Extensions** > **Deploying the recommended way: WIF service connection on MDP**: signed in via workload identity federation with no secret; read the resource group; allowed actions `*/read` only; no Azure identity outside the task.
   > "The token exists only inside the task that names this connection, for pipelines we allow. Compare ACI, where the attached identity answered every job."

### Scene 10: "Detect it" (1 minute)

1. **Organization settings** > **General** > **Auditing** > **Logs**: **Added agent aci-once-1 to pool aci-once-demo.** and **Removed agent aci-once-1 from pool aci-once-demo.** after every ACI `--once` job. The **Actor** is the PAT owner, with the container's IP address. Also **Service Connection "sc-wif-demo" of type AzureRM executed in project mdp-vs-aci-security.**
2. **Streams** tab: send the log to Azure Monitor or Microsoft Sentinel; Azure DevOps keeps it for 90 days.
   > "A stolen registration PAT shows up as an unexpected **Added agent**. Alert on it for production pools."

## If something goes wrong

| Symptom | Do this |
|---------|---------|
| The run panel shows **Next: Resources** instead of **Run** | Expected: select **Next: Resources**, then **Run**. |
| "This pipeline needs permission to access a resource" | Select **Permit**, or re-run `./scripts/deploy.ps1`, which authorises the pipeline on both pools. |
| `aci-agent-1` is offline | `az container restart -g rg-mdp-vs-aci-security -n aci-azp-agent`, then wait about 2 minutes. After the PAT expires (7 days), run `./scripts/deploy.ps1 ... -RotateAciToken`. |
| The MDP stage waits more than 5 minutes | Probably outside the standby window. Open the warm-up run from `DEMO-LINKS.local.md`. |
| MDP shows agents as offline in Azure DevOps | Expected between jobs. Check **Settings** > **Agents** in the Azure portal instead. |
| The deep-dive MDP-STATEFUL stage waits a few minutes | Expected: that pool has no standby agent, so its first job waits for a machine. |
| **Auditing** is missing from Organization settings | **Organization settings** > **Policies** > **Log audit events** > **On**. |
| Policy compliance shows no results | Results can take up to 30 minutes after assignment. Run `az policy state trigger-scan -g rg-mdp-vs-aci-security`. |
| An `unapproved-pipeline` run is still waiting | Cancel it. It never runs unless someone selects **Permit**. If someone did, re-run `deploy.ps1`; it removes that permission. |

## After the demo

Run `./scripts/teardown.ps1 -DeleteProject`. It deletes the policy baseline and the resource group, revokes both ACI PATs, and removes the ACI agent pools and the project (with its pipelines and service connection). It doesn't turn **Log audit events** off.
