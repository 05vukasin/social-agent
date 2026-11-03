-- 0002_web — the open web (news portals, forums, blogs, reviews) as a platform.
-- Articles/threads are posts with platform='web'; comments under articles are comments.

INSERT INTO platforms (code, name, min_interval_minutes)
VALUES ('web', 'Web (vesti, portali, forumi)', 30)
ON CONFLICT (code) DO NOTHING;

-- Domain of the outlet for web posts (n1info.rs, blic.rs ...); NULL for social platforms.
ALTER TABLE posts ADD COLUMN source_domain text;
CREATE INDEX ix_posts_source_domain ON posts (source_domain, published_at DESC) WHERE source_domain IS NOT NULL;

-- Web source kinds: site (domain to search within), forum, rss feed.
ALTER TABLE case_sources DROP CONSTRAINT case_sources_kind_check;
ALTER TABLE case_sources ADD CONSTRAINT case_sources_kind_check
  CHECK (kind IN ('own_account', 'account', 'hashtag', 'subreddit', 'group', 'page', 'search',
                  'url', 'tagged', 'location', 'site', 'forum', 'rss'));

-- New cases monitor the web by default.
ALTER TABLE cases ALTER COLUMN platforms SET DEFAULT ARRAY['web', 'instagram', 'reddit'];

-- upsert_case: new cases default to web + instagram + reddit.
CREATE OR REPLACE FUNCTION upsert_case(
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
            coalesce(p_platforms, ARRAY['web', 'instagram', 'reddit']), coalesce(p_interval_minutes, 180),
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
