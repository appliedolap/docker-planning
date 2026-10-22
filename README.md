# Hyperion Planning 11.2.26 in Docker

EPM System 11.2.26 on Oracle Linux 8: Foundation Services, Calculation Manager, Essbase 21c and Planning, with SQL Server 2022 as the repository. It's for development and testing. Oracle doesn't document containers as a supported deployment.

**This repository holds build scripts only.** It contains no Oracle software, and no image is published from it. Clone it, download the installation media from Oracle yourself, and build your own image. An image built from it contains Oracle software, so don't publish that either. This is an unofficial project, not affiliated with or endorsed by Oracle.

## Quick start

1. Check the [prerequisites](#prerequisites): Docker Desktop with enough memory and disk, and Rosetta on Apple Silicon.
2. Download the seven files listed in [Getting the media](#getting-the-media) into `media/`, and check them with `./build/check-media.sh`.
3. Copy `.env.example` to `.env`, and set the passwords and host name. They're fixed at first start.
4. Build the image with `docker compose build planning`. It takes about 1 hour 40 minutes.
5. Start it with `docker compose up -d`. The first start configures EPM, which takes about 23 minutes; `docker compose logs -f planning` shows progress.
6. Open the launcher page at http://localhost:9000/.
7. Optionally, create the Vision sample application through the web UI: see [Creating the Vision sample application](#creating-the-vision-sample-application-manual-once-per-environment).

## Status

Working end to end on 2026-10-20. Tested on macOS 15.8 on Apple Silicon, under Rosetta, with Docker Desktop (Docker Engine 29.8.2), SQL Server 2022 (`mcr.microsoft.com/mssql/server:2022-latest`) and the media files the [manifests](media) list:

- `docker compose up -d` configures and starts everything unattended in about 23 minutes on first start: database setup, RCU, two silent configurator passes, three fixes for Oracle defects, then startup. Later starts take about 8 minutes.
- Workspace, Shared Services, Planning, Calculation Manager, Essbase (web UI, Smart View, JAPI), EAS Lite and both WebLogic consoles all answer, and the container reports healthy.
- The Vision sample application has to be created through the web UI (below). That procedure was carried out on a freshly started container. Planning reported "Application created successfully", and Essbase shows Vision with cubes Plan1–Plan3 started, Plan1 holding 6,691 data blocks.

What's inside, and what Oracle certifies:

- There's no 11.2.26 installer. The image installs EPM System 11.2.15 and applies the 11.2.26 update, as Oracle documents for a new 11.2.26 installation.
- The installer brings its own WebLogic 12.2.1.4 and Oracle JDK 8, and the update moves the JDK to 8u491. Essbase is 21c (21.8.1), in its own WebLogic domain.
- Oracle's EPM 11.2 certification matrix lists Oracle Linux 8 (from 11.2.15) and SQL Server 2016 SP2, 2017, 2019 and 2022 (from 11.2.16). It doesn't say whether SQL Server running on Linux, as it does here, counts.

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
  - Disk: the media (18 GB), the install and update layers, the image (16 GB) and the `epm-home` volume seeded from it. Plan on 80 GB free.
  - Build cache: Docker Desktop's default caps it at 20 GB (Settings → Docker Engine, `builder.gc.defaultKeepStorage`), which evicts the install between builds. Raise it to about 150 GB, or use the tagged-image route below.
- **Host name:** EPM's name is `EPM_HOSTNAME.EPM_DOMAIN`, `planning.epm.test` by default (see Configuration). Locally, add `127.0.0.1 planning.epm.test` to the Mac's `/etc/hosts`.
  - Browsing works without it: redirects are relative, and Workspace, Planning administration and Vision creation all ran on `http://localhost:9000`.
  - What needs the name is anything EPM hands an absolute URL from its registry, where every application is recorded under that host. The likely cases are Smart View's shared connections and Essbase/Provider Services addresses (`:9010/essbase/...`).
- **Ports:** 7001, 9000, 7010, 9010, 9110 and 1423 must be free, and can't be remapped (EPM redirects to its own ports). Stop any other Essbase or EPM containers first.

## Getting the media

The build needs seven downloads from [Oracle Software Delivery Cloud](https://edelivery.oracle.com), from the Oracle Enterprise Performance Management System media packs for Linux x86-64. Downloading them takes an Oracle account and a license, or trial terms, that covers Hyperion Planning; none of the media is in this repository. Put the files in `media/` as they come: one flat folder, under Oracle's file names.

| File | Oracle's name for it | Size |
| --- | --- | --- |
| `V1039130-01.zip` | EPM System Release 11.2.15.0.000 for Linux x86-64 Part 1 | 3.5 GB |
| `V1039179-01.zip` | EPM System Release 11.2.15.0.000 for Linux x86-64 Part 2 | 1.7 GB |
| `V1039125-01.zip` | EPM System Release 11.2.15.0.000 Linux x86-64 Part 3 | 1.4 GB |
| `V1039108-01.zip` | EPM System Release 11.2.15.0.000 for Linux x86-64 Part 4 | 0.2 GB |
| `V1039137-01.zip` | EPM System Release 11.2.15.0.000 for Linux x86-64 Part 5 | 2.9 GB |
| `V1039140-01.zip` | EPM System Release 11.2.15.0.000 for Linux x86-64 Part 6 | 2.5 GB |
| `V1057744-01.zip` | EPM System Release 11.2.26.0.000 for Linux x86-64 (the update) | 6.2 GB |

The media packs also offer the Oracle HTTP Server installer, the installation documents, Windows client installers, Oracle Internet Directory and Data Relationship Management. The image needs none of them. Anything else in `media/` is ignored, and isn't sent to Docker.

`media/epm-11.2.15-linux.sha256` and `media/epm-11.2.26-update-linux.sha256` list these files with their SHA-256 checksums, taken from the copies this image was built and tested with. Check the downloads before building:

    ./build/check-media.sh

A missing file shows up at once, and a damaged one (an interrupted download or sync) within a minute. The build runs the same check before it installs or patches anything.

## Configuration

Settings come from environment variables, or from a `.env` file next to `compose.yml`; `.env.example` documents them. **The host name and both passwords are fixed at first start**: EPM records them while configuring and can't be renamed or re-pointed afterwards, so changing one means `docker compose down -v`.

| Variable | Default | Notes |
| --- | --- | --- |
| `MSSQL_SA_PASSWORD` | `Welcome1_EPM` | Also RCU's sysDBA password: **16 characters at most** |
| `EPM_PASSWORD` | `Welcome1_EPM` | WebLogic `epm_admin` and Shared Services `admin` |
| `EPM_HOSTNAME` / `EPM_DOMAIN` | `planning` / `epm.test` | EPM's name. Letters, digits, dashes and dots only |
| `PLANNING_MEM_LIMIT` | `16g` | |
| `MSSQL_HOST_PORT` | `21433` | SQL Server from the host |
| `INSTALLED_IMAGE` / `PATCHED_IMAGE` | (build from scratch) | Reuse a built image instead; see Building |
| `PLANNING_IMAGE` | `hyperion-planning:11.2.26` | The built image's name. It contains Oracle software: push it only to a private registry |

Password rules are Oracle's, and they constrain each other. The simplest password satisfies all of them: 16 characters or fewer, starting with a letter, containing a digit, using only letters, digits and `_`. `configure.sh` checks before doing anything.

## Building

From scratch, in one go: about 1 hour 40 minutes under Rosetta. That's about 3 minutes sending the media to Docker, 50 for the install and 45 for the update (measured 2026-10-22).

    docker compose build planning

Either half can instead come from an image built earlier, which survives build-cache eviction and makes rebuilding the container scripts take seconds:

    # keep the 11.2.15 install
    docker buildx build --platform linux/amd64 --build-context media=./media \
        --target installed -t hyperion-planning:installed-11.2.15 --load .
    INSTALLED_IMAGE=hyperion-planning:installed-11.2.15 docker compose build planning

    # keep the patched install (any previous planning image)
    docker tag hyperion-planning:11.2.26 hyperion-planning:patched-11.2.26
    PATCHED_IMAGE=hyperion-planning:patched-11.2.26 docker compose build planning

## Running it

    docker compose up -d
    docker compose logs -f planning

Healthy means `/u01/oracle/.configured` exists and both web tiers answer (`docker compose ps`).

**Start at http://localhost:9000/** (or http://planning.epm.test:9000/), a launcher page with:

- links to everything below, with a live status dot on each;
- copyable connection strings for Smart View, the Essbase Java API, REST, the agent and SQL Server;
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
| `build/` | Build-time install and update scripts, install response file, media check |
| `container/` | Entry point, configuration (two response templates), start/stop, health check, ODBC fix, launcher page (`landing/`, `install-landing.sh`) |
| `db/init-databases.sql` | Database creation, run by `mssql-init` |
| `recorder/` | VNC desktop for recording the configurator response file, and how to do it |
| `start_scripts/` | LCM exports to import on first start (empty) |
| `media/` | Oracle media, ignored by git, plus the manifests and `.dockerignore` that say which files the build uses |
| `recordings/` | Raw recordings and configurator logs from the recording run; ignored by git |
| `AGENTS.md` | Ground rules for coding agents and contributors |

## Not yet exercised

- LCM imports from `start_scripts/` on first start (the code is a port of the one in [docker-essbase](https://github.com/appliedolap/docker-essbase), the 11.1.2.4 image).
- Hosts other than Apple Silicon: x86-64 Linux, and Windows with Docker Desktop. Nothing here depends on Apple Silicon, and without Rosetta everything should be faster, but it hasn't been tried.
- Configuration without Xvfb. The web server pass ran headless; the main pass still runs under Xvfb (`EPM_USE_XVFB=true`).

## License

Copyright 2026 Applied OLAP, Inc. Licensed under the [Apache License, Version 2.0](LICENSE).

Oracle, Hyperion, Essbase and Java are registered trademarks of Oracle and/or its affiliates. Other names may be trademarks of their respective owners.
