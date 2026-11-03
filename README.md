# social-agent

Devops repo za server na kome Claude Code, u pravom Chrome browseru, prati društvene mreže (Instagram, Reddit, Facebook, X, LinkedIn) po slučajevima iz baze. Sve se instalira i podešava idempotentnim `.sh` skriptama i SQL migracijama. Nema aplikativnog koda.

- Plan i sve odluke: [docs/PLAN.md](docs/PLAN.md)
- Šta uraditi posle setupa: [docs/FIRST-LOGIN.md](docs/FIRST-LOGIN.md)

## Server

| | |
|---|---|
| Provajder | Hetzner Cloud |
| Tip | CPX32 ili CX33 (4 vCPU, 8 GB RAM-a), **x86**, ne ARM |
| OS | Ubuntu 24.04 LTS |
| Backups | uključeni (Hetzner Backups) |
| Firewall | samo TCP 22 ulaz |
| SSH ključ | dodat pri kreiranju servera (završava u `/root/.ssh/authorized_keys`) |

## Brzi start

```bash
ssh root@SERVER
git clone https://github.com/05vukasin/social-agent.git /opt/social-agent
cd /opt/social-agent && ./setup.sh
./setup.sh --status
```

Zatim prati [docs/FIRST-LOGIN.md](docs/FIRST-LOGIN.md).

## Moduli

| Modul | Šta radi |
|---|---|
| `00-base` | apt paketi, timezone Europe/Belgrade, ufw (samo SSH), fail2ban, unattended-upgrades, swap |
| `01-env` | generiše `/etc/social-agent/.env` sa nasumičnim lozinkama (samo nedostajuće ključeve) |
| `05-user` | korisnik `agent` (sudo), SSH ključevi, SSH samo preko ključa, `/srv/social-agent` |
| `10-docker` | Docker Engine + compose plugin, rotacija logova |
| `20-desktop` | XFCE + TigerVNC na `:1`, samo `127.0.0.1:5901`, bez screensavera |
| `30-chrome` | Google Chrome, trajni profil `/home/agent/chrome-profile`, autostart, CDP `127.0.0.1:9222` |
| `40-claude` | Claude Code (native) za `agent` + shell okruženje |
| `50-postgres` | Postgres 17 + pgvector u Docker-u na `127.0.0.1:5432`, rola `sa_agent` |
| `55-s3` | Garage (S3) na `127.0.0.1:3900`, bucket, ključ, rclone remote `s3` |
| `60-migrate` | primenjuje `migrations/*.sql` redom, beleži ih u `schema_migrations` |
| `65-agent-env` | `agent.env` + `.pgpass` za korisnika `agent` (`psql` i `rclone` rade bez parametara) |
| `70-backup` | noćni `pg_dump` + folderi slučajeva u `s3:social-agent/backups/` |

### Kako radi idempotentnost

Svaki modul definiše:

```bash
DESCRIPTION="..."
check()  { ... }   # exit 0 = stanje je već tu → modul se preskače
apply()  { ... }   # dovodi server u to stanje; mora biti bezbedno za ponovno pokretanje
```

`setup.sh` za svaki modul prvo pokrene `check`. Ako prolazi, modul se preskače, a ako ne, pokreće `apply` pa ponovo `check`. Zato se `./setup.sh` može pokretati koliko god puta. Kod prvog neuspeha staje, jer kasniji moduli zavise od prethodnih.

```bash
./setup.sh                  # sve što nije urađeno
./setup.sh --status         # samo prikaz stanja
./setup.sh 20-desktop 30    # samo izabrani moduli (prefiks imena)
./setup.sh --force 30       # ponovo primeni modul iako check prolazi
```

### Dodavanje modula

1. Napravi `modules/NN-ime.sh` sa `DESCRIPTION`, `check()` i `apply()`. `NN` određuje redosled.
2. Koristi helpere iz `lib/common.sh`: `apt_install`, `as_agent`, `render`, `compose`, `env_set`, `wait_for`, `listens_on_loopback_only`.
3. Modul sa prefiksom `opt-` (npr. `opt-vpn.sh`) se **ne** pokreće automatski, samo kad je eksplicitno naveden: `./setup.sh opt-vpn`.

## Struktura

```
social-agent/
├── setup.sh                 # orkestrator
├── lib/
│   ├── common.sh            # helperi (log, env, apt, render, compose...)
│   └── run-module.sh        # pokreće jedan modul kao zaseban proces
├── modules/                 # NN-ime.sh, opt-*.sh
├── compose/docker-compose.yml   # postgres + garage
├── templates/               # desktop (VNC, Chrome), garage.toml
├── migrations/              # NNNN_ime.sql
├── bin/                     # migrate.sh, backup.sh, (faza 3: dispatch, agentctl-*)
└── docs/                    # PLAN.md, FIRST-LOGIN.md
```

Na serveru:

| Putanja | Sadržaj |
|---|---|
| `/opt/social-agent` | ovaj repo |
| `/etc/social-agent/.env` | tajne (600, root) |
| `/srv/social-agent/postgres`, `/srv/social-agent/garage` | podaci baze i S3 |
| `/srv/social-agent/cases/<slug>` | folder slučaja, Claude-ova dugotrajna memorija |
| `/srv/social-agent/shared/platforms` | zajedničke beleške po mreži |
| `/home/agent/chrome-profile` | Chrome profil sa loginima |

## Tajne

Repo je javan. **Nikakve tajne ne idu u git.** Sve lozinke i ključevi su samo u `/etc/social-agent/.env` na serveru (generiše ih `01-env`, prava `600`). Vidiš ih sa `sudo cat /etc/social-agent/.env`. Postojeće vrednosti se nikad ne prepisuju, pa ručna izmena opstaje posle ponovnog setupa.
