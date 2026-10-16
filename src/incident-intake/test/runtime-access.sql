BEGIN;
INSERT INTO incident_management.incidents
    (id, source, service, environment, status, severity, summary, created_at, updated_at)
VALUES ('30000000-0000-0000-0000-000000000001', 'runtime-test', 'cart', 'local',
        'open', 'warning', 'Runtime write', now(), now());

SET LOCAL search_path = public;
INSERT INTO incident_management.alert_occurrences
    (id, incident_id, source, service, environment, fingerprint,
     started_at, status, severity, summary, last_seen_at)
VALUES ('30000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001',
        'runtime-test', 'cart', 'local', 'runtime-fingerprint', now(),
        'firing', 'warning', 'Runtime alert', now());
UPDATE incident_management.alert_occurrences
SET status = 'resolved', resolved_at = now()
WHERE id = '30000000-0000-0000-0000-000000000002';
DELETE FROM incident_management.alert_occurrences
WHERE id = '30000000-0000-0000-0000-000000000002';
DELETE FROM incident_management.incidents
WHERE id = '30000000-0000-0000-0000-000000000001';
ROLLBACK;
