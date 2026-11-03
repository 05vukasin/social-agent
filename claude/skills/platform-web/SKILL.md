---
name: platform-web
description: How to monitor the open web (news portals, Google News, forums, blogs, RSS) for a case during a scheduled run. Use from social-collect when "web" is an allowed platform.
---

# Platforma: web (vesti, portali, forumi)

Tools: `WebSearch` and `WebFetch` are cheap and fast — use them first. The Chrome tools
(`mcp__claude-in-chrome__*`) give you a real browser for Google News,
JS-heavy portals and comment sections — use them when the cheap tools are not enough.

## Vremenski prozor

- First run for the case (no previous runs in CLAUDE.md): look back **30 days**.
- Later runs: look back to the previous run (use 1 day; 7 days if the last run was long ago).

## Redosled izvora

1. **RSS** (`case_sources` kind `rss`): `curl -sL <feed>` and grep titles/descriptions for the case
   terms (Latin AND Cyrillic). Cheapest source — only open matching items.
2. **Google News** in Chrome, for each main term (in quotes) — Serbian edition:
   `https://news.google.com/search?q=%22AIK%20banka%22%20when%3A1d&hl=sr&gl=RS&ceid=RS%3Asr`
   (`when:1d`, `when:7d`, `when:30d`). Read result titles/sources/times with `get_page_text` or
   `find`; open only new, relevant ones.
3. **Web search** — `WebSearch` with the terms + context words (`"AIK banka" kredit`, `"АИК банка"`),
   and Google in Chrome with time filter when needed:
   `https://www.google.com/search?q=%22AIK+banka%22&tbs=qdr:d&hl=sr&gl=rs` (`qdr:d`/`qdr:w`/`qdr:m`).
   If Google shows a captcha, switch to Bing (`https://www.bing.com/news/search?q=...`) or
   DuckDuckGo — do not fight the captcha; note it in shared notes. Open an alert only if every
   engine is blocked.
4. **Sites** (`case_sources` kind `site`): `site:<domain> "<term>"` search, or the portal's own
   search page in Chrome.
5. **Forums / reviews** (`kind forum`, `url`): open, look for new threads/posts mentioning the subject.

Run several queries per term (Latin + Cyrillic + common misspellings/declensions:
"AIK banke", "AIK banci", "AIK banku"). Serbian declension matters — search for the stem when the
engine allows it.

## Čitanje članka

1. `agentctl seen <url>` → skip if `yes`.
2. `WebFetch` the URL and extract: title, author, published time, full text (main content only),
   and whether the article is really about the subject.
3. If WebFetch fails (paywall, JS, blocked) → open in Chrome, `get_page_text`.
4. **Comments**: many Serbian portals (blic, kurir, novosti, n1, nova, telegraf…) have reader
   comments. If the article is relevant (≥ 0.6) and has comments, open it in Chrome, load the
   comments (scroll / click "prikaži komentare"), and include them in `comments`. Comments are often
   where the real sentiment is.
5. The same story is often republished by several portals — save each URL (they are different
   posts), but mention in `note` that it is a re-publication ("preneto sa …").

Save with `"platform": "web"` and `source_domain` (without `www.`).

## Higijena browsera

Work in one or two tabs; close tabs you opened when done. Don't log into anything on the web.
