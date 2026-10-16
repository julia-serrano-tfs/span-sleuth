#!/usr/bin/env bash
set -euo pipefail

service_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="$(cd "$service_dir/../.." && pwd)"
image=${POSTGRES_IMAGE:-$(sed -n 's/^POSTGRES_IMAGE=//p' "$repo_dir/.env")}
container="incident-schema-test-$(date +%s)-$$"
test_dir=$(mktemp -d)
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT

docker run --detach --rm --name "$container" \
    --env POSTGRES_DB=span_sleuth --env POSTGRES_USER=span_sleuth_admin \
    --env POSTGRES_PASSWORD=admin_test --env PGUSER=span_sleuth_admin \
    --env PGDATABASE=span_sleuth --env PGHOST=127.0.0.1 --env PGPASSWORD=admin_test \
    --env INCIDENT_DB_PASSWORD=incident_app_test \
    --env INCIDENT_DB_MIGRATION_PASSWORD=incident_migration_test \
    --env INVESTIGATION_DB_PASSWORD=investigation_app_test \
    --env INVESTIGATION_DB_MIGRATION_PASSWORD=investigation_migration_test \
    --tmpfs /var/lib/postgresql \
    --mount "type=bind,source=$service_dir,target=/workspace,readonly" \
    --mount "type=bind,source=$repo_dir/src/shared/database,target=/bootstrap,readonly" \
    "$image" >/dev/null

ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
    if docker exec "$container" psql -X -Atqc 'SELECT 1' >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done
if [[ "$ready" != true ]]; then
    docker logs "$container" >&2
    exit 1
fi

db_as() {
    local role=$1 password=$2
    shift 2
    docker exec --env PGUSER="$role" --env PGPASSWORD="$password" "$container" \
        psql -X --set ON_ERROR_STOP=1 --set VERBOSITY=verbose "$@"
}
migrate() {
    docker exec --env PGUSER=incident_migrator --env PGPASSWORD=incident_migration_test \
        --env PGOPTIONS='-c search_path=public' "$container" bash "$1"
}
assert_denied() {
    local role=$1 password=$2 statement=$3
    if db_as "$role" "$password" -c "$statement" >"$test_dir/denied.log" 2>&1; then
        echo "Unexpected permission granted to $role: $statement" >&2
        exit 1
    fi
    if ! grep -q '42501' "$test_dir/denied.log"; then
        cat "$test_dir/denied.log" >&2
        exit 1
    fi
}

docker exec "$container" bash /bootstrap/provision.sh
migrate /workspace/scripts/migrate.sh
migrate /workspace/scripts/migrate.sh
test "$(db_as incident_migrator incident_migration_test -Atqc 'SELECT count(*) FROM schema_migrations')" = 1
db_as incident_migrator incident_migration_test --file /workspace/test/database.sql

db_as incident_migrator incident_migration_test -c \
    'CREATE TABLE incident_management.permission_probe (id bigint GENERATED ALWAYS AS IDENTITY, value text)' >/dev/null
db_as investigation_migrator investigation_migration_test -c \
    'CREATE TABLE investigation.permission_probe (id bigint GENERATED ALWAYS AS IDENTITY, value text)' >/dev/null

db_as incident_app incident_app_test -c \
    "INSERT INTO permission_probe (value) VALUES ('incident'); UPDATE permission_probe SET value = 'updated'; SELECT * FROM permission_probe; DELETE FROM permission_probe" >/dev/null
db_as investigation_app investigation_app_test -c \
    "INSERT INTO permission_probe (value) VALUES ('investigation'); UPDATE permission_probe SET value = 'updated'; SELECT * FROM permission_probe; DELETE FROM permission_probe" >/dev/null
db_as incident_app incident_app_test --file /workspace/test/runtime-access.sql

docker exec "$container" bash /bootstrap/provision.sh
for kind in incident investigation; do
    if [[ "$kind" = incident ]]; then
        other=investigation
        own=incident_management
    else
        other=incident_management
        own=investigation
    fi
    for role_type in app migrator; do
        role="${kind}_${role_type}"
        if [[ "$role_type" = app ]]; then
            password="${kind}_app_test"
        else
            password="${kind}_migration_test"
        fi
        assert_denied "$role" "$password" "SELECT * FROM $other.permission_probe"
        assert_denied "$role" "$password" "INSERT INTO $other.permission_probe (value) VALUES ('forbidden')"
        assert_denied "$role" "$password" "DROP TABLE $other.permission_probe"
        assert_denied "$role" "$password" 'CREATE TABLE public.forbidden (id integer)'
        assert_denied "$role" "$password" 'CREATE SCHEMA forbidden'
        assert_denied "$role" "$password" 'SET ROLE span_sleuth_admin'
    done
    assert_denied "${kind}_app" "${kind}_app_test" "CREATE TABLE $own.forbidden (id integer)"
    assert_denied "${kind}_app" "${kind}_app_test" "ALTER TABLE $own.permission_probe ADD COLUMN forbidden integer"
    assert_denied "${kind}_app" "${kind}_app_test" "TRUNCATE $own.permission_probe"
    assert_denied "${kind}_app" "${kind}_app_test" "SET ROLE ${kind}_migrator"
done
assert_denied incident_app incident_app_test 'SELECT * FROM incident_management.schema_migrations'
assert_denied investigation_migrator investigation_migration_test 'SELECT * FROM incident_management.schema_migrations'
test "$(docker exec "$container" psql -X -Atqc "SELECT count(*) FROM pg_roles WHERE rolname IN ('incident_app', 'incident_migrator', 'investigation_app', 'investigation_migrator') AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)")" = 0
test "$(docker exec "$container" psql -X -Atqc "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0

insert_scope() {
    db_as incident_app incident_app_test -c "
        BEGIN;
        INSERT INTO incidents (id, source, service, environment, status, severity, summary, created_at, updated_at)
        VALUES ('$1', 'concurrency-test', 'cart', 'local', 'open', 'warning', 'Concurrent alert', now(), now());
        SELECT pg_sleep(0.3);
        COMMIT;"
}
insert_scope '20000000-0000-0000-0000-000000000001' >"$test_dir/first.log" 2>&1 &
first=$!
insert_scope '20000000-0000-0000-0000-000000000002' >"$test_dir/second.log" 2>&1 &
second=$!
first_status=0
wait "$first" || first_status=$?
second_status=0
wait "$second" || second_status=$?
if ! { [[ "$first_status" = 0 && "$second_status" != 0 ]] || [[ "$second_status" = 0 && "$first_status" != 0 ]]; }; then
    cat "$test_dir/first.log" "$test_dir/second.log" >&2
    exit 1
fi
grep -q '23505' "$test_dir/first.log" "$test_dir/second.log"
test "$(db_as incident_app incident_app_test -Atqc "SELECT count(*) FROM incidents WHERE source = 'concurrency-test'")" = 1

docker exec "$container" bash -c '
    mkdir -p /tmp/migration-failure-test
    cp -R /workspace/scripts /workspace/migrations /tmp/migration-failure-test/
    printf "CREATE TABLE migration_should_rollback (id integer); SELECT 1 / 0;\n" \
        > /tmp/migration-failure-test/migrations/002_failure.sql
'
if migrate /tmp/migration-failure-test/scripts/migrate.sh >"$test_dir/failure.log" 2>&1; then
    echo 'Migration runner accepted a failing migration' >&2
    exit 1
fi
test "$(db_as incident_migrator incident_migration_test -Atqc "SELECT to_regclass('incident_management.migration_should_rollback') IS NULL")" = t
test "$(db_as incident_migrator incident_migration_test -Atqc 'SELECT count(*) FROM schema_migrations')" = 1

db_as incident_migrator incident_migration_test -c \
    "UPDATE schema_migrations SET checksum = 'tampered'" >/dev/null
if migrate /workspace/scripts/migrate.sh >"$test_dir/checksum.log" 2>&1; then
    echo 'Migration runner accepted an edited applied migration' >&2
    exit 1
fi
grep -q 'Applied migration changed' "$test_dir/checksum.log"
echo 'Incident database integration and schema isolation tests passed.'
