# Prompt: Migrate a project from Doppler to self-hosted OpenBao/Vault

Copy everything below the line into your coding agent, running it **inside the
project repo you want to migrate**. Fill in the `FILL ME IN` values first.

---

You are migrating this project off **Doppler** and onto a **self-hosted
OpenBao/Vault** instance. Doppler is being decommissioned; this repo must read
its secrets from the self-hosted store instead.

## Inputs (fill these in)

- Doppler project name: `FILL ME IN` (e.g. `myapp`)
- Doppler config(s) / environments to migrate: `FILL ME IN` (e.g. `dev`, `prd`)
- Secrets already migrated into the store? `FILL ME IN` (yes / no / unsure)

If any input is missing, inspect the repo (look for `doppler.yaml`) to infer it,
then ask me to confirm before changing anything.

## Facts about the target store (do not change these)

- Vault/OpenBao API address: `https://secret-store.chrisvouga.dev`
- Secrets engine: **KV v2**, mounted at `secret/`
- Path convention: `secret/<project>/<config>`
  - Example: Doppler `myapp` / `prd` lives at `secret/myapp/prd`
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
| `doppler setup`               | `vault setup --project <p> --config <c>`    |
| `doppler run -- <cmd>`        | `vault run -- <cmd>`                         |
| `doppler.yaml`                | `.vault.yaml`                                |
| `DOPPLER_TOKEN` (CI)          | `VAULT_TOKEN` (CI)                           |

## Goal

After migration, the project fetches secrets from `secret/<project>/<config>`
via `vault run`, with **no remaining dependency on Doppler** for runtime
secrets. Behavior (the set of env vars the app sees) must be unchanged.

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

3. **Ensure secrets exist in the store.** If the inputs say secrets are not yet
   migrated, do NOT invent values. Tell me to run the migration helper from the
   `secret-store` repo, then continue once it reports success:

   ```bash
   ./scripts/vault-run.sh -- ./scripts/migrate-doppler-to-openbao.sh \
     --project <project> --dry-run        # preview
   ./scripts/vault-run.sh -- ./scripts/migrate-doppler-to-openbao.sh \
     --project <project>                  # write (upsert)
   ```

4. **Create `.vault.yaml`** at the repo root (replacing `doppler.yaml`). It
   contains no secrets, only the path coordinates, and is safe to commit:

   ```yaml
   addr: https://secret-store.chrisvouga.dev
   mount: secret
   project: <project>
   config: <default-config>   # e.g. dev
   ```

5. **Replace runtime commands.** Swap every `doppler run -- <cmd>` for
   `vault run -- <cmd>` in scripts, `package.json`, `Makefile`, Dockerfiles,
   etc. For non-default configs use `vault run --config <c> -- <cmd>`.

6. **Update CI.** Replace `DOPPLER_TOKEN` with a `VAULT_TOKEN` secret and set
   `VAULT_ADDR=https://secret-store.chrisvouga.dev`. Run app commands through
   the wrapper (`vault run -- ...`) or export env first. Never hardcode tokens.

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

9. **Remove Doppler.** Once verified, delete `doppler.yaml`/`doppler.yml`, drop
   `DOPPLER_TOKEN` from CI, and remove any Doppler install steps or dependencies.

## Constraints

- Read-only against Doppler; never write secrets back to Doppler.
- Never print secret values, commit tokens, or hardcode credentials.
- `.vault.yaml` is safe to commit (no secrets). `VAULT_TOKEN` and any
  `init-output.json` / `.vault-token` are NOT — keep them out of git.
- Make the smallest changes needed; do not refactor unrelated code.

## Deliverable

When done, output:

1. A list of every file changed and why.
2. The final `.vault.yaml`.
3. The verification result from step 8 (env var names matched / any gaps).
4. A checklist of anything left for me to do manually (auth, CI secret,
   running the migration helper).
