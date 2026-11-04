-- 0004_health — system health flags + automatic alerts for infrastructure problems
-- (Claude logged out, Chrome down, disk full, stale runs, missing backups ...).
-- bin/healthcheck.sh (cron, every 5 min) and run-case.sh report through report_health().

CREATE TABLE system_health (
  component   text PRIMARY KEY,              -- claude_auth, chrome, desktop, s3, disk, dispatcher, runs, backup ...
  status      text NOT NULL CHECK (status IN ('ok', 'warn', 'error')),
  message     text,
  details     jsonb NOT NULL DEFAULT '{}',
  checked_at  timestamptz NOT NULL DEFAULT now(),
  changed_at  timestamptz NOT NULL DEFAULT now()   -- last time status changed
);

ALTER TABLE alerts ADD COLUMN component text;      -- set for infrastructure alerts (platform is NULL then)
CREATE INDEX ix_alerts_component_open ON alerts (component) WHERE status = 'open';

ALTER TABLE alerts DROP CONSTRAINT alerts_kind_check;
ALTER TABLE alerts ADD CONSTRAINT alerts_kind_check
  CHECK (kind IN ('login', 'captcha', '2fa', 'blocked', 'ui_changed', 'rate_limited', 'vpn_down',
                  'error', 'health', 'other'));

ALTER TABLE runs DROP CONSTRAINT runs_status_check;
ALTER TABLE runs ADD CONSTRAINT runs_status_check
  CHECK (status IN ('running', 'success', 'partial', 'failed', 'rate_limited', 'timeout', 'incomplete', 'auth_error'));

-- Record a component's state. On 'error' open ONE alert for the component (deduplicated);
-- on 'ok' auto-resolve its open alerts. 'warn' is visible in v_system_health, no alert.
CREATE FUNCTION report_health(p_component text, p_status text, p_message text DEFAULT NULL,
                              p_details jsonb DEFAULT '{}') RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_prev text;
BEGIN
  SELECT status INTO v_prev FROM system_health WHERE component = p_component;

  INSERT INTO system_health (component, status, message, details, checked_at, changed_at)
  VALUES (p_component, p_status, p_message, coalesce(p_details, '{}'), now(), now())
  ON CONFLICT (component) DO UPDATE SET
    status = EXCLUDED.status, message = EXCLUDED.message, details = EXCLUDED.details, checked_at = now(),
    changed_at = CASE WHEN system_health.status <> EXCLUDED.status THEN now() ELSE system_health.changed_at END;

  IF p_status = 'error' THEN
    IF NOT EXISTS (SELECT 1 FROM alerts WHERE component = p_component AND status = 'open') THEN
      INSERT INTO alerts (kind, component, message)
      VALUES (CASE WHEN p_component = 'claude_auth' THEN 'login' ELSE 'health' END, p_component,
              coalesce(p_message, p_component || ' ne radi'));
    END IF;
  ELSIF p_status = 'ok' THEN
    UPDATE alerts SET status = 'resolved', resolved_at = now(), resolved_by = 'healthcheck',
                      resolution_note = 'automatski: komponenta ponovo radi'
     WHERE component = p_component AND status = 'open';
  END IF;

  RETURN p_component || ': ' || coalesce(v_prev, '-') || ' → ' || p_status;
END $$;

CREATE VIEW v_system_health AS
SELECT component, status, message, checked_at, changed_at,
       now() - checked_at AS since_check,
       CASE WHEN now() - checked_at > interval '15 minutes' THEN 'STALE — healthcheck ne radi?' END AS stale
FROM system_health
ORDER BY CASE status WHEN 'error' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END, component;

-- Open alerts now also show infrastructure components.
DROP VIEW v_open_alerts;
CREATE VIEW v_open_alerts AS
SELECT a.id, a.created_at, coalesce(a.platform, a.component) AS target, a.kind, c.name AS case_name,
       a.message, a.screenshot_key
FROM alerts a LEFT JOIN cases c ON c.id = a.case_id
WHERE a.status = 'open'
ORDER BY a.created_at;
