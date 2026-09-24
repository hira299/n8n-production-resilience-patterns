# Self-hosted n8n with Docker

The compose file in [docker/](../../docker/) is a local stack for running the examples. This page covers what to change when you base a real deployment on it.

## Running the local stack

```bash
cd docker
cp .env.example .env              # set POSTGRES_PASSWORD and N8N_ENCRYPTION_KEY
docker compose up -d
docker compose ps                 # postgres and mock-api report healthy
```

On first start, Postgres runs `init/01-create-resilience-db.sh`, which creates the `resilience` database and loads `sql/schema.sql`. Init scripts run only on an empty volume. To apply schema changes to an existing volume, run the schema file again; it is idempotent:

```bash
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d resilience < ../sql/schema.sql
```

To start over: `docker compose down -v` (this deletes both databases).

## Checklist for a real deployment

**Versions and storage**
- Pin the n8n image (`N8N_IMAGE=docker.n8n.io/n8nio/n8n:<version>`) and upgrade deliberately, after reading the release notes and testing workflows on a copy.
- Keep n8n's data in Postgres (as here), not the default SQLite, once more than one person or workflow depends on it.
- Back up Postgres (both databases) and the `N8N_ENCRYPTION_KEY`. Test a restore.

**Network**
- Serve n8n over HTTPS through a reverse proxy (Caddy, Nginx, Traefik) or a tunnel. Set `N8N_HOST`, `N8N_PROTOCOL=https`, and `WEBHOOK_URL` to the public URL, and remove `N8N_SECURE_COOKIE=false`.
- Do not publish the Postgres port publicly. The local stack binds it to 127.0.0.1 for convenience; in production, remove the port mapping unless something outside Docker needs it.
- Remove the `mock-api` service.

**Execution data**
- `EXECUTIONS_DATA_PRUNE=true` with a `EXECUTIONS_DATA_MAX_AGE` that suits your debugging needs. The dead-letter and job tables are the long-term record.
- Consider `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` for high-volume workflows, keeping errors only.

**Scaling**
- A single n8n container runs everything in one process. When workflows compete for CPU or you need isolation, switch to queue mode: set `EXECUTIONS_MODE=queue`, add Redis, and run one or more `n8n worker` containers. The job worker pattern works unchanged across several n8n workers because claiming uses `SKIP LOCKED`.
- Size the lock timeout in the job worker for the slowest legitimate job, not the average.

**Operations**
- Set an Error Workflow on every production workflow.
- Schedule the dead-letter digest, and a daily cleanup (`prune_rate_limit_windows()`, retention deletes for old jobs and events).
- Monitor `/healthz/readiness` and the queries in [observability](../patterns/observability.md).

## Activating workflows from the CLI

Useful for provisioning and tests. In n8n 2.x:

```bash
docker compose exec n8n n8n import:workflow --input=/examples/idempotency/idempotent-webhook-intake.json
docker compose exec n8n n8n publish:workflow --id=RPidemIntake0001
docker compose restart n8n        # CLI changes take effect after a restart
```

In n8n 1.x the second command is `n8n update:workflow --id=<id> --active=true`. Imported workflows keep the IDs in their JSON, which is why the examples can reference the error handler by ID.
