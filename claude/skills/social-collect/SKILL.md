---
name: social-collect
description: Procedure for one scheduled monitoring run of a case (brand/topic monitoring across web and social platforms). Use whenever a prompt says it is a scheduled run for a case with a RUN_ID, or when asked to collect posts/articles/comments for a case.
---

# Run slučaja — procedura

You are a monitoring analyst. Your job in this run: find **everything new and relevant** about the
case subject on the allowed platforms, save it to the database, and get better at it over time.
The case definition is in `CLAUDE.md` (generated from the DB). Write summaries and notes in **Serbian (latinica)**.

## 1. Učitaj pamćenje (uvek prvo)

1. Read `NOTES.md` (your long-term memory for this case) and `platforms/<p>.md` for every allowed platform.
2. Read the shared platform notes listed in `CLAUDE.md` (`.../shared/platforms/<p>.md`).
3. Look at "Poslednji runovi" in `CLAUDE.md`: what was found, what was planned for next time.
4. Make a short plan with TodoWrite: which platforms, which queries/sources, in what order.
   Prefer what NOTES says works; drop what NOTES says is noise.

## 2. Prikupljanje — po platformi

For each allowed platform, invoke the skill `platform-<name>` (e.g. `platform-web`) and follow it.
Platforms not in the allowed list are paused (waiting for a human) — do not touch them.

Rules that apply everywhere:

- **Relevance first.** The subject is what `CLAUDE.md` describes, not the literal string.
  Terms of kind `exclude` describe what is NOT the subject (e.g. "AIK" the football club).
  Judge each item: is it really about the subject? Score `relevance` 0..1. Save items ≥ 0.4;
  skip the rest but remember the noise pattern for NOTES.
- **No duplicates.** Before reading an item in depth run `agentctl seen <url>`; if `yes`, skip it
  (exception: revisit known items only to pick up new comments when the platform skill says so).
- **Save as you go**, not at the end — a run can be cut off. Batch 1–10 items per `agentctl post-save`.
- **Facts only from the page.** Never invent dates, authors or numbers. Unknown → omit the field.
- **Dates**: ISO 8601 with offset (`2026-11-03T14:20:00+01:00`). Convert relative dates
  ("pre 3 sata", "juče") using the current time from the prompt.

### Format za `agentctl post-save` (stdin, JSON objekat ili niz)

```json
{
  "platform": "web",
  "url": "https://www.example.rs/vesti/clanak-123",
  "title": "Naslov",
  "body": "Ceo tekst ili najvažniji delovi (do ~20k karaktera)",
  "author_name": "Ime autora",
  "source_domain": "example.rs",
  "published_at": "2026-11-03T10:15:00+01:00",
  "lang": "sr-Latn",
  "matched_terms": ["AIK banka"],
  "relevance": 0.9,
  "sentiment": -0.4,
  "tags": ["vest", "kredit"],
  "note": "Jedna rečenica: zašto je bitno za slučaj.",
  "comments": [
    {"author_name": "korisnik123", "body": "tekst komentara", "published_at": "2026-11-03T11:00:00+01:00", "sentiment": -0.6}
  ]
}
```

`sentiment` is toward the case subject (-1 vrlo negativno … +1 vrlo pozitivno). Useful `tags`:
`vest`, `saopštenje`, `reklama`, `žalba`, `pohvala`, `pitanje`, `kriza`, `proizvod`, `zaposleni`,
`regulativa`, `konkurencija`, `prevara`, `recenzija`.

**How to pass JSON:** write it with the Write tool to a file inside the case folder
(`runs/batch-1.json`, `runs/batch-2.json`, …) and run `agentctl post-save --file runs/batch-1.json`.
Every agentctl command that reads stdin accepts `--file <path>`. Heredocs, `<` redirects, `cd … &&`
chains and files outside the case folder are blocked by permissions — don't use them; run each
command on its own, from the case folder.

## 3. Kad nešto blokira

Login wall, captcha you cannot pass, 2FA, account blocked, or the site layout changed so much you
cannot work: **stop working on that platform** and open an alert describing exactly what you see
and what you need:

```bash
agentctl alert captcha web "Google traži captcha na pretrazi vesti; Bing radi. Potrebno: rešiti captcha u Chrome-u."
```

Platform-level alerts pause that platform for all cases until a human resolves it. Continue with
other platforms/sources. Use platform `-` for problems not tied to a platform.

## 4. Učenje (pre kraja)

- **Pojmovi**: if you repeatedly see a sub-topic that clearly matters for the subject (a product
  name, a campaign, a person, a hashtag, a Cyrillic variant), propose it — with evidence:
  write `{"term": "...", "kind": "product", "parent_term": "AIK banka", "rationale": "...", "evidence": ["url1","url2"]}`
  to `runs/term.json`, then `agentctl term-propose --file runs/term.json`.
  Valid kinds: keyword, alias, product, person, organization, event, hashtag, account, location, exclude.
  You can hold at most 10 own terms per case (DB enforces it). Never remove CRM terms.
- **Izvori**: a portal/forum/feed that keeps producing relevant items →
  `{"platform":"web","kind":"site","value":"example.rs","rationale":"..."}` → `runs/source.json` →
  `agentctl source-propose --file runs/source.json`.
  Kinds for web: `site`, `rss`, `forum`, `search`, `url`.
- **NOTES.md** — rewrite it (don't just append) so it stays under ~4000 characters:
  what works (queries, sources, timing), noise patterns to skip, open threads to follow next run,
  quirks. Keep only what will help next time.
- **platforms/<p>.md** — case-specific strategy per platform (best queries, best sources, how far back).
- **shared/platforms/<p>.md** — only general platform knowledge useful for every case
  (e.g. "Google News: when:1d operator works", "blic.rs comments load after scrolling").

## 5. Kraj runa (obavezno)

1. `agentctl stats` to see the totals.
2. Write the run summary in Serbian (markdown, ≤ 15 lines) to `runs/summary.md` and save it with
   `agentctl run-summary --file runs/summary.md`. Shape:
   ```markdown
   **Novo:** 7 članaka, 23 komentara (web).
   **Teme:** ...
   **Ton:** pretežno neutralan; negativno oko ...
   **Izdvojeno:** [naslov](url) — zašto je bitno
   **Sledeći put:** ...
   ```
3. Close browser tabs you opened (leave one blank tab).
4. Your final message: the same summary.

## Budžet

Aim to finish within ~30 minutes. Breadth first (cover all sources briefly), then depth on the most
relevant items. If there is clearly nothing new, finish early — a short run is a good run.
