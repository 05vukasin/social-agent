-- 0003_agent_api — write path for the agent (called by bin/agentctl).
-- Rules (dedup, URL normalization, counters) live here, not in prompts.

-- Canonical URL: lowercase scheme+host, no fragment, no tracking params, no trailing slash.
CREATE FUNCTION normalize_url(u text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(
                 regexp_replace(trim(u), '#.*$', ''),
               '([?&])(utm_[^=&]*|fbclid|gclid|igshid|mc_[a-z]+|ref|ref_src|share_id)=[^&]*', '\1', 'gi'),
             '[?&]+$', ''),
           '\?&+', '?'),
         '/+$', '')
$$;

CREATE FUNCTION url_domain(u text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(lower(substring(u FROM '^[a-zA-Z]+://([^/?#:]+)')), '^www\.', '')
$$;

-- Save (upsert) one post with optional comments and link it to the case.
-- p: {platform, url, external_id?, title?, body?, author_name?, author_handle?, author_url?,
--     source_domain?, published_at?, lang?, metrics?, media?, screenshot_key?, raw?,
--     matched_terms?[], relevance?, sentiment?, tags?[], note?,
--     comments?: [{external_id?, author_name?, author_handle?, body, published_at?, url?,
--                  metrics?, relevance?, sentiment?, tags?[]}]}
-- Returns {post_id, new_post, new_case_link, new_comments}.
CREATE FUNCTION save_post(p_case uuid, p_run uuid, p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_url      text := normalize_url(p->>'url');
  v_platform text := coalesce(p->>'platform', 'web');
  v_ext      text;
  v_post     uuid;
  v_new_post boolean;
  v_new_link boolean := false;
  v_new_comments integer := 0;
  c          jsonb;
  v_cext     text;
  v_cnew     boolean;
BEGIN
  IF coalesce(v_url, '') = '' THEN RAISE EXCEPTION 'url is required'; END IF;
  v_ext := coalesce(nullif(p->>'external_id', ''), encode(sha256(convert_to(lower(v_url), 'UTF8')), 'hex'));

  INSERT INTO posts AS t (platform, external_id, url, author_handle, author_name, author_url, title, body,
                          lang, published_at, metrics, media, screenshot_key, raw, source_domain)
  VALUES (v_platform, v_ext, v_url, p->>'author_handle', p->>'author_name', p->>'author_url',
          p->>'title', left(p->>'body', 50000), p->>'lang', (p->>'published_at')::timestamptz,
          coalesce(p->'metrics', '{}'), coalesce(p->'media', '[]'), p->>'screenshot_key', p->'raw',
          coalesce(p->>'source_domain', CASE WHEN v_platform = 'web' THEN url_domain(v_url) END))
  ON CONFLICT (platform, external_id) DO UPDATE SET
    last_seen_at   = now(),
    title          = coalesce(EXCLUDED.title, t.title),
    body           = CASE WHEN length(coalesce(EXCLUDED.body, '')) > length(coalesce(t.body, '')) THEN EXCLUDED.body ELSE t.body END,
    author_name    = coalesce(EXCLUDED.author_name, t.author_name),
    author_handle  = coalesce(EXCLUDED.author_handle, t.author_handle),
    published_at   = coalesce(t.published_at, EXCLUDED.published_at),
    metrics        = t.metrics || EXCLUDED.metrics,
    screenshot_key = coalesce(EXCLUDED.screenshot_key, t.screenshot_key),
    deleted_at     = NULL
  RETURNING id, (xmax = 0) INTO v_post, v_new_post;

  INSERT INTO case_posts (case_id, post_id, matched_terms, relevance, sentiment, tags, note, first_run_id)
  VALUES (p_case, v_post,
          coalesce(ARRAY(SELECT jsonb_array_elements_text(p->'matched_terms')), '{}'),
          (p->>'relevance')::real, (p->>'sentiment')::real,
          coalesce(ARRAY(SELECT jsonb_array_elements_text(p->'tags')), '{}'),
          p->>'note', p_run)
  ON CONFLICT (case_id, post_id) DO UPDATE SET
    matched_terms = ARRAY(SELECT DISTINCT unnest(case_posts.matched_terms || EXCLUDED.matched_terms)),
    relevance     = coalesce(EXCLUDED.relevance, case_posts.relevance),
    sentiment     = coalesce(EXCLUDED.sentiment, case_posts.sentiment),
    tags          = ARRAY(SELECT DISTINCT unnest(case_posts.tags || EXCLUDED.tags)),
    note          = coalesce(EXCLUDED.note, case_posts.note)
  RETURNING (xmax = 0) INTO v_new_link;

  FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p->'comments', '[]')) LOOP
    CONTINUE WHEN coalesce(c->>'body', '') = '';
    v_cext := coalesce(nullif(c->>'external_id', ''),
                       encode(sha256(convert_to(v_post::text || '|' || coalesce(c->>'author_handle', c->>'author_name', '') || '|' || (c->>'body'), 'UTF8')), 'hex'));
    INSERT INTO comments AS t (post_id, platform, external_id, url, author_handle, author_name, body,
                               published_at, metrics, relevance, sentiment, tags, first_run_id)
    VALUES (v_post, v_platform, v_cext, c->>'url', c->>'author_handle', c->>'author_name', c->>'body',
            (c->>'published_at')::timestamptz, coalesce(c->'metrics', '{}'),
            (c->>'relevance')::real, (c->>'sentiment')::real,
            coalesce(ARRAY(SELECT jsonb_array_elements_text(c->'tags')), '{}'), p_run)
    ON CONFLICT (platform, external_id) DO UPDATE SET last_seen_at = now(), metrics = t.metrics || EXCLUDED.metrics
    RETURNING (xmax = 0) INTO v_cnew;
    IF v_cnew THEN v_new_comments := v_new_comments + 1; END IF;
  END LOOP;

  IF p_run IS NOT NULL THEN
    UPDATE runs SET new_posts = new_posts + (CASE WHEN v_new_link THEN 1 ELSE 0 END),
                    new_comments = new_comments + v_new_comments
     WHERE id = p_run;
  END IF;

  RETURN jsonb_build_object('post_id', v_post, 'new_post', v_new_post,
                            'new_case_link', v_new_link, 'new_comments', v_new_comments);
END $$;

-- Has the case already seen this URL? Lets the agent skip re-reading known articles.
CREATE FUNCTION case_has_url(p_case uuid, p_url text) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM case_posts cp JOIN posts po ON po.id = cp.post_id
     WHERE cp.case_id = p_case AND po.url = normalize_url(p_url))
$$;

-- Platforms a case may run on right now: listed on the case, enabled, account ok.
CREATE FUNCTION case_runnable_platforms(p_case uuid) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT coalesce(array_agg(pl.code ORDER BY pl.code), '{}')
    FROM cases c JOIN platforms pl ON pl.code = ANY (c.platforms)
   WHERE c.id = p_case AND pl.enabled AND pl.status = 'ok'
$$;
