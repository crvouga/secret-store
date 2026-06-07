# Secret Store (OpenBao on Fly.io)

Production-ready [OpenBao](https://openbao.org/) deployment on Fly.io with Neon Postgres storage, Cloudflare DNS, and automated GitHub Actions pipeline.

**URL:** https://secret-store.chrisvouga.dev

## Architecture

```
GitHub Actions (push to main)
  ├── provision-dns   → Cloudflare CNAME
  ├── migrate-db      → Neon Postgres (secret_store schema)
  ├── deploy          → Fly.io (OpenBao container)
  ├── issue-tls       → Fly.io certificate
  └── smoke-test      → KV round-trip verification

OpenBao (Fly.io) ──storage──► Neon Postgres (secret_store schema)
Cloudflare DNS ──CNAME──► secret-store-chrisvouga.fly.dev
```

## Database schema

All database objects live in the **`secret_store`** schema — never `public`:

| Table | Purpose |
|-------|---------|
| `secret_store.vault_kv_store` | OpenBao storage backend |
| `secret_store.vault_ha_locks` | OpenBao HA locks (reserved for future use) |
| `secret_store.schema_migrations` | Applied migration tracking |

OpenBao is configured with `skip_create_table = true` so it never auto-creates tables in `public`. The entrypoint sets `search_path=secret_store` on the Postgres connection so all OpenBao queries resolve to the custom schema.

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) — `gh auth login`
- [flyctl](https://fly.io/docs/hands-on/install-flyctl/) — `fly auth login`
- [Wrangler](https://developers.cloudflare.com/workers/wrangler/) — `wrangler login`
- [Neon CLI (`neonctl`)](https://neon.com/docs/reference/cli-install) — `neon auth`
- [OpenBao CLI (`bao`)](https://openbao.org/docs/install/) — for init and smoke tests
- [PostgreSQL client (`psql`)](https://www.postgresql.org/download/) — for migrations
- [`jq`](https://jqlang.github.io/jq/) — for init and seed scripts

## First-Time Setup

### 1. Create the Fly app (one-time, local)

```bash
fly apps create secret-store-chrisvouga
```

### 2. Seed secrets

Log in to each provider, then run the seed script. It auto-fetches secrets from your CLI sessions and pushes them to GitHub Actions (and Fly):

```bash
gh auth login
fly auth login
wrangler login
neonctl auth          # npm i -g neonctl  (or: npx neonctl auth)

chmod +x scripts/seed-github-secrets.sh
./scripts/seed-github-secrets.sh
```

| Secret | Required | Auto-fetched from |
|--------|----------|-------------------|
| `FLY_API_TOKEN` | Yes | `fly auth token` |
| `CF_API_TOKEN` | Yes | `wrangler auth token` |
| `DB_CONNECTION_URI` | Yes | `neon connection-string` |
| `BAO_TOKEN` | After init | `init-output.json` (after `./scripts/init.sh`) |

Flags:

- `--skip-fly` — only seed GitHub (if the Fly app is not created yet)
- `--skip-bao` — do not fetch or set `BAO_TOKEN`

Optional overrides via `.env.secrets` (copy from `.env.secrets.example`) or environment variables. Set `NEON_PROJECT_ID` if you have multiple Neon projects (or run `neon set-context` first).

If CI DNS provisioning fails, the Wrangler OAuth token may lack zone DNS permissions. Create a scoped **Zone:DNS:Edit** API token in Cloudflare and set `CLOUDFLARE_API_TOKEN` in `.env.secrets` before re-running the script.

Re-run after `init.sh` to pick up `BAO_TOKEN` from `init-output.json` for CI smoke tests.

The workflow derives everything else automatically:

- **Cloudflare zone** — looked up from `CUSTOM_DOMAIN` (`secret-store.chrisvouga.dev` → zone `chrisvouga.dev`)
- **Fly hostname** — derived from `FLY_APP` (`secret-store-chrisvouga.fly.dev`)

### 3. Deploy via GitHub Actions

Push to `main`. The workflow will:

1. Create the Cloudflare CNAME (`secret-store.chrisvouga.dev` → `secret-store-chrisvouga.fly.dev`, not proxied)
2. Run database migrations against Neon (`secret_store` schema)
3. Deploy OpenBao to Fly.io
4. Issue a TLS certificate for the custom domain
5. Run smoke tests if `BAO_TOKEN` is set (skipped automatically until after step 4)

### 4. Initialize OpenBao (one-time, local)

After the first deploy succeeds, run init locally:

```bash
export DB_CONNECTION_URI="postgres://..."
export BAO_ADDR="https://secret-store.chrisvouga.dev"

chmod +x scripts/init.sh scripts/migrate.sh
./scripts/init.sh
```

This script will:

1. Run database migrations (`scripts/migrate.sh`)
2. Wait for OpenBao to become reachable
3. Initialize OpenBao (5 unseal keys, threshold 3)
4. Save credentials to `init-output.json` (gitignored)
5. Unseal OpenBao with 3 keys

**Save the unseal keys and root token from the output immediately.**

Then re-run the seed script to push `BAO_TOKEN` to GitHub:

```bash
./scripts/seed-github-secrets.sh
```

Re-run the workflow (or push a commit) to execute smoke tests.

## **WARNING: Back Up Unseal Keys and Root Token**

**Losing your unseal keys or root token means losing access to ALL secrets permanently.** There is no recovery without the unseal keys. Store them offline in a password manager or secure physical backup. Never commit them to git.

## Database migrations

Migrations live in [`migrations/`](migrations/) and are applied by [`scripts/migrate.sh`](scripts/migrate.sh):

```bash
export DB_CONNECTION_URI="postgres://..."
./scripts/migrate.sh
```

The script is idempotent — already-applied migrations are tracked in `secret_store.schema_migrations` and skipped. CI runs this automatically before every deploy.

To add a new migration, create `migrations/003_description.sql` using fully qualified `secret_store.*` table names.

## Manual Unseal

OpenBao does **not** use auto-unseal. After a machine restart or redeploy, OpenBao will be **sealed** and must be unsealed manually:

```bash
export BAO_ADDR="https://secret-store.chrisvouga.dev"

bao operator unseal   # enter unseal key 1
bao operator unseal   # enter unseal key 2
bao operator unseal   # enter unseal key 3

bao status            # should show Sealed: false
```

You need 3 of the 5 unseal keys each time.

## Smoke Tests

### Locally

```bash
export BAO_ADDR="https://secret-store.chrisvouga.dev"
export BAO_TOKEN="your-root-token"

chmod +x scripts/smoke-test.sh
./scripts/smoke-test.sh
```

### In CI

Smoke tests run automatically on every push to `main` when `BAO_TOKEN` is configured. If the secret is not set yet, the job skips with a message.

## Fly Secrets

| Secret | Purpose |
|--------|---------|
| `DB_CONNECTION_URI` | Neon Postgres connection string for OpenBao storage backend |

```bash
fly secrets set DB_CONNECTION_URI="postgres://..." --app secret-store-chrisvouga
```

Fly also sets `FLY_APP_NAME` automatically, which the entrypoint uses to configure `BAO_API_ADDR`. The entrypoint appends `search_path=secret_store` to the connection URL at runtime.

## Health Checks

Fly.io health checks hit:

```
GET /v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200
```

This returns HTTP 200 even when OpenBao is sealed or uninitialized, so the process is considered healthy while waiting for manual init/unseal.

## Repository Structure

```
secret-store/
├── .github/workflows/deploy.yml   # CI/CD pipeline
├── config/openbao.hcl             # OpenBao server config
├── migrations/                    # SQL migrations (secret_store schema)
├── scripts/
│   ├── init.sh                    # First-time initialization
│   ├── migrate.sh                 # Apply database migrations
│   ├── seed-github-secrets.sh     # Auto-fetch + seed GitHub/Fly secrets
│   └── smoke-test.sh              # End-to-end verification
├── docker-entrypoint.sh           # Maps env vars + search_path for OpenBao
├── Dockerfile
├── fly.toml
└── README.md
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Health check fails | Check Fly logs: `fly logs --app secret-store-chrisvouga` |
| Smoke test returns 503 | OpenBao is sealed — run manual unseal |
| DNS not resolving | Verify Cloudflare CNAME points to `secret-store-chrisvouga.fly.dev` (proxied: off) |
| TLS certificate pending | Wait for DNS propagation; check with `fly certs check secret-store.chrisvouga.dev` |
| DB connection errors | Verify `DB_CONNECTION_URI` Fly secret matches Neon connection string |
| Migration job fails | Check `DB_CONNECTION_URI` GitHub secret; ensure Neon allows connections from GitHub Actions IPs |
| Empty OpenBao after schema change | If data existed in `public.vault_kv_store`, migrate manually: `INSERT INTO secret_store.vault_kv_store SELECT * FROM public.vault_kv_store;` |
