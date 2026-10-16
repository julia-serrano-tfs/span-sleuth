#!/usr/bin/env bash
set -euo pipefail

migration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../migrations" && pwd)"
shopt -s nullglob
migrations=("$migration_dir"/*.sql)
if ((${#migrations[@]} == 0)); then
    echo "No incident database migrations found" >&2
    exit 1
fi

sql_file=$(mktemp)
trap 'rm -f "$sql_file"' EXIT
cat >"$sql_file" <<'SQL'
BEGIN;
SELECT pg_advisory_xact_lock(742018612);
SET LOCAL search_path = incident_management;
CREATE TABLE IF NOT EXISTS incident_management.schema_migrations (
    version text PRIMARY KEY,
    checksum text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

for migration in "${migrations[@]}"; do
    version=$(basename "$migration")
    # Require an ordered numeric prefix and SQL-safe lowercase migration filename.
    if [[ ! "$version" =~ ^[0-9]{3}_[a-z0-9_]+\.sql$ ]]; then
        echo "Invalid migration filename: $version" >&2
        exit 1
    fi
    checksum=$(sha256sum "$migration")
    checksum=${checksum%% *}
    cat >>"$sql_file" <<SQL
SELECT EXISTS (SELECT 1 FROM incident_management.schema_migrations WHERE version = '$version') AS applied,
       EXISTS (SELECT 1 FROM incident_management.schema_migrations WHERE version = '$version'
               AND checksum <> '$checksum') AS changed
\gset migration_
\if :migration_changed
    DO \$\$ BEGIN RAISE EXCEPTION 'Applied migration changed: $version'; END; \$\$;
\endif
\if :migration_applied
    \echo Already applied: $version
\else
    \echo Applying: $version
    \ir '$migration'
    INSERT INTO incident_management.schema_migrations (version, checksum) VALUES ('$version', '$checksum');
\endif
SQL
done
printf 'REVOKE ALL ON incident_management.schema_migrations FROM incident_app;\nCOMMIT;\n' >>"$sql_file"
psql -X --set ON_ERROR_STOP=1 --file "$sql_file"
