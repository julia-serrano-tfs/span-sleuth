CREATE TABLE incident_management.incidents (
    id uuid PRIMARY KEY,
    revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
    source text NOT NULL CHECK (btrim(source) <> ''),
    service text CHECK (service IS NULL OR btrim(service) <> ''),
    environment text CHECK (environment IS NULL OR btrim(environment) <> ''),
    status text NOT NULL CHECK (status IN ('open', 'resolved')),
    severity text NOT NULL CHECK (severity IN ('unknown', 'info', 'warning', 'critical')),
    summary text NOT NULL CHECK (btrim(summary) <> ''),
    created_at timestamptz NOT NULL CHECK (isfinite(created_at)),
    updated_at timestamptz NOT NULL CHECK (isfinite(updated_at)),
    resolved_at timestamptz CHECK (resolved_at IS NULL OR isfinite(resolved_at)),
    resolution_reason text,
    CHECK (updated_at >= created_at),
    CHECK (
        (status = 'open' AND resolved_at IS NULL AND resolution_reason IS NULL)
        OR (status = 'resolved' AND resolved_at IS NOT NULL
            AND resolution_reason IS NOT NULL AND btrim(resolution_reason) <> '')
    )
);

CREATE UNIQUE INDEX incidents_one_open_per_scope
    ON incident_management.incidents (source, environment, service)
    WHERE status = 'open' AND service IS NOT NULL AND environment IS NOT NULL;

CREATE TABLE incident_management.alert_occurrences (
    id uuid PRIMARY KEY,
    incident_id uuid REFERENCES incident_management.incidents (id),
    source text NOT NULL CHECK (btrim(source) <> ''),
    service text CHECK (service IS NULL OR btrim(service) <> ''),
    environment text CHECK (environment IS NULL OR btrim(environment) <> ''),
    fingerprint text NOT NULL CHECK (btrim(fingerprint) <> ''),
    started_at timestamptz NOT NULL CHECK (isfinite(started_at)),
    resolved_at timestamptz CHECK (resolved_at IS NULL OR isfinite(resolved_at)),
    status text NOT NULL CHECK (status IN ('firing', 'resolved')),
    severity text NOT NULL CHECK (severity IN ('unknown', 'info', 'warning', 'critical')),
    summary text NOT NULL CHECK (btrim(summary) <> ''),
    labels jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(labels) = 'object'
            AND NOT jsonb_path_exists(labels, '$.* ? (@.type() != "string")')),
    annotations jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(annotations) = 'object'
            AND NOT jsonb_path_exists(annotations, '$.* ? (@.type() != "string")')),
    last_seen_at timestamptz NOT NULL CHECK (isfinite(last_seen_at)),
    UNIQUE (source, fingerprint, started_at),
    CHECK (
        (status = 'firing' AND resolved_at IS NULL AND incident_id IS NOT NULL)
        OR (status = 'resolved' AND resolved_at IS NOT NULL AND resolved_at >= started_at)
    )
);

CREATE INDEX alert_occurrences_incident_id ON incident_management.alert_occurrences (incident_id);

CREATE FUNCTION incident_management.validate_alert_incident_scope() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    parent incident_management.incidents%ROWTYPE;
BEGIN
    IF NEW.incident_id IS NOT NULL THEN
        SELECT * INTO parent FROM incident_management.incidents WHERE id = NEW.incident_id FOR SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Incident does not exist' USING ERRCODE = '23503';
        END IF;
        IF ROW(NEW.source, NEW.service, NEW.environment)
            IS DISTINCT FROM ROW(parent.source, parent.service, parent.environment) THEN
            RAISE EXCEPTION 'Alert scope must match its incident' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER alert_incident_scope
    BEFORE INSERT OR UPDATE ON incident_management.alert_occurrences
    FOR EACH ROW EXECUTE FUNCTION incident_management.validate_alert_incident_scope();

CREATE FUNCTION incident_management.prevent_incident_scope_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.source, NEW.service, NEW.environment)
        IS DISTINCT FROM ROW(OLD.source, OLD.service, OLD.environment) THEN
        RAISE EXCEPTION 'Incident correlation scope is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER incident_scope_immutable
    BEFORE UPDATE OF source, service, environment ON incident_management.incidents
    FOR EACH ROW EXECUTE FUNCTION incident_management.prevent_incident_scope_change();
