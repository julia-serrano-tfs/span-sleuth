BEGIN;
CREATE FUNCTION pg_temp.assert_rejected(statement text, expected_state text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected_state THEN RETURN; END IF;
        RAISE;
    END;
    RAISE EXCEPTION 'Expected SQLSTATE % for %', expected_state, statement;
END;
$$;

INSERT INTO incidents (id, source, service, environment, status, severity, summary, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000001', 'grafana-demo', 'cart', 'local',
        'open', 'warning', 'Cart latency', '2026-10-16T10:00:00Z', '2026-10-16T10:00:00Z');

SELECT pg_temp.assert_rejected($test$
    INSERT INTO incidents SELECT '00000000-0000-0000-0000-000000000002', revision,
        source, service, environment, status, severity, summary,
        created_at, updated_at, resolved_at, resolution_reason FROM incidents
$test$, '23505');

INSERT INTO incidents SELECT '00000000-0000-0000-0000-000000000003', revision,
    source, 'checkout', environment, status, severity, summary,
    created_at, updated_at, resolved_at, resolution_reason FROM incidents
WHERE id = '00000000-0000-0000-0000-000000000001';
INSERT INTO incidents SELECT '00000000-0000-0000-0000-000000000004', revision,
    source, service, 'production', status, severity, summary,
    created_at, updated_at, resolved_at, resolution_reason FROM incidents
WHERE id = '00000000-0000-0000-0000-000000000001';
INSERT INTO incidents SELECT '00000000-0000-0000-0000-000000000005', revision,
    'grafana-other', service, environment, status, severity, summary,
    created_at, updated_at, resolved_at, resolution_reason FROM incidents
WHERE id = '00000000-0000-0000-0000-000000000001';

INSERT INTO incidents (id, source, service, environment, status, severity, summary, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000007', 'grafana-demo', NULL, NULL,
        'open', 'unknown', 'Unknown identity 1', now(), now()),
       ('00000000-0000-0000-0000-000000000008', 'grafana-demo', NULL, NULL,
        'open', 'unknown', 'Unknown identity 2', now(), now());

INSERT INTO alert_occurrences (id, incident_id, source, service, environment,
    fingerprint, started_at, status, severity, summary, labels, annotations, last_seen_at)
VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
    'grafana-demo', 'cart', 'local', 'abc', '2026-10-16T10:00:00Z', 'firing', 'warning',
    'Cart latency', '{"service_name":"cart"}', '{"summary":"Cart latency"}', '2026-10-16T10:01:00Z');

SELECT pg_temp.assert_rejected($test$
    INSERT INTO alert_occurrences SELECT '10000000-0000-0000-0000-000000000002',
        incident_id, source, service, environment, fingerprint, started_at,
        resolved_at, status, severity, summary, labels, annotations, last_seen_at
    FROM alert_occurrences
$test$, '23505');

INSERT INTO alert_occurrences SELECT '10000000-0000-0000-0000-000000000003',
    incident_id, source, service, environment, fingerprint, '2026-10-16T11:00:00Z',
    resolved_at, status, severity, summary, labels, annotations, '2026-10-16T11:01:00Z'
FROM alert_occurrences WHERE id = '10000000-0000-0000-0000-000000000001';

SELECT pg_temp.assert_rejected($test$
    UPDATE alert_occurrences SET environment = 'production'
    WHERE id = '10000000-0000-0000-0000-000000000001'
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE incidents SET service = 'other'
    WHERE id = '00000000-0000-0000-0000-000000000001'
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE alert_occurrences SET incident_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    WHERE id = '10000000-0000-0000-0000-000000000001'
$test$, '23503');
SELECT pg_temp.assert_rejected($test$
    UPDATE alert_occurrences SET labels = '{"bad":42}'
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE alert_occurrences SET annotations = '[]'
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE alert_occurrences SET status = 'resolved', resolved_at = '2026-10-16T09:00:00Z'
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE alert_occurrences SET status = 'other'
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE incidents SET revision = 0
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE incidents SET status = 'resolved'
$test$, '23514');
SELECT pg_temp.assert_rejected($test$
    UPDATE incidents SET severity = 'urgent'
$test$, '23514');

INSERT INTO alert_occurrences (id, source, fingerprint, started_at, resolved_at,
    status, severity, summary, last_seen_at)
VALUES ('10000000-0000-0000-0000-000000000004', 'grafana-demo', 'resolved-first',
    '2026-10-16T10:00:00Z', '2026-10-16T10:05:00Z', 'resolved', 'unknown',
    'Resolution arrived first', '2026-10-16T10:06:00Z');
SELECT pg_temp.assert_rejected($test$
    UPDATE alert_occurrences SET status = 'firing', resolved_at = NULL
    WHERE id = '10000000-0000-0000-0000-000000000004'
$test$, '23514');

UPDATE alert_occurrences SET status = 'resolved', resolved_at = '2026-10-16T12:00:00Z'
WHERE incident_id = '00000000-0000-0000-0000-000000000001';
UPDATE incidents SET status = 'resolved', resolved_at = '2026-10-16T12:00:00Z',
    resolution_reason = 'All alerts resolved', revision = revision + 1,
    updated_at = '2026-10-16T12:01:00Z'
WHERE id = '00000000-0000-0000-0000-000000000001';
INSERT INTO incidents (id, source, service, environment, status, severity, summary, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000006', 'grafana-demo', 'cart', 'local',
        'open', 'warning', 'A later incident', now(), now());

DO $$
DECLARE affected integer;
BEGIN
    UPDATE incidents SET revision = revision + 1
    WHERE id = '00000000-0000-0000-0000-000000000001' AND revision = 1;
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 0 THEN RAISE EXCEPTION 'Stale revision overwrote incident'; END IF;
END;
$$;
ROLLBACK;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM incidents) OR EXISTS (SELECT 1 FROM alert_occurrences) THEN
        RAISE EXCEPTION 'Transaction rollback left business data behind';
    END IF;
END;
$$;
