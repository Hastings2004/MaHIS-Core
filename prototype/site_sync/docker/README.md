# Two hospitals and central, each its own MaHIS installation

This folder runs the sync prototype the way it would be deployed: Kamuzu
Central Hospital (KCH), Zomba Central Hospital (ZCH) and central are each an
independent MaHIS installation with its own database, API and, for the
hospitals, the MaHIS web app and a sync agent. Nobody runs scripts during
use: staff work in the MaHIS web app and sync happens in the background.

| What | Address |
|---|---|
| Central dashboard | <http://localhost:4200/api/v1/site_sync/admin/dashboard?token=demo-admin-token> |
| KCH, MaHIS web app | <http://localhost:8201> (its API: port 4201) |
| ZCH, MaHIS web app | <http://localhost:8202> (its API: port 4202) |

Log in to either hospital with your usual dev MaHIS username and password:
every server starts from a copy of your dev database, with all its users
moved to that hospital.

## Containers

| Container | Role |
|---|---|
| `central-db`, `central-redis`, `central-api` | Central: national copy, validation, dashboard |
| `kch-db`, `kch-redis`, `kch-api`, `kch-web`, `kch-agent` | KCH: its own MySQL, MaHIS API, web app, sync agent |
| `zch-…` | The same for ZCH |
| `*-init` | Run once at first start: sync tables, capture triggers, the first full copy to central, database accounts. Then they exit. |

Hospitals reach central only over the `wan` network. The API runs as the
restricted `mahis_app` MySQL account, the agent as `mahis_sync`.

## Start and stop

Needs Docker Desktop (with WSL integration) and two things built once:

```bash
# 1. The MaHIS data to start from (once; also used by the scripted demo)
cd ~/projects/MAHIS/MaHIS-Core && prototype/site_sync/bin/setup
# 2. The MaHIS web app
cd ~/projects/MAHIS/MAHIS && npx vite build --base=/

cd ~/projects/MAHIS/MaHIS-Core/prototype/site_sync/docker
docker compose up -d --build     # first start ~10 min: each database loads the MaHIS data
docker compose ps                # all running; the *-init containers "exited (0)"
docker compose down              # stop; data is kept
docker compose down -v           # stop and delete all data (next start is fresh)
```

Everything can also be started, stopped and watched from Docker Desktop's
Containers view (the `mahis-sync` group).

## Showing it

1. Open the dashboard and both hospitals side by side. Both show as active
   with their real names; each has sent its existing records to central.
2. At KCH, register a patient and record vitals. Within seconds the
   dashboard's counts rise; central has the patient.
3. Take ZCH offline and keep working there:
   `./network.sh ZCH off` (or, in Docker Desktop, pause `zch-agent`). The
   dashboard's "Unsent" for ZCH grows. Bring it back (`./network.sh ZCH on`)
   and the queue drains.
4. A patient from KCH walks into ZCH: ZCH fetches them from central (a
   referral). Edits at either hospital then reach the other.

The scripted fault scenes (power cut, tampering, corruption, restore) stay in
`prototype/site_sync/demo` and run against the non-Docker setup.

## Settings

Defaults suit a demo; set them in a `.env` file next to `docker-compose.yml`:
`DB_ROOT_PASSWORD`, `KCH_SECRET`, `ZCH_SECRET`, `SITE_SYNC_ADMIN_TOKEN`,
`SITE_SYNC_PUSH_EVERY` (default 5 s; production 30), `SITE_SYNC_PULL_EVERY`
(10 s; production 120), `MAHIS_DUMP` (the starting data),
`MAHIS_WEB_DIST` (the built web app).
