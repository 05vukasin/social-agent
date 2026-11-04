# Prvi login posle setupa

Redosled koraka posle uspešnog `./setup.sh`.

## 1. Lozinke

Na serveru:

```bash
sudo cat /etc/social-agent/.env
```

Biće ti potrebni `AGENT_PASSWORD` (sudo za korisnika `agent`), `VNC_PASSWORD`, `POSTGRES_PASSWORD` i `PG_AGENT_PASSWORD`.

## 2. SSH tunel

Sa svog računara:

```bash
ssh -L 5901:localhost:5901 -L 5432:localhost:5432 -L 3900:localhost:3900 agent@SERVER
```

Dok je ova sesija otvorena, na svom računaru imaš:

| Port | Servis |
|---|---|
| `localhost:5901` | desktop servera (VNC) |
| `localhost:5432` | Postgres |
| `localhost:3900` | S3 (Garage) |

## 3. Desktop (VNC)

1. Otvori VNC klijent (TigerVNC Viewer, Remmina...) na `localhost:5901`.
2. Unesi lozinku `VNC_PASSWORD`.
3. Dobijaš XFCE desktop korisnika `agent`. **Agent Chrome** se otvara sam:
   - profil: `/home/agent/chrome-profile`
   - CDP: `127.0.0.1:9222`
   - ako je zatvoren, pokreni ga ikonicom „Agent Chrome“ na desktopu ili komandom `agent-chrome`.

## 4. Nalozi na mrežama

U Agent Chrome-u se ručno uloguj na Instagram, Reddit, Facebook, X i LinkedIn, **posebnim nalozima, ne ličnim**. Logini ostaju u profilu i preživljavaju restart. Za 2FA, ako je moguće, koristi aplikaciju ili mail kojima tim ima pristup, jer će to trebati i kad sistem otvori alert.

## 5. Claude in Chrome ekstenzija

U Agent Chrome-u otvori Chrome Web Store, instaliraj **Claude** ekstenziju i uloguj se istim claude.ai nalogom (subskripcija).

## 6. Claude Code

Otvori terminal na desktopu (XFCE Terminal):

```bash
claude            # pa /login → izaberi subskripciju i prođi login u browseru
```

Provera:

```bash
claude -p "reci zdravo"
```

## 7. Baza

**Sa laptopa** (DBeaver ili drugi klijent, preko tunela):

| | |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Baza | `social_agent` |
| Korisnik | `sa_admin` (vlasnik, migracije) ili `sa_agent` (samo podaci) |
| Lozinka | `POSTGRES_PASSWORD` ili `PG_AGENT_PASSWORD` |

**Na serveru, kao `agent`:** okruženje je već podešeno, dovoljno je `psql`.

```sql
SELECT * FROM v_case_overview;
SELECT * FROM v_open_alerts;
SELECT code, status, status_reason FROM platforms;
```

### Prvi slučaj

```sql
SELECT upsert_case('aik', 'AIK Banka', 'aik-brand', 'AIK Banka — brend',
  p_platforms => ARRAY['instagram','reddit'],
  p_terms => '[{"term":"AIK banka","kind":"alias"},{"term":"АИК банка","kind":"alias","lang":"sr-Cyrl"},{"term":"#aikbanka","kind":"hashtag"},{"term":"AIK","kind":"exclude","metadata":{"note":"sam AIK hvata fudbalski klub — tražiti uz kontekst banke"}}]');
```

`upsert_case` je idempotentan: ponovni poziv sa istim `aik` / `aik-brand` ažurira slučaj i dodaje nove pojmove, ali postojeće ne briše.

## 8. S3

Kao `agent` ili `root`:

```bash
rclone lsf s3:social-agent
```

Backupi su u `s3:social-agent/backups/`: noćni `pg_dump` i arhive foldera slučajeva.

```bash
rclone lsf -R s3:social-agent/backups/
```

## 9. Kad nešto ne radi

```bash
# desktop / VNC
systemctl status vnc-agent
journalctl -u vnc-agent -n 100

# postgres + garage
cd /opt/social-agent && docker compose -p social-agent ps
docker compose -p social-agent logs --tail 100 postgres
docker compose -p social-agent logs --tail 100 garage

# stanje svih modula / ponovni setup (urađeno se preskače)
sudo ./setup.sh --status
sudo ./setup.sh
sudo ./setup.sh --force 20-desktop   # ponovo primeni jedan modul
```

## Zdravlje sistema i alerti

`bin/healthcheck.sh` se pokreće na svakih 5 minuta (cron, korisnik `agent`) i upisuje stanje svake komponente u `system_health`: `claude_auth`, `chrome`, `desktop`, `postgres`, `s3`, `disk`, `dispatcher`, `runs`, `backup`.

- Kad komponenta pređe u **error**, otvara se **jedan** alert u tabeli `alerts`. Kad se oporavi, alert se sam zatvara (`resolved_by = 'healthcheck'`).
- **Claude izlogovan.** `claude auth status` ne troši tokene. Dok je `claude_auth` u stanju error, dispatcher ne pokreće runove. Posle `/login` healthcheck u roku od 5 minuta vraća stanje u ok i runovi se nastavljaju sami. Ako se logout otkrije usred runa, run dobija status `auth_error`, a to se slučaju ne računa kao greška.
- **Chrome ugašen.** Healthcheck ga sam ponovo pokreće (status warn). Ako restart ne uspe, prelazi u error.
- **Run koji visi** duže od 70 minuta bez procesa zatvara se kao `incomplete`.

```sql
SELECT * FROM v_system_health;   -- stanje svih komponenti
SELECT * FROM v_open_alerts;     -- šta čeka čoveka
-- ručno zatvaranje alerta za platformu (npr. posle rešene captcha provere):
UPDATE alerts SET status = 'resolved', resolved_by = 'ime', resolved_at = now(), resolution_note = 'šta je urađeno' WHERE id = '...';
```

Logovi: `/srv/social-agent/logs/dispatch.log`, `/srv/social-agent/logs/health.log`.
