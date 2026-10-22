# Recording the response files

The image installs and configures EPM silently, from two response files:

- `build/install-response.xml`, for the EPM System Installer (`installTool.sh`). It didn't need recording. It's written from the installer's own product tree (`xml/installTree.xml` in Part 1's `installTool.jar`) and validates against its schema (`xml/response.xsd`, same jar). Section 1 below is kept for checking it against a real recording if the build disagrees.
- `container/config-response.xml`, for the EPM System Configurator (`configtool.sh`). This one does have to be recorded (section 2).

The configurator has had no console mode since 11.2.15, and 11.1.2.4 response files don't work with 11.2. So it's recorded once, through the GUI, in a throwaway container that serves an X desktop to the browser with noVNC. Both recorder services publish noVNC on `127.0.0.1:6080` only. Open:

    http://localhost:6080/vnc.html?autoconnect=true&resize=remote

The desktop has an Openbox session with an xterm (closing it opens a new one) and nothing else. Typing in a normal browser just works. When driving noVNC from browser automation (Playwright, for example), text must arrive as real `keydown`/`keyup` events on the canvas. Inserted text never reaches the VNC session.

## 1. Installer response file (only to cross-check)

Needs the 11.2.15 Linux parts in `media/` (the files `media/epm-11.2.15-linux.sha256` lists).

    docker compose --profile recorder up -d --build install-recorder

In the xterm:

    mkdir -p /tmp/epm-media
    for zip in $(awk '{print $2}' /media/epm-11.2.15-linux.sha256); do unzip -q -o "/media/$zip" -d /tmp/epm-media; done
    cd /tmp/epm-media && ./installTool.sh -record /home/oracle/recordings/install-response.xml

Choices:

- **Middleware home:** `/u01/oracle/Middleware`.
- **Installation type:** New installation.
- **Products:**
  - Foundation Services, with Calculation Manager. **Not** Oracle HTTP Server.
  - Essbase: server, Provider Services and EAS Lite.
  - Planning.
  - Nothing else: no Financial Reporting, HFM, FDMEE, Profitability, Financial Close or Tax.

On the Confirmation page, also click **Save** and save to `/home/oracle/recordings/install-response-saved.xml`; Oracle documents both routes and they should agree. Letting the install run here isn't necessary. The image build does the real one.

Then compare `recordings/install-response.xml` with `build/install-response.xml`. If the recording is right, copy it over and change its `HyperionHome` value to `__MW_HOME__`.

Finish with `docker compose --profile recorder down`.

## 2. Configurator response file

Recorded on 2026-10-20 from 11.2.26; `container/config-response.xml` is the result. Repeat this only when the configuration choices change or after a new update.

Needs the planning image (`docker compose build planning`): config-recorder is built on top of it, so the configurator records against an installed, patched home. It also configures for real while recording, which makes this an end-to-end test.

    docker compose --profile recorder up -d --build config-recorder

First create the RCU schemas and `RCUSchema.properties` the way the container will:

    docker compose exec config-recorder /home/oracle/container/configure.sh --prepare-only

Then start the configurator on the VNC display, either from the xterm or straight from the Mac:

    docker compose exec -d config-recorder bash -c 'cd $EPM_ORACLE_HOME/common/config/11.1.2.0 && DISPLAY=:1 ./configtool.sh -record /home/oracle/recordings/config-response.xml'

Driving it from scripts or automation: `xdotool` is installed. `DISPLAY=:1 xdotool mousemove X Y click 1` clicks at X display coordinates, and `xdotool type --delay 150 "$PASSWORD"` types from the container's environment. Under Rosetta, typing faster than about 100 ms per key drops characters, which in a password field only shows up later as a failed login.

Choices (Oracle only lets a recording pass through the wizard once; going back to Task Selection restarts the recording):

- **EPM Oracle instance:** new, `/u01/oracle/Middleware/user_projects`, name `epmsystem1`.
- **Tasks:** everything for Foundation Services, Calculation Manager, Essbase and Planning.
- **Shared Services database:** first-time configuration. Microsoft SQL Server, server `mssql`, port `1433`, database `EPM`, user `sa`. Use the same database for the other products' Configure Database pages.
- **Application server:** new domain `EPMSystem`, admin server port `7001`, admin user `epm_admin`. Select **Deploy the web applications to a single managed server** (`EPMServer0`, port 9000).
- **Common settings:** no Windows services, no SSL. Leave the LCM export/import location at its default.
- **Shared Services admin:** `admin`.
- **Essbase:** defaults (cluster `EssbaseCluster-1`, agent 1423, default application location). Don't narrow the application port range.
- **Planning RMI:** default port 11333.
- **Web server:** Embedded WebLogic HTTP Server, port 9000 (EPMServer0 itself). Leave "Set the logical address" unchecked.

On the Confirmation page, also click **Save** to `/home/oracle/recordings/config-response-saved.xml`. The `-record` file is written when the run starts, and the saved copy came out identical. Then let it finish.

Turn the recording into `container/config-response.xml` by replacing values with the placeholders `configure.sh` fills in. The last recording was converted by a short script; the mapping is:

| Placeholder | Recorded value |
| --- | --- |
| `__MW_HOME__` | `/u01/oracle/Middleware` |
| `__EPM_ORACLE_INSTANCE__` | `/u01/oracle/Middleware/user_projects/epmsystem1` |
| `__HOST__` | `planning.epm.test` |
| `__DB_HOST__`, `__DB_PORT__`, `__EPM_DB__`, `__DB_USER__` | `mssql`, `1433`, `EPM`, `sa` |
| `__DB_PASSWORD__` | each database password property, as `<property name="password" encrypt="true">__DB_PASSWORD__</property>` |
| `__WLS_ADMIN_USER__`, `__WLS_ADMIN_PASSWORD__` | `adminUser` / `adminPassword` (with `encrypt="true"`) under `applicationServerDeployment` |
| `__EPM_ADMIN_USER__`, `__EPM_ADMIN_PASSWORD__` | `adminUserName` / `adminPassword` (with `encrypt="true"`) under Foundation's `customConfiguration` |

Oracle documents the clear-text `encrypt="true"` form for exactly this (Installation and Configuration Guide, "Performing Silent Configurations"). Recorded passwords are otherwise encrypted and salted.

Two more edits:

- Leave each database block's `<property name="encrypted">true</property>` alone. With `encrypt="true"` the configurator encrypts the clear text on load, then decrypts it to connect. Setting `encrypted` to `false`, as the 11.1.2.4 template did, makes it connect with the ciphertext ("Login failed for user 'sa'").
- Leave the Essbase block's `password` as recorded. It's a constant for an internal `hypuser` default, the same ciphertext as in 11.1.2.4.

Finish with `docker compose --profile recorder down -v`, which also drops the databases the recording configured.
