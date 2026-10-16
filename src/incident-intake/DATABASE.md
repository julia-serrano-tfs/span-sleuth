# Shared database and incident schema

This slice implements `incident_management.incidents` and
`incident_management.alert_occurrences` in the shared `span_sleuth` database. Repository implementations, HTTP processing, outbox delivery,
and investigation persistence remain unimplemented.

## Local setup

Use Docker Compose v2 with `up --wait` support, Bash, and Make. No local Node.js
or PostgreSQL installation is needed to start the database or apply migrations.
Run the following commands from the repository root:

```sh
make start-incident-db
make migrate-incident-db
```

The database runs in the dedicated Compose project `span-sleuth-data`;
these commands do not start the webstore or change its `astronomy-db` database.
The normal `make start` command does not enable the incident database.
`compose.incidents.yaml` can also be layered with the other Compose files when
service containers are introduced; load `compose.extras.yaml` last. The database
service is named `span-sleuth-db`; both services will use that same server.

Local connection settings:

| Setting          | Default                   |
| ---------------- | ------------------------- |
| Host             | `127.0.0.1`               |
| Port             | `5433`                    |
| Database         | `span_sleuth`             |
| Schema           | `incident_management`     |
| Application user | `incident_app`            |
| Password         | `incident_local_password` |

The password is a local-development default. Override `INCIDENT_DB_PASSWORD` and
`SPAN_SLEUTH_DB_PORT` in `.env.override`, or export them in your shell. Compose
containers on the same network connect to `span-sleuth-db:5432`; applications
running on the host use `127.0.0.1:5433` instead. App connections automatically
use their service schema through a role-specific `search_path`.

`make start-incident-db` starts the shared server and runs the privileged role
provisioner. `make migrate-incident-db` depends on that setup, then applies only
Incident Management migrations using its restricted migration account. Service
application processes must never receive the admin or migration credentials.

Open a database console without installing PostgreSQL locally:

```sh
docker compose --env-file .env --env-file .env.override \
  --project-name span-sleuth-data -f compose.incidents.yaml \
  exec span-sleuth-db psql -h 127.0.0.1 -U incident_app -d span_sleuth -W
```

Stop the local database with:

```sh
make stop-incident-db
```

Data survives container recreation in the `span-sleuth-db-data` named volume.
The PostgreSQL image initializes the admin credentials only for a new data
directory: changing `SPAN_SLEUTH_DB_ADMIN_PASSWORD` does not change the password
of an existing admin. The provisioner updates the four service-role passwords
when `make start-incident-db` runs. The image version comes from the repository's
existing `POSTGRES_IMAGE` setting.

The earlier database-only prototype used a different project and volume,
`span-sleuth-incidents_incident-db-data`. This version does not delete or import
that volume. If it contains data you need, preserve it and plan an explicit
export/import before switching. The initial draft migration now targets the new
schema; do not run it against the former `public` tables.

## Service isolation and provisioning

There is one PostgreSQL instance, one `span_sleuth` database, and two schemas:

```text
span_sleuth
  incident_management     Intake tables and migration history
  investigation           Reserved for the worker's own migrations
```

`src/shared/database/provision.sh` is infrastructure provisioning, not an Intake
migration. It creates roles and schema ownership, removes public schema access
and default database access, and configures service-specific search paths.

| Role                     | Permissions                                                      | Password variable (local default)                                                |
| ------------------------ | ---------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `span_sleuth_admin`      | Provision schemas/roles; never used by applications              | `SPAN_SLEUTH_DB_ADMIN_PASSWORD` (`span_sleuth_local_admin`)                      |
| `incident_migrator`      | Own Incident Management schema and run its migrations            | `INCIDENT_DB_MIGRATION_PASSWORD` (`incident_local_migration_password`)           |
| `incident_app`           | Select, insert, update, delete Incident Management business data | `INCIDENT_DB_PASSWORD` (`incident_local_password`)                               |
| `investigation_migrator` | Own Investigation schema and run its future migrations           | `INVESTIGATION_DB_MIGRATION_PASSWORD` (`investigation_local_migration_password`) |
| `investigation_app`      | Select, insert, update, delete Investigation business data       | `INVESTIGATION_DB_PASSWORD` (`investigation_local_password`)                     |

All four service roles are non-superusers without database creation, role
creation, replication, or row-security bypass privileges. Neither service's
roles may access the other schema or create objects in `public`. Application
roles cannot create or alter tables, assume migration/admin roles, or access
migration history. Migration roles have temporary-object privileges for tooling;
application roles do not.

Default privileges grant each app CRUD access to tables and sequence access
created by its own migration role. Public function execution is revoked for
functions those migration roles create; future callable functions need explicit
grants in their migrations. Trigger execution works without exposing their
functions as application APIs.

The Investigation schema is intentionally empty: its tables and migration
history must be defined by that service later. Its migration runner must use
`investigation.schema_migrations`, revoke application access to that history,
and use its own migration lock key. No cross-schema joins, foreign keys, or
service-role grants are part of this design. Cross-service communication stays
behind APIs or messages.

## Schema and policies

`incidents` owns identity, revision, lifecycle, summary, severity, and the fixed
correlation scope (`source`, `environment`, `service`). A partial unique index
allows at most one open incident per fully known scope. Missing service or
environment does not establish a shared scope: the application must create
standalone incidents rather than correlate those alerts automatically.

`alert_occurrences` stores the source alert episode and its incident association.
A UUID is its primary key. A separate unique constraint on
`(source, fingerprint, started_at)` prevents duplicate episodes. Timestamp columns
use `timestamptz`; labels and annotations use `jsonb` objects with string values.

The duplicated scope fields describe the incident's grouping scope and each
alert's reported identity. Triggers reject conflicting scope on attached alerts
and changes to an existing incident's scope, including changes involving nulls.
An index on `alert_occurrences.incident_id` supports aggregate loading.

A resolved occurrence may have a null `incident_id` to retain resolutions that
arrive before firing notifications. Firing occurrences require an incident.
An incident must have at least one occurrence as a domain invariant; the future
application/repository must create them in one transaction. A foreign key alone
does not enforce that minimum cardinality.

The schema validates allowed statuses and severities, positive incident
revisions, finite timestamps, resolution consistency, and string-map JSON fields.
It does not implement correlation, severity aggregation, monotonic state
transitions, or automatic incident resolution. Those rules belong to the domain
and application. In particular, delayed firing notifications must not reopen
resolved occurrences.

Future repository updates must check the expected revision in their SQL update
and treat zero affected rows as a concurrency conflict. An unchanged repeated
notification must not increment the incident revision. `last_seen_at` records the
latest receipt time; it is operational metadata rather than a new business event.

## Versioned migrations

SQL migrations live in `migrations/` and are applied by `scripts/migrate.sh`.
Use names such as `002_add_example.sql`. Applied migrations are immutable: add a
new migration rather than editing one already applied.

The runner connects as `incident_migrator`, explicitly sets the schema search
path, and serializes Incident Management migrations using a PostgreSQL transaction
advisory lock. It records filenames and SHA-256 checksums in the infrastructure table
`incident_management.schema_migrations`, skips previously applied files, and rejects changed applied
files. All pending migrations and their version records commit together; an
error rolls them back. Use migrations that can run inside a transaction.

This does not rely on first-start initialization scripts: rerun
`make migrate-incident-db` to upgrade an existing database. There is no automatic
migration step hidden inside normal application startup.

## Integration tests

```sh
make test-incident-db
```

Tests create an isolated temporary PostgreSQL container with an in-memory data
directory, expose no host port, and remove it afterward. They do not use or clear
your local incident database. `POSTGRES_IMAGE` can be exported to select the test
image; otherwise tests use the image configured in `.env`.

Checks cover repeatable migrations, changed-migration rejection, failed-migration
rollback, occurrence uniqueness, incident-scope uniqueness, concurrent incident
creation, independent scopes, missing service/environment, scope consistency,
foreign keys, validation, transaction rollback, and stale revision checks.
Tests also authenticate over TCP as all four service roles, prove own-schema
application writes work, verify cross-schema reads/writes/DDL are denied, check
restricted role attributes, protect migration history, and reject application
DDL and role escalation. The Investigation test table is only an isolation
fixture inside the disposable test database.

## Architecture boundary

Domain code and application ports remain independent of PostgreSQL. Concrete
connections, SQL, row mapping, and transaction handling will live under
`src/adapters/outbound/`; bootstrap will construct and inject those adapters.
The current `TransactionContext` also includes future receipts, summaries, and
outbox ports. This schema slice does not claim to implement that full contract.

## Before opening a PR

Run the same command used by the Incident database GitHub Actions workflow:

```sh
make check-incident-db
```

This checks Bash with ShellCheck and shfmt, YAML with yamllint, Markdown with
markdownlint, and YAML/Markdown formatting with Prettier. It also validates the
standalone and combined Compose configurations, runs the isolated PostgreSQL
integration suite, and checks tracked-file whitespace. It does not start or
modify your persistent local database.

The checks and formatters run in a cached local tools image built from
`src/shared/database/Dockerfile.tools`, so Docker and Make are the only host
dependencies. `make lint-incident-db` runs just lint and formatting checks;
`make check-incident-db-compose` validates Compose without starting containers.
The image is built on demand, with Docker reusing unchanged layers.

To apply Bash, YAML, and Markdown formatting:

```sh
make format-incident-db
make check-incident-db
```

Formatting does not rewrite SQL migrations: applied migration checksums must
remain stable. SQL syntax and constraints are exercised against PostgreSQL in
the integration tests. Formatting is explicit; checks never rewrite source. YAML and Markdown reuse
the Prettier settings in `src/shared/typescript/prettier.config.mjs`, also used
by the TypeScript service commands.

Fork-owned Intake, Investigation, shared database/TypeScript tooling, the incidents Compose
file, and the database/service CI workflows are excluded from both `make checklicense`
and `make addlicense`. Existing upstream files retain their license checks.

The workflow runs automatically for pull requests targeting `main` and pushes to
`main`. It has no path filter, so its status is available for every PR.
Configure its `Incident database checks` status as a required branch-protection
check if you want failed checks to block merging. The repository-wide
`make check` remains separate; its changelog validation still requires a real
issue or PR reference.
