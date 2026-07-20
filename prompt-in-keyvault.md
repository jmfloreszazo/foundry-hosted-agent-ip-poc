# Why keep the system prompt in Key Vault (with a Hosted Agent)?

A reasonable question: if you already have private ACR + signed image + isolated
sandbox, why not just bake the system prompt into an `appsettings.json` inside
the container? The bytes would be "protected" too.

The answer is that the difference is not **where the bit physically lives** — it
is **who controls it, on what lifecycle, and with what blast radius**.

## What Key Vault buys you vs. baking the prompt into the image

### 1. Decouples the prompt lifecycle from the code lifecycle

Prompts iterate roughly 10× faster than binaries. If the prompt lives in the
image, every wording tweak becomes: rebuild → sign → push to ACR → verify → new
Hosted Agent version. With Key Vault: `az keyvault secret set` + recycle the
session, done. No pipeline run, no new digest, no invalidated provenance.

### 2. Separation of roles (prompt engineer ≠ developer)

The people refining the prompt (product / domain / prompt engineer) do not need
— and should not have — permissions to push code or images. With Key Vault you
grant them `Key Vault Secrets Officer` on *that specific secret* and nothing
else. With the prompt in the image, they would need to touch code.

### 3. Blast radius if the image ever leaks

This is the one that gets overlooked. A compiled binary is **not opaque**:
`docker save`, `strings agent.dll`, or a .NET decompiler (ILSpy, dnSpy) will
extract embedded literals — including any packaged `appsettings.json` — in
seconds. Signing the image protects **integrity** (nobody tampered with it), not
**confidentiality** (if they steal it, they can read it).

With the prompt in Key Vault, an attacker who exfiltrates the image walks away
with the orchestration but not with the business rules, few-shots, or personas.
Those are resolved at runtime against the vault, using the agent's managed
identity. That is real defense in depth, not ceremony.

### 4. Real rotation and revocation

If a prompt leaks (a demo screenshot, a misconfigured log), you rotate the
secret in Key Vault: a new version becomes current, the old one is no longer
served, and the audit log records the change. In the image you have to rebuild,
republish, and confirm that no sandbox is still running the old container.

### 5. Line-grain audit (versioning and access)

Key Vault gives you native versioning of the secret, tags of who updated it and
when, and access logs of every `GET` (which identity read it, how often).
`git blame` on a JSON in the repo tells you who wrote it, not who **read** it or
how many times.

### 6. Same binary, different behavior per environment / tenant

One signed digest running in dev, staging, and prod — each one reads a different
prompt from its corresponding Key Vault. In a multi-tenant setup, each tenant
gets its own prompt without duplicating images. If the prompt lives in the
image, you end up with N signed images for the same code, which breaks the
"one artifact = one verified version" model.

### 7. Compliance / auditable narrative

When the auditor shows up, "secrets and sensitive configuration are in Key Vault
with managed identity and RBAC" is a checkbox that ticks itself. "They are
inside the signed binary" forces you to defend equivalence case by case.

## What Key Vault does NOT buy you (so nobody oversells it)

- **It does not protect against a compromised sandbox.** Once the agent reads
  the secret, the prompt lives in process memory. If an attacker gets code
  execution *inside* the sandbox, they can read it. Key Vault controls *access
  to the secret*, not *process memory*.
- **It does not stop the model from reciting it.** If the model is jailbroken
  into vomiting the system prompt, Key Vault will not save you. That is what
  [`Opacity.cs`](src/AgentCSharp/Opacity.cs), [`Guardrails.cs`](src/AgentCSharp/Guardrails.cs),
  and the directives in [prompt-opacity-directives.md](prompt-opacity-directives.md)
  are for. Three layers for the same problem.
- **It does not make anything faster.** Each cold start adds a Key Vault call
  (mitigable with an in-memory cache). It is an acceptable cost, not a free
  one.

## One-line summary

Baking the prompt into the image protects **integrity**. Putting it in Key Vault
additionally protects **confidentiality, lifecycle, roles, and audit** — and
decouples prompt iteration from the release pipeline. For a Hosted Agent whose
IP **is** the behavior (prompt + rules + orchestration), that separation is
exactly where the value lives.
