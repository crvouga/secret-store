# Prompt: Migrate a project from Doppler to self-hosted OpenBao/Vault

Copy everything below the line into your coding agent, running it **inside the
project repo you want to migrate**.

---

You are migrating this project off **Doppler** and onto a **self-hosted
OpenBao/Vault** instance. Doppler is being decommissioned; this repo must read
its secrets from the self-hosted store instead.

## Fixed coordinates for this setup

- Doppler project: always **`personal`**
- Doppler configs / environments: **`dev`** and **`prd`** (only these two)
- Store paths: `secret/personal/dev` and `secret/personal/prd`
- Default config for this repo: `dev` (use `prd` for production commands)

Use these values directly — do not ask me for the project or config names.

## Facts about the target store (do not change these)

- Vault/OpenBao API address: `https://secret-store.chrisvouga.dev`
- Secrets engine: **KV v2**, mounted at `secret/`
- Path convention: `secret/<project>/<config>` → here `secret/personal/dev`
  and `secret/personal/prd`
  - Each Doppler key is a **field** on that secret; reserved `DOPPLER_*` keys
    are not migrated
- The store ships a Doppler-style CLI wrapper (from the `secret-store` repo)
  that adds two subcommands on top of the real `vault`/`bao` binary:
  - `vault setup --project <p> --config <c>` → writes `.vault.yaml`
  - `vault run -- <command>` → injects the secret's fields as env vars, then
    runs `<command>`
  - All other `vault` subcommands pass through to the real binary

## Doppler → this setup mapping

| Doppler                       | This setup                                  |
| ----------------------------- | ------------------------------------------- |
| `doppler login`               | `vault login hvs.xxx` (or a scoped dev token) |
| `doppler setup`               | `vault setup --project personal --config dev` |
| `doppler run -- <cmd>`        | `vault run -- <cmd>`                         |
| `doppler.yaml`                | `.vault.yaml`                                |
| `DOPPLER_TOKEN` (CI)          | GitHub Actions OIDC (no stored token) — see step 6 |

## Goal

**Completely remove Doppler and fully replace it with the self-hosted Vault.**
After migration the project must fetch all secrets from `secret/personal/<config>`
via `vault run`, and there must be **zero** remaining references to Doppler
anywhere in the repo — no `doppler` CLI usage, config files, dependencies, CI
steps, install steps, env vars, or documentation. Behavior (the set of env vars
the app sees) must be unchanged. A repo-wide search for `doppler` / `DOPPLER`
(case-insensitive) must return nothing once you are done.

## Steps

1. **Audit Doppler usage.** Find every reference in the repo and list them
   before editing. Search for: `doppler.yaml` / `doppler.yml`, `doppler run`,
   `doppler secrets`, `DOPPLER_TOKEN`, `DOPPLER_` env vars, and any mention in
   `package.json` scripts, `Makefile`, `Justfile`, Dockerfiles, shell scripts,
   CI workflows (`.github/`, `.gitlab-ci.yml`, etc.), and docs/READMEs.

2. **Confirm prerequisites (instruct me if missing).** The `vault` wrapper must
   be installed and on `PATH`, and the Vault CLI/OpenBao binary must be present.
   Installed once from the `secret-store` repo:

   ```bash
   ./scripts/install-cli.sh          # installs wrapper to ~/.local/bin/vault
   vault login hvs.your-root-token   # or: ./scripts/create-dev-token.sh
   ```

   Do not attempt to install global tooling yourself — tell me the exact
   commands to run if they are missing.

3. **Ensure secrets exist in the store.** If `secret/personal/dev` or
   `secret/personal/prd` is missing, do NOT invent values. Tell me to run the
   migration helper from the `secret-store` repo, then continue once it reports
   success:

   ```bash
   ./scripts/vault-run.sh -- ./scripts/migrate-doppler-to-openbao.sh \
     --project personal --dry-run        # preview
   ./scripts/vault-run.sh -- ./scripts/migrate-doppler-to-openbao.sh \
     --project personal                  # write (upsert)
   ```

4. **Create `.vault.yaml`** at the repo root (replacing `doppler.yaml`). It
   contains no secrets, only the path coordinates, and is safe to commit:

   ```yaml
   addr: https://secret-store.chrisvouga.dev
   mount: secret
   project: personal
   config: dev   # default; use prd for production commands
   ```

5. **Replace runtime commands.** Swap every `doppler run -- <cmd>` for
   `vault run -- <cmd>` in scripts, `package.json`, `Makefile`, Dockerfiles,
   etc. The default config is `dev`; for production use
   `vault run --config prd -- <cmd>`.

6. **Update CI (GitHub Actions OIDC — no stored token).** Do NOT add a
   `VAULT_TOKEN` secret. The store has a JWT auth method that trusts GitHub's
   OIDC issuer, so CI authenticates with a short-lived token minted per run.

   Remove `DOPPLER_TOKEN` and pull secrets via OIDC instead. Grant the job the
   OIDC permission and use `hashicorp/vault-action` (works against OpenBao):

   ```yaml
   permissions:
     id-token: write   # required to request a GitHub OIDC token
     contents: read

   steps:
     - uses: hashicorp/vault-action@v3
       with:
         url: https://secret-store.chrisvouga.dev
         method: jwt
         path: jwt
         role: github-actions
         secrets: |
           secret/data/personal/prd OPENAI_API_KEY | OPENAI_API_KEY ;
           secret/data/personal/prd DATABASE_URL   | DATABASE_URL
   ```

   This repo must be allowed by the JWT role's bound claims. If `vault-action`
   fails with a permission/role error, tell me to authorize it from the
   `secret-store` repo (one-time, per repo or via an owner-wide glob):

   ```bash
   ./scripts/setup-oidc-auth.sh --repo chrisvouga/<this-repo>
   ```

   Never hardcode tokens or add a `VAULT_TOKEN`/`DOPPLER_TOKEN` CI secret.

7. **Update docs.** Fix README/setup instructions to describe `vault login`,
   `vault setup`, and `vault run` instead of the Doppler equivalents.

8. **Verify (no secret values printed).** Confirm the env var names the app
   expects are present:

   ```bash
   vault run --dry-run -- <app-start-command>   # prints env var NAMES only
   ```

   Compare the name list against what the app reads (e.g. references to
   `process.env.*`, `os.environ[...]`, etc.). Investigate any missing keys —
   they may be `DOPPLER_*` reserved keys (intentionally excluded) or may need to
   be added to the secret.

9. **Completely remove Doppler.** Once verified, eradicate every trace of
   Doppler from the repo:
   - Delete `doppler.yaml` / `doppler.yml` (and any `.doppler` files).
   - Remove the `doppler` CLI from dependencies and lockfiles (`package.json`,
     `Brewfile`, `requirements`, etc.) and from any `mise`/`asdf`/tool configs.
   - Remove every Doppler install/setup step from Dockerfiles, CI workflows,
     scripts, and Makefiles.
   - Drop `DOPPLER_TOKEN` and any other `DOPPLER_*` vars from CI secrets,
     `.env*` files, and `.env.example` files.
   - Strip all Doppler mentions from READMEs and docs, replacing them with the
     `vault login` / `vault setup` / `vault run` equivalents.
   - Finally, run a repo-wide case-insensitive search for `doppler` and confirm
     there are **no** matches left (call out anything intentionally kept).

## Constraints

- Read-only against Doppler; never write secrets back to Doppler.
- Never print secret values, commit tokens, or hardcode credentials.
- `.vault.yaml` is safe to commit (no secrets). `VAULT_TOKEN` and any
  `init-output.json` / `.vault-token` are NOT — keep them out of git.
- CI must use GitHub Actions OIDC (step 6), not a stored `VAULT_TOKEN`. A
  static token is only acceptable for local/manual use.
- Make the smallest changes needed; do not refactor unrelated code.

## Deliverable

When done, output:

1. A list of every file changed and why.
2. The final `.vault.yaml`.
3. The verification result from step 8 (env var names matched / any gaps).
4. Proof that Doppler is fully removed: the output of a repo-wide
   case-insensitive search for `doppler` showing no remaining matches (or an
   explicit justification for anything intentionally kept).
5. A checklist of anything left for me to do manually (auth, authorizing this
   repo for OIDC via `setup-oidc-auth.sh`, running the migration helper).
