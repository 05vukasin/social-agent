-- 0001_init — core schema for social-agent.
-- Applied by bin/migrate.sh inside one transaction, as the owner role.
--
-- Ownership of columns:
--   CRM / human  → clients, cases definition (name, type, platforms, schedule, status), case_terms origin='crm'
--   agent        → posts, comments, case_posts, runs, run_events, alerts, case_terms/case_sources origin='agent'
--   dispatcher   → cases.next_run_at / last_run_*

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------- helpers

-- IMMUTABLE wrapper so unaccent can be used in generated columns / indexes
-- (Serbian is often typed without diacritics: "kes kredit" must find "keš kredit").
CREATE FUNCTION f_unaccent(text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
  RETURN public.unaccent('public.unaccent'::regdictionary, $1);

CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Platforms we know about. A table (not an enum) so adding TikTok is an INSERT, not a migration.
CREATE TABLE platforms (
  code         text PRIMARY KEY,                -- instagram, reddit, facebook, x, linkedin, tiktok
  name         text NOT NULL,
  enabled      boolean NOT NULL DEFAULT true,
  -- Shared Chrome profile ⇒ account state is per platform, not per case.
  account_handle text,
  status       text NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'needs_human', 'disabled')),
  status_reason text,
  status_changed_at timestamptz NOT NULL DEFAULT now(),
  min_interval_minutes integer NOT NULL DEFAULT 60,  -- floor for any case on this platform
  notes        text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_platforms_updated BEFORE UPDATE ON platforms FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO platforms (code, name, min_interval_minutes) VALUES
  ('instagram', 'Instagram', 120),
  ('reddit',    'Reddit',     60),
  ('facebook',  'Facebook',  120),
  ('x',         'X',          90),
  ('linkedin',  'LinkedIn',  360),
  ('tiktok',    'TikTok',    180);
UPDATE platforms SET enabled = false WHERE code = 'tiktok';

-- ---------------------------------------------------------------- clients & cases

CREATE TABLE clients (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  external_ref text UNIQUE,                     -- id in the client's CRM
  name         text NOT NULL,
  metadata     jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_clients_updated BEFORE UPDATE ON clients FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE cases (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    uuid NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  external_ref text,                            -- id in the CRM
  slug         text NOT NULL UNIQUE,            -- folder name: /srv/social-agent/cases/<slug>
  type         text NOT NULL DEFAULT 'brand_monitoring',  -- selects skill case-<type>
  name         text NOT NULL,
  description  text,                            -- goal in plain words, goes into CLAUDE.md
  instructions text,                            -- extra per-case instructions from CRM/human
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'archived')),
  platforms    text[] NOT NULL DEFAULT ARRAY['instagram', 'reddit'],
  -- schedule
  interval_minutes integer NOT NULL DEFAULT 180 CHECK (interval_minutes >= 15),
  active_from  time,                            -- NULL = whole day (server TZ Europe/Belgrade)
  active_to    time,
  priority     integer NOT NULL DEFAULT 100,    -- lower = earlier when several are due
  -- dispatcher state
  next_run_at  timestamptz NOT NULL DEFAULT now(),
  last_run_at  timestamptz,
  last_run_status text,
  consecutive_failures integer NOT NULL DEFAULT 0,
  metadata     jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (client_id, external_ref)
);
CREATE TRIGGER trg_cases_updated BEFORE UPDATE ON cases FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX ix_cases_due ON cases (next_run_at, priority) WHERE status = 'active';

-- Terms = keywords that narrow down the case's subject, with metadata. Tree via parent_id.
CREATE TABLE case_terms (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id      uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  parent_id    uuid REFERENCES case_terms(id) ON DELETE SET NULL,
  term         text NOT NULL,
  kind         text NOT NULL DEFAULT 'keyword'
               CHECK (kind IN ('keyword', 'alias', 'product', 'person', 'organization', 'event',
                               'hashtag', 'account', 'location', 'exclude')),
  lang         text,                            -- sr-Latn, sr-Cyrl, en, ...
  platforms    text[],                          -- NULL = all case platforms
  weight       real NOT NULL DEFAULT 1.0,
  metadata     jsonb NOT NULL DEFAULT '{}',
  origin       text NOT NULL DEFAULT 'crm' CHECK (origin IN ('crm', 'human', 'agent')),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('probation', 'active', 'retired')),
  rationale    text,                            -- why the agent added it
  evidence     jsonb NOT NULL DEFAULT '[]',     -- post URLs that motivated it
  created_run_id uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_case_terms_updated BEFORE UPDATE ON case_terms FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE UNIQUE INDEX uq_case_terms ON case_terms (case_id, kind, lower(term));
CREATE INDEX ix_case_terms_case ON case_terms (case_id) WHERE status <> 'retired';

-- Agent may hold at most 10 non-retired terms of its own per case.
CREATE FUNCTION enforce_agent_term_limit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  n integer;
BEGIN
  IF NEW.origin = 'agent' AND NEW.status <> 'retired' THEN
    SELECT count(*) INTO n FROM case_terms
     WHERE case_id = NEW.case_id AND origin = 'agent' AND status <> 'retired' AND id <> NEW.id;
    IF n >= 10 THEN
      RAISE EXCEPTION 'agent term limit reached for case % (max 10 non-retired agent terms) — retire one first', NEW.case_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_case_terms_agent_limit BEFORE INSERT OR UPDATE OF origin, status ON case_terms
  FOR EACH ROW EXECUTE FUNCTION enforce_agent_term_limit();

-- Where to look on each platform (accounts, hashtags, subreddits, groups, pages, saved searches).
CREATE TABLE case_sources (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id      uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  platform     text NOT NULL REFERENCES platforms(code),
  kind         text NOT NULL CHECK (kind IN ('own_account', 'account', 'hashtag', 'subreddit',
                                             'group', 'page', 'search', 'url', 'tagged', 'location')),
  value        text NOT NULL,                   -- '@aikbanka', 'finansije', 'https://...'
  metadata     jsonb NOT NULL DEFAULT '{}',
  origin       text NOT NULL DEFAULT 'crm' CHECK (origin IN ('crm', 'human', 'agent')),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('probation', 'active', 'retired')),
  rationale    text,
  last_checked_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_case_sources_updated BEFORE UPDATE ON case_sources FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE UNIQUE INDEX uq_case_sources ON case_sources (case_id, platform, kind, lower(value));

-- ---------------------------------------------------------------- runs

CREATE TABLE runs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id      uuid REFERENCES cases(id) ON DELETE CASCADE,
  kind         text NOT NULL DEFAULT 'collect' CHECK (kind IN ('collect', 'synthesis', 'manual', 'maintenance')),
  status       text NOT NULL DEFAULT 'running'
               CHECK (status IN ('running', 'success', 'partial', 'failed', 'rate_limited', 'timeout', 'incomplete')),
  trigger      text NOT NULL DEFAULT 'cron',    -- cron | manual
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  claude_session_id text,                       -- `claude --resume <id>` to ask it later why
  platforms_done   text[] NOT NULL DEFAULT '{}',
  platforms_skipped text[] NOT NULL DEFAULT '{}',
  new_posts    integer NOT NULL DEFAULT 0,
  new_comments integer NOT NULL DEFAULT 0,
  summary      text,                            -- agent's own end-of-run summary
  stats        jsonb NOT NULL DEFAULT '{}',     -- tokens, duration, cost from `claude -p --output-format json`
  error        text
);
CREATE INDEX ix_runs_case_started ON runs (case_id, started_at DESC);
CREATE INDEX ix_runs_running ON runs (started_at) WHERE status = 'running';

CREATE TABLE run_events (
  id           bigserial PRIMARY KEY,
  run_id       uuid NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  at           timestamptz NOT NULL DEFAULT now(),
  event        text NOT NULL,                   -- hook name: PreToolUse, PostToolUse, Stop, ...
  tool         text,
  payload      jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX ix_run_events_run ON run_events (run_id, id);

-- ---------------------------------------------------------------- collected content

-- A post is global (dedup per platform); which cases it belongs to lives in case_posts.
CREATE TABLE posts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform     text NOT NULL REFERENCES platforms(code),
  external_id  text NOT NULL,                   -- platform id, or sha256(url) when none is visible
  url          text NOT NULL,
  author_handle text,
  author_name  text,
  author_url   text,
  title        text,
  body         text,
  lang         text,
  published_at timestamptz,
  metrics      jsonb NOT NULL DEFAULT '{}',     -- likes, comments, shares, views, score ...
  media        jsonb NOT NULL DEFAULT '[]',     -- [{type, url, s3_key, alt}]
  screenshot_key text,                          -- S3 key of the evidence screenshot
  raw          jsonb,
  deleted_at   timestamptz,                     -- seen gone on a later visit
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  search_tsv   tsvector GENERATED ALWAYS AS (
                 to_tsvector('simple', f_unaccent(coalesce(title, '') || ' ' || coalesce(body, '') || ' ' || coalesce(author_handle, '')))
               ) STORED,
  UNIQUE (platform, external_id)
);
CREATE INDEX ix_posts_published ON posts (platform, published_at DESC);
CREATE INDEX ix_posts_tsv ON posts USING gin (search_tsv);
CREATE INDEX ix_posts_body_trgm ON posts USING gin (f_unaccent(body) gin_trgm_ops);

CREATE TABLE case_posts (
  case_id      uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  post_id      uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  matched_terms text[] NOT NULL DEFAULT '{}',
  relevance    real,                            -- 0..1, agent's judgement
  sentiment    real,                            -- -1..1
  tags         text[] NOT NULL DEFAULT '{}',    -- complaint, praise, question, news, ...
  note         text,
  first_run_id uuid REFERENCES runs(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (case_id, post_id)
);
CREATE INDEX ix_case_posts_case_created ON case_posts (case_id, created_at DESC);

CREATE TABLE comments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id      uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  parent_id    uuid REFERENCES comments(id) ON DELETE CASCADE,
  platform     text NOT NULL REFERENCES platforms(code),
  external_id  text NOT NULL,                   -- platform id, or sha256(post_url|author|body)
  url          text,
  author_handle text,
  author_name  text,
  body         text NOT NULL,
  published_at timestamptz,
  metrics      jsonb NOT NULL DEFAULT '{}',
  relevance    real,
  sentiment    real,
  tags         text[] NOT NULL DEFAULT '{}',
  deleted_at   timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  first_run_id uuid REFERENCES runs(id) ON DELETE SET NULL,
  UNIQUE (platform, external_id)
);
CREATE INDEX ix_comments_post ON comments (post_id, published_at);
CREATE INDEX ix_comments_body_trgm ON comments USING gin (f_unaccent(body) gin_trgm_ops);

-- ---------------------------------------------------------------- human-in-the-loop

CREATE TABLE alerts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform     text REFERENCES platforms(code),
  case_id      uuid REFERENCES cases(id) ON DELETE CASCADE,
  run_id       uuid REFERENCES runs(id) ON DELETE SET NULL,
  kind         text NOT NULL CHECK (kind IN ('login', 'captcha', '2fa', 'blocked', 'ui_changed',
                                             'rate_limited', 'vpn_down', 'error', 'other')),
  message      text NOT NULL,                   -- what the agent sees and what it needs
  screenshot_key text,
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'dismissed')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  resolved_by  text,
  resolved_at  timestamptz,
  resolution_note text                          -- copied into shared/platforms/<p>.md by the agent
);
CREATE INDEX ix_alerts_open ON alerts (created_at) WHERE status = 'open';

-- Opening a platform alert pauses that platform for every case; resolving the last one resumes it.
CREATE FUNCTION alerts_sync_platform() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.platform IS NULL OR NEW.kind IN ('rate_limited', 'error', 'other') THEN
    RETURN NEW;
  END IF;
  IF NEW.status = 'open' THEN
    UPDATE platforms SET status = 'needs_human', status_reason = NEW.kind || ': ' || left(NEW.message, 200),
                         status_changed_at = now()
     WHERE code = NEW.platform AND status = 'ok';
  ELSIF NOT EXISTS (SELECT 1 FROM alerts WHERE platform = NEW.platform AND status = 'open' AND id <> NEW.id) THEN
    UPDATE platforms SET status = 'ok', status_reason = NULL, status_changed_at = now()
     WHERE code = NEW.platform AND status = 'needs_human';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_alerts_sync_platform AFTER INSERT OR UPDATE OF status ON alerts
  FOR EACH ROW EXECUTE FUNCTION alerts_sync_platform();

-- ---------------------------------------------------------------- CRM entry point

-- Idempotent upsert of a case (+ its CRM terms) by CRM refs. Returns the case id.
--   SELECT upsert_case('crm-client-1', 'AIK Banka', 'crm-case-7', 'AIK Banka — brend',
--                      p_terms => '[{"term":"AIK banka","kind":"alias"},{"term":"#aikbanka","kind":"hashtag"}]');
-- Terms from CRM are added/updated, never deleted here (retire them explicitly).
CREATE FUNCTION upsert_case(
  p_client_ref  text,
  p_client_name text,
  p_case_ref    text,
  p_name        text,
  p_type        text    DEFAULT 'brand_monitoring',
  p_description text    DEFAULT NULL,
  p_platforms   text[]  DEFAULT NULL,
  p_interval_minutes integer DEFAULT NULL,
  p_priority    integer DEFAULT NULL,
  p_status      text    DEFAULT NULL,
  p_terms       jsonb   DEFAULT '[]'
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_client uuid;
  v_case   uuid;
  v_slug   text;
  t        jsonb;
BEGIN
  IF coalesce(trim(p_name), '') = '' THEN RAISE EXCEPTION 'p_name is required'; END IF;
  -- NULL refs would never match ON CONFLICT / lookup and silently create duplicates.
  IF coalesce(trim(p_client_ref), '') = '' THEN RAISE EXCEPTION 'p_client_ref is required'; END IF;
  IF coalesce(trim(p_case_ref), '') = '' THEN RAISE EXCEPTION 'p_case_ref is required'; END IF;
  IF jsonb_typeof(p_terms) <> 'array' THEN RAISE EXCEPTION 'p_terms must be a JSON array'; END IF;

  INSERT INTO clients (external_ref, name) VALUES (p_client_ref, p_client_name)
  ON CONFLICT (external_ref) DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_client;

  SELECT id INTO v_case FROM cases WHERE client_id = v_client AND external_ref = p_case_ref;

  IF v_case IS NULL THEN
    v_slug := trim(BOTH '-' FROM regexp_replace(lower(unaccent(p_name)), '[^a-z0-9]+', '-', 'g'));
    v_slug := left(v_slug, 40) || '-' || substr(md5(random()::text), 1, 6);
    INSERT INTO cases (client_id, external_ref, slug, type, name, description, platforms,
                       interval_minutes, priority, status)
    VALUES (v_client, p_case_ref, v_slug, coalesce(p_type, 'brand_monitoring'), p_name, p_description,
            coalesce(p_platforms, ARRAY['instagram', 'reddit']), coalesce(p_interval_minutes, 180),
            coalesce(p_priority, 100), coalesce(p_status, 'active'))
    RETURNING id INTO v_case;
  ELSE
    UPDATE cases SET
      name             = p_name,
      type             = coalesce(p_type, type),
      description      = coalesce(p_description, description),
      platforms        = coalesce(p_platforms, platforms),
      interval_minutes = coalesce(p_interval_minutes, interval_minutes),
      priority         = coalesce(p_priority, priority),
      status           = coalesce(p_status, status)
    WHERE id = v_case;
  END IF;

  FOR t IN SELECT * FROM jsonb_array_elements(p_terms) LOOP
    INSERT INTO case_terms (case_id, term, kind, lang, platforms, weight, metadata, origin, status)
    VALUES (v_case, t->>'term', coalesce(t->>'kind', 'keyword'), t->>'lang',
            CASE WHEN t ? 'platforms' THEN ARRAY(SELECT jsonb_array_elements_text(t->'platforms')) END,
            coalesce((t->>'weight')::real, 1.0), coalesce(t->'metadata', '{}'), 'crm', 'active')
    ON CONFLICT (case_id, kind, lower(term)) DO UPDATE SET
      lang = EXCLUDED.lang, platforms = EXCLUDED.platforms, weight = EXCLUDED.weight,
      metadata = case_terms.metadata || EXCLUDED.metadata, origin = 'crm', status = 'active';
  END LOOP;

  RETURN v_case;
END $$;

-- ---------------------------------------------------------------- convenience views

CREATE VIEW v_case_overview AS
SELECT c.id, cl.name AS client, c.name, c.type, c.status, c.platforms, c.interval_minutes,
       c.next_run_at, c.last_run_at, c.last_run_status,
       (SELECT count(*) FROM case_terms t WHERE t.case_id = c.id AND t.status <> 'retired') AS terms,
       (SELECT count(*) FROM case_terms t WHERE t.case_id = c.id AND t.origin = 'agent' AND t.status <> 'retired') AS agent_terms,
       (SELECT count(*) FROM case_posts cp WHERE cp.case_id = c.id) AS posts,
       (SELECT count(*) FROM case_posts cp WHERE cp.case_id = c.id AND cp.created_at > now() - interval '24 hours') AS posts_24h
FROM cases c JOIN clients cl ON cl.id = c.client_id;

CREATE VIEW v_open_alerts AS
SELECT a.id, a.created_at, a.platform, a.kind, c.name AS case_name, a.message, a.screenshot_key
FROM alerts a LEFT JOIN cases c ON c.id = a.case_id
WHERE a.status = 'open'
ORDER BY a.created_at;
