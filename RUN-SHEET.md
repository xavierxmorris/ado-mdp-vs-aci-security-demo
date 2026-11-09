# Demo script: MDP vs ACI, click by click (about 12 minutes)

Every click below was rehearsed in a browser on 9 November 2026, including starting the pipeline from the UI. That run took 3 minutes 39 seconds.

**Get your exact links first:** run `./scripts/demo-links.ps1`. It writes `DEMO-LINKS.local.md` (git-ignored) with a direct link for each scene.

## Before the demo (15 minutes before)

| # | Check | Where | Expected |
|---|-------|-------|----------|
| 1 | Sign in once | One browser profile: `dev.azure.com` and `portal.azure.com` with the demo account. If **Pick an account** appears, choose the demo account, not an administrator or corporate account. | Both open without prompts |
| 2 | ACI agent is online | Azure DevOps: **Organization settings** > **Agent pools** > `aci-selfhosted-demo` > **Agents** | `aci-agent-1`, **Online**, **Idle** |
| 3 | MDP standby is ready | Azure portal: `mdp-security-demo` > **Settings** > **Agents** | One machine, **Status: Ready** (weekdays 08:00 to 18:00, Sydney time) |
| 4 | Warm-up run | Do scene 4 once | All three stages green |
| 5 | Open tabs | One tab per scene, from `DEMO-LINKS.local.md` | |

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

## If something goes wrong

| Symptom | Do this |
|---------|---------|
| The run panel shows **Next: Resources** instead of **Run** | Expected: select **Next: Resources**, then **Run**. |
| "This pipeline needs permission to access a resource" | Select **Permit**, or re-run `./scripts/deploy.ps1`, which authorises the pipeline on both pools. |
| `aci-agent-1` is offline | `az container restart -g rg-mdp-vs-aci-security -n aci-azp-agent`, then wait about 2 minutes. After the PAT expires (7 days), run `./scripts/deploy.ps1 ... -RotateAciToken`. |
| The MDP stage waits more than 5 minutes | Probably outside the standby window. Open the warm-up run from `DEMO-LINKS.local.md`. |
| MDP shows agents as offline in Azure DevOps | Expected between jobs. Check **Settings** > **Agents** in the Azure portal instead. |

## After the demo

Run `./scripts/teardown.ps1 -DeleteProject`. It deletes the resource group, revokes the PAT, and removes the ACI agent pool and the project.
