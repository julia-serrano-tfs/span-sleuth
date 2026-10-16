#!/usr/bin/env bash
set -euo pipefail

: "${INCIDENT_DB_PASSWORD:?Set INCIDENT_DB_PASSWORD}"
: "${INCIDENT_DB_MIGRATION_PASSWORD:?Set INCIDENT_DB_MIGRATION_PASSWORD}"
: "${INVESTIGATION_DB_PASSWORD:?Set INVESTIGATION_DB_PASSWORD}"
: "${INVESTIGATION_DB_MIGRATION_PASSWORD:?Set INVESTIGATION_DB_MIGRATION_PASSWORD}"

psql -X --set ON_ERROR_STOP=1 <<'SQL'
\getenv incident_password INCIDENT_DB_PASSWORD
\getenv incident_migration_password INCIDENT_DB_MIGRATION_PASSWORD
\getenv investigation_password INVESTIGATION_DB_PASSWORD
\getenv investigation_migration_password INVESTIGATION_DB_MIGRATION_PASSWORD
BEGIN;
SELECT pg_advisory_xact_lock(742018611);

SELECT format('CREATE ROLE %I LOGIN', name)
FROM (VALUES ('incident_app'), ('incident_migrator'),
             ('investigation_app'), ('investigation_migrator')) AS roles(name)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = name)
\gexec

ALTER ROLE incident_app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'incident_password';
ALTER ROLE incident_migrator WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'incident_migration_password';
ALTER ROLE investigation_app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'investigation_password';
ALTER ROLE investigation_migrator WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'investigation_migration_password';

REVOKE ALL ON DATABASE span_sleuth FROM PUBLIC;
GRANT CONNECT ON DATABASE span_sleuth
    TO incident_app, incident_migrator, investigation_app, investigation_migrator;
GRANT TEMPORARY ON DATABASE span_sleuth TO incident_migrator, investigation_migrator;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA IF NOT EXISTS incident_management AUTHORIZATION incident_migrator;
CREATE SCHEMA IF NOT EXISTS investigation AUTHORIZATION investigation_migrator;
REVOKE ALL ON SCHEMA incident_management FROM PUBLIC, investigation_app, investigation_migrator;
REVOKE ALL ON SCHEMA investigation FROM PUBLIC, incident_app, incident_migrator;
GRANT USAGE ON SCHEMA incident_management TO incident_app;
GRANT USAGE ON SCHEMA investigation TO investigation_app;

ALTER ROLE incident_app IN DATABASE span_sleuth SET search_path = incident_management;
ALTER ROLE incident_migrator IN DATABASE span_sleuth SET search_path = incident_management;
ALTER ROLE investigation_app IN DATABASE span_sleuth SET search_path = investigation;
ALTER ROLE investigation_migrator IN DATABASE span_sleuth SET search_path = investigation;

ALTER DEFAULT PRIVILEGES FOR ROLE incident_migrator IN SCHEMA incident_management
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO incident_app;
ALTER DEFAULT PRIVILEGES FOR ROLE investigation_migrator IN SCHEMA investigation
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO investigation_app;
ALTER DEFAULT PRIVILEGES FOR ROLE incident_migrator IN SCHEMA incident_management
    GRANT USAGE, SELECT ON SEQUENCES TO incident_app;
ALTER DEFAULT PRIVILEGES FOR ROLE investigation_migrator IN SCHEMA investigation
    GRANT USAGE, SELECT ON SEQUENCES TO investigation_app;
ALTER DEFAULT PRIVILEGES FOR ROLE incident_migrator REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE investigation_migrator REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA incident_management FROM PUBLIC, investigation_app, investigation_migrator;
REVOKE ALL ON ALL TABLES IN SCHEMA investigation FROM PUBLIC, incident_app, incident_migrator;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA incident_management FROM PUBLIC, investigation_app, investigation_migrator;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA investigation FROM PUBLIC, incident_app, incident_migrator;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA incident_management FROM PUBLIC, investigation_app, investigation_migrator;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA investigation FROM PUBLIC, incident_app, incident_migrator;

SELECT format('REVOKE ALL ON TABLE %I.schema_migrations FROM %I', schema_name, app_role)
FROM (VALUES ('incident_management', 'incident_app'), ('investigation', 'investigation_app'))
    AS histories(schema_name, app_role)
WHERE to_regclass(format('%I.schema_migrations', schema_name)) IS NOT NULL
\gexec
COMMIT;
SQL
