# Run sheet: MDP vs ACI security demo (about 10 minutes)

## Before the meeting

1. Deploy (`./scripts/deploy.ps1 ...`) and check that `aci-selfhosted-demo` shows one **online** agent.
2. Run the probe once (`./scripts/run-probe.ps1 -ProofOfImpact`) so a completed run is ready if live provisioning is slow.
   With one standby MDP agent and the free tier's single self-hosted parallel job, a full run took about 4 minutes.
3. Open these tabs:
   - Azure DevOps > Organization settings > Agent pools (both pools).
   - The completed `security-probe` run > **Extensions** tab (the comparison table).
   - Azure portal > resource group `rg-mdp-vs-aci-security`.

## Talk track

| Minute | Show | Say |
|--------|------|-----|
| 0-1 | Agent pools page | "Two self-hosted options for the same pipeline: Microsoft's documented container agent on ACI, and a Managed DevOps Pool. Both are private to one project, and only this pipeline is authorised." |
| 1-3 | Azure portal: container group, then the MDP pool | "ACI is a container that we build and patch. It registers with a PAT that has Agent Pools read & manage. MDP is an Azure resource: stateless agents, a Microsoft-maintained image, and a standby schedule. No PAT anywhere." |
| 3-4 | Queue `security-probe` with **Proof of impact** ticked | "Each pool runs the same read-only probe twice. It prints names and yes/no results, never secret values." |
| 4-8 | The completed run's **Extensions** tab | Walk the red rows top to bottom (next section). |
| 8-10 | README "Why the results differ" | Map each finding to the recommendation: MDP, ephemeral agents, no identities on agents, WIF service connections. Then cover the AKS column (analysis, not measured): same image and PAT as ACI, plus a Kubernetes secret, pod access to the node's identity through IMDS by default, and outbound access you must design. |

## Reading the table

- **Registration token readable on disk (ACI)**: any job, from any pipeline allowed to use the pool, can read the agent's PAT in `/azp/.token`.
- **Registration secret in a process environment (ACI)**: ACI's `secureValue` hides the PAT from the Azure control plane only. `start.sh` runs `unset AZP_TOKEN`, which stops child processes inheriting it, but `start.sh`'s own environment still holds it.
- **Registration token usable from the job (ACI)**: with *Proof of impact*, the job used that PAT for one read-only call that listed the organisation's agent pools. The same token could register an attacker-controlled agent into pools that receive other teams' jobs. *(Our analysis; the demo makes no changes.)*
- **Residue from an earlier job (ACI)**: job 1 found a file left by the previous run, and job 2 found job 1's file. With a persistent agent, one pipeline can tamper with the next pipeline's environment.
- **Machine (ACI vs MDP)**: both ACI jobs ran in the same container. Both MDP jobs reported agent name `mdp-security-demo 1`, but different hostnames and boot IDs: a new VM per job.
- **Azure managed identity (ACI)**: the identity attached only for image pulls issued a token to the job.
- **Info rows**: on MDP, the job has root (passwordless sudo) on a VM that holds no reusable secret and is discarded after one job. That is the security model: assume the job controls the machine, and make the machine disposable.

## If something goes wrong

| Symptom | Fix |
|---------|-----|
| ACI agent offline | `az container logs -g rg-mdp-vs-aci-security -n aci-azp-agent`; then `./scripts/deploy.ps1 ... -RotateAciToken`. |
| MDP job waits a long time | Expected without a standby agent: MDP creates a VM per job. Show the pre-run instead. |
| "This pipeline needs permission to access a resource" | Re-run `deploy.ps1`; it authorises the pipeline on both pools. |

## Afterwards

Run `./scripts/teardown.ps1 -DeleteProject`. It deletes the resource group, revokes the PAT, and removes the ACI pool and the project.
