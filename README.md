# Hyperion Planning 11.2.26 in Docker

EPM System 11.2.26 on Oracle Linux 8: Foundation Services, Calculation Manager, Essbase 21c and Planning, with SQL Server 2022 as the repository. It's for development and testing. Oracle doesn't document containers as a supported deployment.

See [REQUIREMENTS.md](REQUIREMENTS.md) for the analysis behind the choices here.

## Status

Working end to end (2026-10-20, on an M1 Max under Rosetta):

- `docker compose up -d` configures and starts everything unattended in about 23 minutes on first start: database setup, RCU, two silent configurator passes, three fixes for Oracle defects, then startup. Later starts take about 8 minutes.
- Workspace, Shared Services, Planning, Calculation Manager, Essbase (web UI, Smart View, JAPI), EAS Lite and both WebLogic consoles all answer, and the container reports healthy.
- The Vision sample application has to be created through the web UI (below). That procedure was carried out on a freshly started container. Planning reported "Application created successfully", and Essbase shows Vision with cubes Plan1–Plan3 started, Plan1 holding 6,691 data blocks.

## How it works

- **Build:**
  1. Installs 11.2.15 silently. `build/install-response.xml` is written from the installer's own product tree and response schema, both inside Part 1's `installTool.jar`.
  2. Applies the 11.2.26 update with Oracle's `ApplyUpdate.sh`, giving it only the patches for installed products.
  3. Fails the build if any of those patches report a failure.

  The Oracle media is bind-mounted from a separate build context and never lands in a layer.
- **First start** (`container/entrypoint.sh`, then `configure.sh`):
  1. `mssql-init` creates the `EPM`, `EPM_RCU` and `EPM_VISION` databases with Oracle's collation and snapshot settings.
  2. Checks the passwords and host name.
  3. Runs RCU (FMW schemas, prefix `EPM`) and writes `RCUSchema.properties`.
  4. Runs the configurator silently from `container/config-response.xml`, recorded once through the GUI ([recorder/README.md](recorder/README.md)).
  5. Adds a registry property Essbase 21c forgets, then runs the Configure Web Server task as a second silent pass (`webserver-response.xml`).
  6. Points Essbase's ODBC configuration at the real DataDirect 8.0.2 driver paths.
  7. Writes `/u01/oracle/.configured`.
- **Every start:**
  1. WebLogic Admin Server.
  2. `epmsystem1/bin/start.sh`, which also starts the Essbase domain.
  3. The launcher page at `/` (installed or updated only if it changed).
  4. Any LCM imports in `start_scripts/` (first start only).
  5. Then it follows the logs.
- **State:** everything EPM writes is under `/u01/oracle`, on the `epm-home` volume. With the `mssql-data` volume, configuration survives `docker compose down`. `down -v` is a full reset.

### Oracle defects this works around

These cost real time to find; each fix sits in the script named, with the evidence in its comments.

| Symptom | Cause | Fix |
| --- | --- | --- |
| Every EPM product patch fails in seconds during `ApplyUpdate.sh` | The EPM home's OPatch (11.1.0.9, never upgraded by the update) needs `Middleware/utils`, which this install doesn't create | `build/apply-update.sh` creates it |
| The Middleware home's inventory lands in `~oracle/oraInventory`, outside the image tree | Installer default | `build/apply-update.sh` moves it to `/u01/oracle/fmwInventory` |
| RCU rejects `UCSUMS` | User Messaging Service is Oracle-database-only | Left out of `RCU_COMPONENTS` |
| Configure Web Server fails with a NullPointerException; Workspace then answers 500 | Essbase 21c registers Provider Services without the `context` property every other web app has | `configure.sh` adds it with `epmsys_registry.sh`, then runs the web server task |
| Planning's Vision creation fails on SQL Server (Oracle known issues 39039397, 39010704) | Essbase's `odbc.ini` names its driver by bare file name and `odbcinst.ini` points at Oracle's build path, `/u01/app/dist` | `container/fix-essbase-odbc.sh` |

## Prerequisites

- **Docker Desktop:**
  - Rosetta enabled (Settings → General). The product is x86-64 only.
  - Memory at 22 GB or more (Settings → Resources). EPM is capped at 16 GB (`PLANNING_MEM_LIMIT`) and uses about 12 GB once running; SQL Server uses about 2.5 GB.
  - Disk: the media build context (~22 GB), the install and update layers, the image (16 GB) and the `epm-home` volume seeded from it. Plan on 80 GB free.
  - Build cache: Docker Desktop's default caps it at 20 GB (Settings → Docker Engine, `builder.gc.defaultKeepStorage`), which evicts the install between builds. Raise it to about 150 GB, or use the tagged-image route below.
- **Host name:** EPM's name is `EPM_HOSTNAME.EPM_DOMAIN`, `planning.epm.test` by default (see Configuration). Locally, add `127.0.0.1 planning.epm.test` to the Mac's `/etc/hosts`.
  - Browsing works without it: redirects are relative, and Workspace, Planning administration and Vision creation all ran on `http://localhost:9000`.
  - What needs the name is anything EPM hands an absolute URL from its registry, where every application is recorded under that host. The likely cases are Smart View's shared connections and Essbase/Provider Services addresses (`:9010/essbase/...`).
- **Ports:** 7001, 9000, 7010, 9010, 9110 and 1423 must be free, and can't be remapped (EPM redirects to its own ports). Stop Cessna's Essbase stack first; it uses 7001, 9000 and 1423.

## Configuration

Settings come from environment variables, or from a `.env` file next to `compose.yml`; `.env.example` documents them. **The host name and both passwords are fixed at first start**: EPM records them while configuring and can't be renamed or re-pointed afterwards, so changing one means `docker compose down -v`.

| Variable | Default | Notes |
| --- | --- | --- |
| `MSSQL_SA_PASSWORD` | `Welcome1_EPM` | Also RCU's sysDBA password: **16 characters at most** |
| `EPM_PASSWORD` | `Welcome1_EPM` | WebLogic `epm_admin` and Shared Services `admin` |
| `EPM_HOSTNAME` / `EPM_DOMAIN` | `planning` / `epm.test` | EPM's name. Letters, digits, dashes and dots only |
| `PLANNING_MEM_LIMIT` | `16g` | |
| `MSSQL_HOST_PORT` | `21433` | SQL Server from the host |
| `BASE_MEDIA_DIR` / `UPDATE_MEDIA_DIR` | `Hyperion_Planning_11.2.15` / `Planning_11.2.26_Linux` | Folders under `media/` |
| `INSTALLED_IMAGE` / `PATCHED_IMAGE` | (build from scratch) | Reuse a built image instead; see Building |

Password rules are Oracle's, and they constrain each other. The simplest password satisfies all of them: 16 characters or fewer, starting with a letter, containing a digit, using only letters, digits and `_`. `configure.sh` checks before doing anything.

## Building

From scratch: about 40 minutes for the install plus 40 for the update.

    docker compose build planning

Either half can instead come from an image built earlier, which survives build-cache eviction and makes rebuilding the container scripts take seconds:

    # keep the 11.2.15 install
    docker buildx build --platform linux/amd64 --build-context media=./media \
        --target installed -t hyperion-planning:installed-11.2.15 --load .
    INSTALLED_IMAGE=hyperion-planning:installed-11.2.15 docker compose build planning

    # keep the patched install (any previous planning image)
    docker tag appliedolap/hyperion-planning:11.2.26 hyperion-planning:patched-11.2.26
    PATCHED_IMAGE=hyperion-planning:patched-11.2.26 docker compose build planning

## Running it

    docker compose up -d
    docker compose logs -f planning

Healthy means `/u01/oracle/.configured` exists and both web tiers answer (`docker compose ps`).

**Start at http://localhost:9000/** (or http://planning.epm.test:9000/), a launcher page with:

- links to everything below, with a live status dot on each;
- copyable connection strings for Smart View, the Essbase Java API (Dodeca), REST, the agent and SQL Server;
- which user signs in where.

It deliberately doesn't show passwords. EPM's web proxy owns the root path (it also forwards `/essbase` and `/eas` on port 9000), so the page is added to the proxy rather than replacing it; see `container/install-landing.sh`. Its status dots for ports other than 9000 only work on `localhost`. Under any other name, browsers block a plain-http page from probing other ports, so those dots show grey ("couldn't check"), not red.

| What | URL |
| --- | --- |
| Workspace | http://planning.epm.test:9000/workspace/ |
| Shared Services | http://planning.epm.test:9000/interop/ |
| Planning | http://planning.epm.test:9000/HyperionPlanning/ (but administer it from Workspace) |
| Calculation Manager | http://planning.epm.test:9000/calcmgr/index.htm |
| Essbase web UI | http://planning.epm.test:9010/essbase/jet |
| Smart View (Essbase) | http://planning.epm.test:9010/essbase/smartview |
| Smart View (Planning) | http://planning.epm.test:9000/HyperionPlanning/SmartView |
| EAS Lite | http://planning.epm.test:9110/easconsole/ |
| WebLogic consoles | http://planning.epm.test:7001/console, http://planning.epm.test:7010/console |
| SQL Server | `localhost,21433`, user `sa` |

The URLs show the default host name; use yours if you set `EPM_HOSTNAME`/`EPM_DOMAIN`. Users: `admin` / `$EPM_PASSWORD` for EPM, and `epm_admin` / `$EPM_PASSWORD` for WebLogic.

Workspace opens in a pop-up window from its welcome page (**Launch Application…**), so allow pop-ups for the site.

## Creating the Vision sample application (manual, once per environment)

Planning only creates data sources and applications through Workspace; there's no command line for either, and Planning's standalone sign-in can't do it (with no application it errors). Everything this needs is in place: the `EPM_VISION` database, and the ODBC fix without which Vision fails on SQL Server.

1. Open Workspace, **Launch Application…**, and sign in as `admin`.
2. **Navigate → Administer → Planning Administration.**
3. **Manage Data Source**, then the green **+** (or Actions → Create):
   - **Data Source Name:** `VisionDS`. **Data Source Description:** anything.
   - **Application Database:**
     - **Database:** Microsoft SQL Server. The port changes to 1433 and the next field becomes "Database".
     - **Server:** `mssql`.
     - **Database:** `EPM_VISION`.
     - **User:** `sa`. **Password:** `$MSSQL_SA_PASSWORD`.
     - **Validate** should report "The database connection was successful."
   - **Essbase Server:**
     - **Server:** EPM's host name (`planning.epm.test` by default). Essbase's agent port, 1423, is the default, so no `:port`.
     - **User:** `admin`. **Password:** `$EPM_PASSWORD`.
     - **Validate** should report "The Essbase connection was successful."
   - **Save.**
4. **Manage Applications**, then the green **+**:
   - **Data Source:** `VisionDS`.
   - **Application:** `Vision` (8 characters at most).
   - **Application Type:** **Sample**.
   - **Shared Services Project:** leave the default.
   - **Next** goes straight to Finish, because the sample's calendar, currencies and plan types are fixed. There, click **Create**.
   - "Initializing Application: Loading Dimensionality and Data…" takes a while under Rosetta. It creates the Essbase application `Vision` with cubes Plan1, Plan2 and Plan3.
5. Check it: Vision is listed under Manage Applications and in Navigate → Applications → Planning, and its cubes show in the Essbase web UI.

To skip step 4 in later environments, export Vision with LCM (Shared Services → Application Groups) into a folder under `start_scripts/`; it's imported on first start. The data source (step 3) still has to exist first, so either do step 3 before restarting the container, or run the import by hand afterwards with `$EPM_ORACLE_INSTANCE/bin/Utility.sh`.

## Starting over

    docker compose down -v

Configuration can't be repeated over a partial attempt: RCU won't recreate a prefix, the Shared Services registry can't be reused, and Essbase can't be reconfigured. So after any failure, reset completely. This also drops the databases.

A rebuilt image's container scripts take effect as soon as the container is recreated (`docker compose up -d`), because they live outside the volume. Its EPM installation (`/u01/oracle`) only takes effect after `down -v`, because `epm-home` is seeded from the image once.

## Restarts

SQL Server and Planning have `restart: unless-stopped`, so they come back after a Docker or machine restart. Later starts don't reconfigure. EPM waits for SQL Server, then starts in about 8 minutes, and it recovers from being killed mid-run. A graceful stop takes about 7 minutes, and compose allows 10 (`stop_grace_period`).

Two situations aren't retried. The container stays up, idle and unhealthy, with the reason in `docker compose logs planning`:

- **First-time configuration didn't finish.** It can't be repeated over a partial attempt. Read the logs, then `down -v`.
- **A configured volume started under a different host name.** Put `EPM_HOSTNAME`/`EPM_DOMAIN` back, or `down -v` to configure afresh under the new name.

## Logs

| What | Where (in the container) |
| --- | --- |
| Container scripts, RCU, Admin Server stdout | `/u01/oracle/container-logs` |
| Configurator | `$EPM_ORACLE_INSTANCE/diagnostics/logs/config` (`configtool.log`, `configtool_summary.log`) |
| EPM managed server | `$EPM_DOMAIN_HOME/servers/EPMServer0/logs` (`Planning_WebApp.log`, `Workspace.log`, …) |
| Essbase | `$ESSBASE_DOMAIN_HOME/servers/essbase_server1/logs` (`essbase/jagent.log`, application logs under `essbase/essbase/app`) |
| Install and update (build time) | `$EPM_ORACLE_HOME/diagnostics/logs/install` (`ApplyUpdateSummary.log`) |

`docker compose exec planning bash` gets a shell as `oracle` with all of these variables set.

## Layout

| Path | What |
| --- | --- |
| `Dockerfile` | Base OS, install, update, runtime image, recorder images |
| `compose.yml` | SQL Server, database setup, Planning, recorders |
| `.env.example` | Every setting, with Oracle's constraints; copy to `.env` |
| `build/` | Build-time install and update scripts, install response file |
| `container/` | Entry point, configuration (two response templates), start/stop, health check, ODBC fix, launcher page (`landing/`, `install-landing.sh`) |
| `db/init-databases.sql` | Database creation, run by `mssql-init` |
| `recorder/` | VNC desktop for recording the configurator response file, and how to do it |
| `start_scripts/` | LCM exports to import on first start (empty) |
| `media/` | Oracle media; ignored by git |
| `recordings/` | Raw recordings and configurator logs from the recording run; ignored by git |

## Not yet exercised

- LCM imports from `start_scripts/` on first start (the code is a port of the 11.1.2.4 image's).
- Configuration without Xvfb. The web server pass ran headless; the main pass still runs under Xvfb (`EPM_USE_XVFB=true`).
- One uninterrupted build from scratch. The base install and the update each ran with the current scripts, but as separate builds (the update via `INSTALLED_IMAGE`). The running image is that patched install plus the current `container/` scripts (via `PATCHED_IMAGE`).
