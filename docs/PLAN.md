# social-agent — plan i odluke

Ovaj dokument beleži sve dogovorene odluke (iz razgovora za dizajn) i roadmap po fazama.

## 1. Cilj

- **Praćenje brenda i tema na društvenim mrežama.** Prvi klijent je AIK Banka: treba naći **svaki post i komentar** koji ih pominje, na svim mrežama.
- **Sistem je generički.** Slučajeve (cases) puni CRM klijenta ili čovek. Slučajevi mogu biti različitih tipova (`brand_monitoring`, `campaign`, `person`, `complaint`...).
- **Ovo je odvojen proizvod**, nije integrisan sa `sada` projektom. Iz `sada` preuzimamo samo obrasce: slučaj sa ključnim rečima, interval i dispatcher.
- **Claude radi u pravom browseru.** Skroluje Instagram, Reddit i ostale mreže kao čovek, da bi feed bio što potpuniji. Prikupljanje ide kroz browser, a ne preko API-ja.

## 2. Arhitektura

| Komponenta | Odluka |
|---|---|
| Server | Jedan Hetzner Cloud server, x86, Ubuntu 24.04 (CPX32 ili CX33: 4 vCPU, 8 GB) |
| Desktop | Minimalan XFCE + TigerVNC na `:1`, samo `127.0.0.1` |
| Browser | Google Chrome, trajni profil `/home/agent/chrome-profile`, autostart, CDP `127.0.0.1:9222` |
| Upravljanje browserom | Claude in Chrome ekstenzija i/ili DevTools/Playwright MCP preko CDP-a na istom Chrome-u (biramo u fazi 3) |
| Claude Code | Native instalacija za korisnika `agent`, login preko **subskripcije** |
| Baza | Postgres 17 (+pgvector) u Docker-u, `127.0.0.1:5432` |
| Objekti (S3) | Garage (S3-kompatibilan) u Docker-u na istom serveru, `127.0.0.1:3900` (MinIO CE se više ne održava) |
| Pristup spolja | Samo SSH (port 22). VNC, Postgres i S3 idu preko SSH tunela. Tailscale je opcija za kasnije. |
| Tajne | `/etc/social-agent/.env` (600), generiše se na serveru, nikad u repou |
| Setup | Ovaj repo: idempotentne `.sh` skripte i SQL migracije, bez aplikativnog koda |

Posledice subskripcije:
- Runovi idu **strogo jedan po jedan** (`flock`), jer postoje jedan limit i jedan Chrome profil.
- `rate_limited` nije neuspeh: dispatcher pauzira do vremena resetovanja i šalje jedno obaveštenje.

## 3. Model podataka

| Tabela | Svrha |
|---|---|
| `platforms` | instagram, reddit, facebook, x, linkedin, tiktok. Stanje naloga **po platformi** (`ok` / `needs_human` / `disabled`), jer je Chrome profil zajednički. |
| `clients` | Klijent, sa `external_ref` iz CRM-a |
| `cases` | Slučaj: `type`, `name`, `description`, `platforms[]`, raspored (`interval_minutes`, `active_from/to`, `priority`), stanje dispatchera (`next_run_at`, `last_run_*`) |
| `case_terms` | Pojmovi koji bliže određuju temu: `kind` (alias, product, person, hashtag, account, exclude...), `parent_id` (stablo), `lang`, `platforms`, `weight`, `metadata` JSONB, `origin` (crm/human/agent), `status` (probation/active/retired), `rationale`, `evidence` |
| `case_sources` | Gde se gleda po mreži: nalozi, heštegovi, subredditovi, grupe, stranice, pretrage |
| `posts` | Globalni post (dedup `platform + external_id`), screenshot u S3, FTS i trigram indeksi |
| `case_posts` | Veza post–slučaj: `matched_terms`, `relevance`, `sentiment`, `tags` |
| `comments` | Komentari i odgovori (`parent_id`), dedup `platform + external_id` |
| `runs` / `run_events` | Svaki `claude -p` run (status, `session_id`, summary, stats) i log svih hook događaja |
| `alerts` | Human-in-the-loop: Claude opisuje problem, čovek ga rešava |

Pravila u bazi:
- **Agent ima najviše 10** svojih aktivnih ili probnih pojmova po slučaju (trigger). Pojmove iz CRM-a Claude ne briše; to je pravilo iz skilla, ne iz baze.
- **CRM ulaz:** `upsert_case(...)` je idempotentna funkcija. CRM pojmove dodaje i ažurira, nikad ih ne briše.
- **Alerti:** otvoren alert na platformi pauzira tu platformu za sve slučajeve, a rešen poslednji alert je vraća (trigger).
- **Vlasništvo nad poljima:** definiciju slučaja menjaju CRM i čovek, a stanje i rezultate agent i dispatcher.

## 4. Izvršavanje

- **Dispatcher:** jedan cron red svakog minuta, `flock -n` + `dispatch.sh`. Uzima prvi slučaj kod kog je `next_run_at <= now()` (po `priority`), poštuje aktivni prozor i pauzirane platforme, i radi **jedan po jedan**.
- **Jedan slučaj je jedna sveža `claude -p` sesija.** Nema `--resume`, kontekst je uvek čist. `session_id` se čuva u `runs`, za ručno ispitivanje kasnije.
- **Prompt se sastavlja iz baze:** skill za tip slučaja (`case-<type>`), svi aktivni pojmovi i izvori, otvoreni alerti.
- **Folder slučaja je dugotrajna memorija:**
  ```
  /srv/social-agent/cases/<slug>/
  ├── CLAUDE.md          # generiše dispatcher iz baze (cilj, pojmovi, izvori)
  ├── NOTES.md           # Claude-ovo pamćenje: šta radi, šta ne, šum, tajming
  ├── platforms/*.md     # strategija po mreži za ovaj slučaj
  ├── scripts/           # alati koje Claude sam napiše
  ├── .claude/skills/    # skilovi specifični za slučaj
  ├── runs/<timestamp>/  # log i summary runa
  └── .git/              # commit posle svakog runa (istorija + revert)
  ```
  Opšte znanje o mrežama, zajedničko za sve slučajeve: `/srv/social-agent/shared/platforms/*.md`.
- **Claude može da dodaje pojmove i izvore** kao `probation`, sa obrazloženjem i dokazima. Promoviše ih ili gasi skripta prema prinosu (relevantni nalazi), ne Claude.
- **Hookovi samo beleže i zatvaraju, ništa ne blokiraju:**
  - `PostToolUse` upisuje u `run_events`;
  - `Stop` zatvara run, postavlja `next_run_at` i radi git commit foldera.
- **Skilovi su preporuka, ne kavez.** Claude slobodno koristi `psql`, bash i browser. Preporučeni put su `agentctl-*` bash skripte.
- **Zaštite bez ograničavanja:** DB rola `sa_agent` nema DDL (`DROP`/`TRUNCATE` šeme), a noćni backup ide u S3.
- **Watchdog:** `timeout` po runu (npr. 30 min). Posle 3 uzastopna neuspeha slučaj se pauzira i otvara se alert.

## 5. Alert sistem (human-in-the-loop)

1. Claude naiđe na login, captcha proveru, 2FA, blokadu ili promenu UI-ja i upiše `alerts` red sa porukom i screenshotom.
2. Platforma prelazi u `needs_human` i dispatcher je preskače za sve slučajeve. Ostale mreže rade normalno.
3. Čovek se poveže preko VNC-a, reši problem i označi alert kao `resolved`, sa `resolution_note`.
4. Platforma se vraća u `ok`. Agent uzima prvi sledeći slučaj i nastavlja kao da se ništa nije desilo.
5. `resolution_note` agent prepisuje u `shared/platforms/<p>.md`, da bi učio iz toga.

Obaveštenja (Telegram, email ili drugo) i dnevni health izveštaj idu u fazu 3.

## 6. Mreže

| Mreža | Faza | Napomena |
|---|---|---|
| Instagram | 3 (prva) | Nema pretrage teksta: zvanični nalozi, heštegovi, tagged objave, praćeni nalozi |
| Reddit | 3 (prva) | Pretraga i subredditovi. Najblaži prema automatizaciji. |
| Facebook | 3 | Stranice, grupe, pretraga (traži login) |
| X | 3 | Pretraga (traži login) |
| LinkedIn | 3 | Najagresivniji prema automatizaciji: najređi interval, najoprezniji nalog |
| TikTok | kasnije | Unet u `platforms`, ali isključen |

## 7. Rizici

| Rizik | Mera |
|---|---|
| IG/LinkedIn/FB blokiraju datacenter IP (Hetzner) | Faza 2: izlaz Chrome-a kroz firmin ruter u Srbiji |
| Blokada naloga | Posebni nalozi (nikad lični), umeren tempo, pravila tempa u `shared/platforms/*.md` |
| Limit subskripcije | Jedan run u isto vreme, `rate_limited` pauza, aktivni prozor (npr. 07–23h) |
| Drift ključnih reči | Najviše 10 agent pojmova, probni status, ocena po prinosu, audit u bazi i git |
| Sve je na jednom serveru | Hetzner Backups + noćni `pg_dump` i folderi slučajeva u S3. Preporuka: i kopija van servera. |
| UI mreža se menja | Alert `ui_changed` + beleške po platformi |

## 8. VPN izlaz (faza 2)

- Chrome izlazi preko **firminog rutera u Srbiji**, kroz firmin VPN.
- **Split tunnel:** kroz tunel ide samo saobraćaj korisnika `agent` i Chrome-a. SSH, Claude API, Postgres i S3 idu direktno.
- **Kill switch:** bez tunela nema browsera, a otvara se alert `vpn_down`. Chrome ne sme da pređe na Hetzner IP.
- **Čeka se IT.** Potrebni su: protokol (preporuka je WireGuard peer samo za server), auth bez interaktivne 2FA, i dozvoljen izlaz na internet kroz kancelariju.
- **Rizik reputacije firmine IP adrese** (captcha provere kolegama): IT mora da zna i da odobri.

## 9. Roadmap

### Faza 1 — setup servera (ovaj repo)
- [x] `setup.sh` orkestrator + idempotentni moduli (`check`/`apply`)
- [x] Osnova: paketi, timezone, ufw (samo 22), fail2ban, swap
- [x] Tajne u `/etc/social-agent/.env`
- [x] Korisnik `agent`, SSH samo preko ključa
- [x] Docker
- [x] XFCE + TigerVNC (localhost)
- [x] Chrome sa trajnim profilom + autostart + CDP
- [x] Claude Code (native)
- [x] Postgres + rola `sa_agent`
- [x] Garage S3 + bucket + rclone remote `s3`
- [x] Migracije (`migrations/*.sql`, `schema_migrations`)
- [x] Okruženje agenta (`agent.env`, `.pgpass`)
- [x] Noćni backup u S3
- [ ] Prvo pokretanje na pravom serveru i ispravke
- [ ] Ručno: login u Claude (subskripcija), login na mreže, Claude in Chrome ekstenzija

### Faza 2 — VPN izlaz
- [ ] Prikupiti od IT-a: tip VPN-a, ruter, način autentifikacije, izlaz na internet
- [ ] `modules/opt-vpn.sh`: klijent, rutiranje po korisniku (split tunnel), kill switch
- [ ] Health check izlaza i alert `vpn_down`

### Faza 3 — agent
- [ ] Posebni nalozi po mreži, upisani u `platforms.account_handle`
- [ ] `bin/agentctl-*` (bash + psql): `case-show`, `post-save`, `shot-save`, `term-propose`, `source-propose`, `alert-open`, `run-finish`
- [ ] `bin/dispatch.sh`: izbor sledećeg slučaja, generisanje `CLAUDE.md`, `claude -p`, timeout, upis runa
- [ ] Cron: dispatcher svakog minuta (`flock`)
- [ ] Skilovi: `case-brand_monitoring` i `platform-<x>` (procedure skrolovanja i čitanja komentara)
- [ ] Hookovi: `PostToolUse` → `run_events`, `Stop` → zatvaranje runa + git commit
- [ ] Ocena prinosa probnih pojmova i izvora (skripta)
- [ ] Izbor kanala za upravljanje browserom (ekstenzija vs DevTools MCP)
- [ ] Obaveštenja (kanal TBD) + dnevni health izveštaj
- [ ] Način na koji krajnji korisnici vide rezultate (dashboard / izvoz u CRM)
