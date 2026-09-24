# Contributing

Thanks for helping improve this resource. The most useful contributions are concrete: a failure case the patterns do not handle, a workflow that breaks on a newer n8n version, or a clearer explanation of a tradeoff.

## Before opening a pull request

- **Keep examples runnable.** New or changed workflows should run against the local stack in `docker/` using the mock API, not a third-party account.
- **Say where an example comes from.** Every workflow has a sticky note with an Origin line. Mark it as a new demonstration unless it is derived from a real workflow you are allowed to share.
- **Keep state rules in SQL.** If a pattern needs new state transitions, add a function to `sql/schema.sql` and a test to `tests/sql/test_schema.sql`, rather than updating tables from workflow nodes.
- **Run the checks** described in [tests/README.md](tests/README.md). At minimum, the SQL tests.

## Sanitizing workflows

Exported n8n workflows can carry more than you expect. Before submitting one, remove:

- credential blocks (`"credentials": {...}`) and any API keys, tokens, or passwords typed into node parameters or headers
- internal hostnames, private IPs, and URLs of real services
- webhook IDs and paths you use in production
- `pinData` and any sample data taken from real executions
- prompts, business rules, or identifiers that belong to an employer or client

Use obvious placeholders such as `YOUR_API_KEY` or `https://YOUR_ALERT_WEBHOOK_URL`.

## Writing style

Explain the failure first, then the pattern, then its limits. Avoid words like "guaranteed" or "bulletproof": every pattern here reduces a specific risk under stated assumptions, and the docs should say what those are.

## Reporting security issues

If you find a security problem, such as an example that could expose credentials, please open an issue without including sensitive details, or contact the maintainer through the links in the README.
