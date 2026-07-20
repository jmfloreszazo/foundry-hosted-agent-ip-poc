# Foundry Hosted Agent — IP Protection PoC

> **Scope note.** This repository is deliberately narrow: it shows **one piece**
> of a larger puzzle — how to protect the IP of an AI agent at the *hosting*
> and *endpoint* layer (private ACR, signed image, VM-isolated sandbox, Key
> Vault, opaque response). A production deployment does **not** stop here.
> Sitting in front of and around this PoC you should expect the usual
> enterprise perimeter: reverse proxies, WAF, DDoS protection, an API gateway
> (Azure API Management or equivalent) fronting the Foundry endpoint with
> authentication, quotas, rate limiting, request/response transformation and
> content-safety policies, egress firewalls and forced tunneling, private DNS
> zones and hub-and-spoke networking, Defender for Cloud / Sentinel for
> detection, and a proper SDLC (SAST, SCA, secret scanning, dependency
> updates) around the pipeline shown in [.github/workflows/deploy.yml](.github/workflows/deploy.yml).
> Treat what follows as the **agent-hosting brick**, not the whole wall.

This repository is a Proof of Concept that shows how to deploy a **containerized AI
agent** as an Azure AI Foundry **Hosted Agent**, in a way that keeps the agent's
logic (its IP) inside your Azure tenant:

- The agent binary lives in a **private Azure Container Registry** (no public
  network access, reachable only via private endpoint).
- The image is **signed** on build and **verified** before deploy, so only images
  produced by your pipeline can run.
- The agent runs in a **VM-isolated sandbox** managed by Foundry, with a dedicated
  Entra ID identity and least-privilege RBAC.
- The **system prompt** (the sensitive part of the behavior) lives in **Key Vault**,
  not in the repo, and is read at runtime by the agent's managed identity.
- The agent exposes an **opaque endpoint** (uniform refusals, normalized latency,
  no leakage of internal reasoning), so clients cannot fingerprint or extract the
  underlying configuration.

The rest of this document explains the architecture, the pieces in the repo, and
how to run it end-to-end.

> **Extension — C# vs Python benchmark.** The same agent is ported to
> Python 3.12 (using the official `azure-ai-agentserver-responses` SDK) as
> `ippoc-agentpython`, sibling of the reference `ippoc-agentcsharp` (.NET 10
> using `Azure.AI.AgentServer.Responses`). Both agents share the same
> Microsoft server SDK family, so the comparison isolates language runtime
> and SDK implementation rather than framework choice. They are deployed
> side by side in the same Foundry project, and a neutral benchmark harness
> measures p50 / p95 / p99 latency, throughput and tokens over N calls. See
> **[benchmark.md](benchmark.md)** for methodology, how to run it, and the
> results table.
---

## Architecture

```
                +---------------------------------------------------+
                |                    Azure tenant                   |
                |                                                   |
   Client ----->|  Foundry Project endpoint  (public HTTPS)         |
                |          |                                        |
                |          v                                        |
                |  Hosted Agent sandbox (VM-isolated, dedicated MI) |
                |          |     ^                                  |
                |          |     |  pulls signed image (private EP) |
                |          |     +----------------+                 |
                |          |                      |                 |
                |          v                      |                 |
                |  Model deployment (gpt-4.1)     |                 |
                |          ^                      |                 |
                |          |                      |                 |
                |   +------+------+        +------+-------+         |
                |   |  Key Vault  |        |  Private ACR |         |
                |   | system prompt|        |  (agent img) |         |
                |   +-------------+        +--------------+         |
                |                                                   |
                |   App Insights  <----  traces / tool calls        |
                +---------------------------------------------------+
```

Two boundaries protect the IP:

1. **Infrastructure boundary.** The image never leaves the tenant: private ACR +
   private endpoint, VM-isolated sandbox, dedicated managed identity, Key Vault
   for the prompt. The client never reaches Azure resources directly.
2. **Endpoint boundary.** The agent's response handler enforces *opacity*: a
   single style of refusal, no reasoning traces, no metadata, normalized timing.
   A network capture (e.g. Fiddler on the client) only sees the opaque HTTPS
   response — never the source code, the prompt, or the model↔agent traffic
   (which is server-to-server inside Azure).

---

## Repository layout

```
azure.yaml                     azd config: ai.agent service, protocols, sign/verify hooks
prompt-opacity-directives.md   Text to append to the Key Vault system prompt
                               (reinforces opaque behavior at prompt level)
infra/
  main.bicep                   Composes all modules
  main.bicepparam              Parameter values (name prefix, model, principalId)
  modules/
    network.bicep              VNet + subnets + private DNS zones
    registry.bicep             Premium ACR, public access disabled, private endpoint
    foundry.bicep              Foundry account + project + model deployment
    keyvault.bicep             Key Vault + RBAC for the agent identity
    observability.bicep        Log Analytics + Application Insights
src/AgentCSharp/                 Reference agent — C# on .NET 10
  Program.cs                   Hosted Agent bootstrap (Responses adapter)
  ProtectedResponseHandler.cs  The IP: your business logic + prompt loading
  Guardrails.cs                Input/output filters (PII, jailbreak, secrets)
  KeyVaultPromptStore.cs       Loads the system prompt from Key Vault at startup
  Opacity.cs                   Uniform refusals + normalized latency
  Dockerfile                   Deterministic build, linux/amd64, non-root user
src/AgentPython/                 Same agent — Python 3.12 on the official
                               azure-ai-agentserver-responses SDK
  main.py                      SDK bootstrap: ResponsesAgentServerHost + @app.response_handler
  protected_response_handler.py  Handler port with same Phase-A canned response
  guardrails.py                Regex-identical port of Guardrails.cs
  key_vault_prompt_store.py    Prompt loader (azure-identity + azure-keyvault-secrets)
  opacity.py                   Uniform refusals + normalized latency (asyncio)
  requirements.txt             Pinned deps (azure-ai-agentserver-responses 1.0.0b8, ...)
  Dockerfile                   Multi-stage, python:3.12-slim, non-root user
src/ippoc-agentcsharp/           azd hosted-agent manifest for the C# service
src/ippoc-agentpython/           azd hosted-agent manifest for the Python service
scripts/
  sign-image.sh                Signs the image after `azd package` (postpackage hook)
  verify-image.sh              Verifies signature before deploy (predeploy hook)
  invoke.ps1                   One-shot POST to /responses with AAD token
  benchmark.ps1                N-call latency/throughput bench, C# vs Python
benchmark.md                     Methodology + results for the C# vs Python bench
```

The two files whose purpose is often unclear:

- [prompt-opacity-directives.md](prompt-opacity-directives.md) — **not deployed as code**.
  It contains the behavioral rules you should paste into the Key Vault secret
  `agent-system-prompt`. They tell the model to refuse uniformly, not to reveal
  its configuration, and not to leak reasoning. It is the *prompt-level* half of
  the opacity that `Opacity.cs` / `Guardrails.cs` enforce at *code* level. Think
  of it as defense-in-depth: even if code fails, the model has been told not to
  leak; even if the model is jailbroken into reciting the rules, the output
  guardrail cuts them off.
- [prompt-in-keyvault.md](prompt-in-keyvault.md) — explains **why** the system
  prompt lives in Key Vault instead of baked into the container image, even
  though the image is already in a private ACR and signed. Covers lifecycle
  decoupling, role separation, blast radius if the image leaks, rotation, audit,
  and what Key Vault does **not** protect against.
- `Guardrails.cs` / `Opacity.cs` — the *code-level* half of the opacity idea:
  a single refusal shape, normalized response latency, stripped metadata.

---

## Prerequisites

- Azure subscription with permission to create resources in the target region.
- A region where Foundry Hosted Agents are available.
- Foundry project created **after 25 June 2026** (required for private ACR with
  private endpoint; earlier projects only support public-endpoint registries).
- Tools installed locally:
  - Azure CLI (`az`)
  - Azure Developer CLI (`azd`)
  - Docker (with `linux/amd64` build capability)
  - Either **notation** + Azure Trusted Signing, **or** **cosign** (for keyless
    Sigstore signing)
- Your user or service principal must have `Owner` (or equivalent) on the target
  resource group so the Bicep can assign RBAC roles.

---

## Step-by-step: run the PoC

### 1. Clone and log in

```bash
git clone <this-repo>
cd foundry-hosted-agent-ip-poc

az login
azd auth login
```

### 2. Configure the environment

Create a new azd environment and set the target subscription and region:

```bash
azd env new ippoc-dev
azd env set AZURE_LOCATION <region-with-hosted-agents>   # e.g. eastus2
```

Edit `infra/main.bicepparam` and set `deployerPrincipalId` to your user or CI
service principal object id (this grants `AcrPush` and Foundry project access):

```bash
# Your own user:
az ad signed-in-user show --query id -o tsv

# A service principal by appId:
az ad sp show --id <appId> --query id -o tsv
```

### 3. Provision the infrastructure

```bash
azd provision
```

This deploys, in order: VNet + private DNS, private ACR, Log Analytics +
Application Insights, Foundry account + project + model deployment, Key Vault +
RBAC. Outputs used later (`ACR_LOGIN_SERVER`, `FOUNDRY_PROJECT_ENDPOINT`,
`KEY_VAULT_URI`, ...) are stored in the azd environment.

### 4. Upload the system prompt to Key Vault

The prompt is **not** in the repo. Write your proprietary system prompt to a local
file (and append the directives from `prompt-opacity-directives.md` at the end),
then upload it:

```bash
KV_NAME=$(azd env get-values | grep KEY_VAULT_URI | sed 's|.*https://\([^\.]*\)\..*|\1|')

az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name agent-system-prompt \
  --file ./prompt.txt
```

The agent's managed identity reads this secret at runtime; the value never enters
the repo, the image, or the container's environment variables. For the rationale
behind keeping the prompt in Key Vault rather than in the image, see
[prompt-in-keyvault.md](prompt-in-keyvault.md).

### 5. Package the agent (build + sign)

```bash
# Configure signing mode (choose one):
export SIGNING_MODE=trusted
export TRUSTED_SIGNING_CERT_PROFILE_ID=<your-trusted-signing-profile-id>
# --- OR ---
export SIGNING_MODE=cosign

azd package
```

`azd package` builds the deterministic `linux/amd64` image, pushes it to the
private ACR, and then the `postpackage` hook runs `scripts/sign-image.sh` to sign
the resulting digest.

### 6. Deploy the agent (verify + publish)

```bash
azd deploy
```

The `predeploy` hook runs `scripts/verify-image.sh`. If the signature is missing
or does not match the expected identity, **the deploy aborts**. If verification
passes, azd registers a new version of the Hosted Agent against the Foundry
project.

### 7. Invoke the agent

Get the project endpoint and call the agent using any Responses-API–compatible
client (or the Foundry portal / SDK):

```bash
azd env get-values | grep FOUNDRY_PROJECT_ENDPOINT
```

You can also observe traces (tool calls, latency, refusals) in the Application
Insights resource created by `observability.bicep`.

### 8. Tear down

```bash
azd down --purge
```

`--purge` also purges the Key Vault soft-delete so the name can be reused.

---

## CI/CD: run the pipeline in GitHub Actions

The workflow at [.github/workflows/deploy.yml](.github/workflows/deploy.yml) does
the same as the manual steps above (`provision` → `package` (sign) → `deploy`
(verify)) but from GitHub Actions, with no long-lived Azure secrets: it uses
**OIDC federation** to log in to Azure and **cosign keyless** (Sigstore + OIDC)
to sign the image.

Follow these steps to make the pipeline run green.

### 1. Create the App Registration + service principal

In your Azure tenant, create an Entra ID application that will represent the
pipeline:

```bash
az ad app create --display-name "gh-foundry-hosted-agent-ip-poc"
APP_ID=$(az ad app list --display-name "gh-foundry-hosted-agent-ip-poc" --query "[0].appId" -o tsv)
az ad sp create --id "$APP_ID"
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
```

### 2. Grant the SP the roles it needs on the resource group

The Bicep creates role assignments (AcrPush for the SP, Foundry project roles,
Key Vault access for the agent MI). Because it *assigns roles*, the pipeline
principal needs both **Contributor** and **User Access Administrator** on the
target resource group (or Owner, which combines the two):

```bash
RG=<your-resource-group>
az group create -n "$RG" -l <region-with-hosted-agents>

az role assignment create --assignee "$APP_ID" --role "Contributor"                --scope "/subscriptions/<sub-id>/resourceGroups/$RG"
az role assignment create --assignee "$APP_ID" --role "User Access Administrator"  --scope "/subscriptions/<sub-id>/resourceGroups/$RG"
```

### 3. Configure federated credentials (OIDC)

This is what lets GitHub Actions get an Azure token without a client secret. Add
one credential per branch/trigger you want to allow. For the current pipeline
(pushes to `main` + `workflow_dispatch`), two are enough:

```bash
REPO=<owner>/<repo>   # e.g. jmfloreszazo/foundry-hosted-agent-ip-poc

# For pushes to the main branch
az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"gh-main\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:$REPO:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"

# For manual workflow_dispatch runs from any branch
az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"gh-dispatch\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:$REPO:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```

If you want to run the pipeline from a pull request or another branch, add a
credential with `subject` set to `repo:<owner>/<repo>:pull_request` or
`repo:<owner>/<repo>:ref:refs/heads/<branch>` accordingly.

### 4. Add GitHub repository secrets and variables

In the GitHub repository, go to **Settings → Secrets and variables → Actions**
and add:

**Repository secrets** (`Settings → Secrets and variables → Actions → Secrets`):

| Name                    | Value                                       |
| ----------------------- | ------------------------------------------- |
| `AZURE_CLIENT_ID`       | `$APP_ID` from step 1 (the SP's appId)      |
| `AZURE_TENANT_ID`       | Your Entra tenant id (`az account show --query tenantId -o tsv`) |
| `AZURE_SUBSCRIPTION_ID` | Target subscription id                      |

**Repository variables** (`Settings → Secrets and variables → Actions → Variables`):

| Name              | Value                                          |
| ----------------- | ---------------------------------------------- |
| `AZURE_ENV_NAME`  | Any short name for the azd environment, e.g. `ippoc-ci` |
| `AZURE_LOCATION`  | A region with Hosted Agents, e.g. `eastus2`    |

The pipeline reads secrets for auth (they are masked in logs) and variables for
non-sensitive config (env name, region).

### 5. Push and watch the pipeline

Push to `main` (or run the workflow manually from the **Actions** tab). The
pipeline will:

1. Log in to Azure via OIDC (no client secret exchanged).
2. Resolve the SP's object id and expose it as the `deployerPrincipalId` Bicep
   param, so the infra grants roles to the right principal.
3. Create/select the azd environment on the runner.
4. Run `azd provision` → `azd package` (which signs the image with cosign
   keyless, using the runner's OIDC token) → `azd deploy` (which first verifies
   the signature was issued by *this* repo before publishing the new agent
   version to Foundry).

If verification fails (missing signature, wrong identity, wrong issuer), the
`predeploy` hook aborts and no new agent version is published.

### 6. One thing the pipeline does NOT do

**It does not upload the system prompt to Key Vault.** The prompt is the
sensitive part of the behavior and it is deliberately out of band from CI. After
the first `azd provision` in the pipeline succeeds, follow step 4 of the manual
guide once (from your machine) to seed `agent-system-prompt` in Key Vault. From
then on the pipeline can redeploy the agent freely: the prompt stays in Key
Vault, read at runtime by the agent's managed identity.

---

## Notes and assumptions

- Hosted Agents APIs and the `Azure.AI.AgentServer.*` packages are in preview.
  Pin versions against `microsoft-foundry/foundry-samples` before taking this
  beyond a PoC.
- The private ACR with private endpoint requires a Foundry project created after
  25 June 2026. Older projects need the registry via public endpoint.
- Choose a region where Hosted Agents are available.
- The signing scripts support two modes (Azure Trusted Signing via `notation`, or
  keyless `cosign` via Sigstore + OIDC). Pick the one that fits your CI.

---

## Further reading

- [prompt-in-keyvault.md](prompt-in-keyvault.md) — Why the system prompt lives
  in Key Vault instead of being baked into the signed container image. Covers
  lifecycle decoupling, role separation, blast radius if the image leaks,
  rotation, audit, and what Key Vault does not protect against.
- [prompt-opacity-directives.md](prompt-opacity-directives.md) — Behavioral
  rules to append to the `agent-system-prompt` secret so the model refuses
  uniformly and never reveals its own configuration. Complements the code-level
  opacity in `src/AgentCSharp/Opacity.cs` and `src/AgentCSharp/Guardrails.cs`.

