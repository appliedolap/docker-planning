# Hyperion Planning 11.2.26 in Docker: requirements analysis

> **Outcome (2026-10-20):** built and working; see README.md. The analysis below held up, with these corrections from the real run:
>
> - Planning needs 11.2.15 Parts 1–6, not 1–4.
> - RCU's UCSUMS component isn't available on SQL Server.
> - The Essbase ODBC problem is a bare driver name plus Oracle's `/u01/app/dist` build path, not the Readme's 7.1.6 → 8.0.2 rename.
> - Configure Web Server needs a registry fix to succeed.
> - The installer response file came from the installer's own schema, with no recording session. The configurator's web-server pass ran with no display; the main pass still uses Xvfb.
>
> README.md's "Oracle defects this works around" has the details.

Initial analysis for a runnable Planning image, composed with Microsoft SQL Server. Sources:

- `media/Installation_Docs/V1057743-01.zip`: the 11.2.26 Readme (G56066-02, July 2026), the Installation and Configuration Guide (F81254-36, July 2026), and the Linux media pack readme. Note that 11.2.26 ships no install guide of its own; the guide in the zip is the **11.2.15** guide, kept current.
- Our prior images: `~/Development/docker-essbase` (Essbase 11.1.2.4, SQL Server), `~/Development/docker-images` branch `appliedolap-essbase` (Oracle's Essbase 21c reference scripts and our SQL Server sample), and `Cessna/docker/essbase` (Essbase 21c/26.1 under Rosetta).

Page references below are to the install guide PDF unless noted.

## Headline findings

1. **11.2.26 is not a full installer.** A new install is: install **11.2.15**, update `RCUSchema.properties`, run `ApplyUpdate.sh` for 11.2.26, then configure (Readme table 1-6). Patching happens *before* configuration, so install and patch belong in the image build and configuration belongs at first start. That is the same split as the 11.1.2.4 image.
2. **Essbase is 21c, not 11g.** Since 11.2.15, EPM embeds Essbase 21c (21.8.1 as of 11.2.26) with its own WebLogic domain (`essbase_domain`), its own RCU schema, EAS Lite in place of EAS, and APS folded into `/essbase` URLs (ch. 3, appendix B–D). Our 21c experience applies here; our 11.1.2.4 Essbase knowledge mostly does not.
3. **The EPM installer brings its own WebLogic 12.2.1.4 and JDK 8**, and every quarterly update replaces the JDK and applies WebLogic/ADF patches into the Middleware home (pp. 60, 72; Readme table 1-2: Java 8u491, WLS PSU 12.2.1.4.260514). The base image should be plain Oracle Linux, not `oracle/fmw-infrastructure`.
4. **SQL Server is a supported repository but has specific requirements:** a separate case-sensitive RCU database, RCSI on, one database per Planning application, and a manual Essbase ODBC driver fix at 11.2.26. Without that fix, creating the Vision sample application fails (known issue 39010704).
5. **Silent install and silent configuration both exist**, but the response files have to be recorded through the GUI. The configurator lost console mode in 11.2.15, and 11.1.2.4 response files are not compatible with 11.2 (pp. 83, 144–145).
6. **The product is x86-64 only.** On the M1 Max it runs under Rosetta, as Cessna's Essbase images already do (`platform: linux/amd64`).

## Base image decision

| Option | Verdict |
| --- | --- |
| `oraclelinux:8` | **Recommended.** Certified (p. 73). 11.2.15, our base installer, is the release that introduced Linux 8 support (ch. 2). Linux 8 is also the target Oracle names for HFM-on-Linux and out-of-place upgrades, so it is the most travelled path. |
| `oraclelinux:9` | Certified (p. 72), but only since **11.2.25**, so the 11.2.15 base installer predates it. OHS on 9 needs an **el8** `compat-libpthread-nonshared` RPM (p. 73). The Troubleshooting Guide also notes that on new RHEL 9 builds at 11.2.25/26, the OHS DB client install that `ApplyUpdate` runs can fail its prerequisite check; the workaround (`-ignoreSysPrereqs` plus a symlink) is "only with SR approval". Revisit later. |
| `oraclelinux:7` | Still listed, but the OS is past end of life. No. |
| `oracle/fmw-infrastructure:12.2.1.4` | The installer will reuse a WebLogic it finds in the Middleware home if the version is supported (p. 60). But the update process owns WebLogic, ADF and JDK patch levels, so a separately patched FMW base is a version-skew liability with no benefit. No. |

## Build-time and run-time split

**Image build** (multi-stage, like the 11.1.2.4 Dockerfile):

1. OS packages; `oracle` user in `oinstall`; writable `oraInventory`.
2. Unzip the 11.2.15 Linux parts into a directory **without spaces**. The assemblies land in `assemblies/<product>/<version>/assembly.dat` (pp. 68–69).
3. `installTool.sh -silent <response.xml>` (p. 83) for Foundation Services, Calculation Manager, Essbase (server, APS, EAS Lite), Planning and possibly Financial Reporting. Skip OHS (see Configuration choices).
4. Unzip the 11.2.26 update into its own folder and run `./ApplyUpdate.sh <MIDDLEWARE_HOME>` from it, with no extra OPatch zips extracted into that folder (Readme pp. 14–15). Run `ApplyUpdate.sh -verify` first. Confirm with `opatch lsinventory` (Readme p. 20). Logs go to `EPM_ORACLE_HOME/diagnostics/logs/install/ApplyUpdate*.log`.
5. Trim: installer media, `.patch_storage`, install logs, and anything else the configurator doesn't miss (the 11.1.2.4 image learned that list the hard way).

**First container start** (marker file, like `.hasBeenConfigured`):

1. Wait for SQL Server, then create the databases (see SQL Server) and drop leftovers from a previous attempt.
2. Run RCU silently for the EPM infrastructure schemas: `oracle_common/bin/rcu -silent -createRepository -databaseType SQLSERVER ...`. Oracle's Essbase 21c container scripts already do this against SQL Server (`_createDomain.sh` lines 168–207). The guide only documents the GUI, and asks for "AS Common Schemas" except ODI and Essbase (p. 108).
3. Write `EPM_ORACLE_HOME/common/config/11.1.2.0/RCUSchema.properties`, including `schemaPrefixEssbase`/`dbURLEssbase`. **The configurator creates the Essbase RCU schema itself** from those values (pp. 113, 116–117).
4. `configtool.sh -silent <config.xml>`, templated from env vars. Passwords may be given in clear text as `<property name="password" encrypt="true">…</property>` and the configurator encrypts them in place (pp. 145–146).
5. Apply the Essbase SQL Server ODBC fix (see Gotchas).
6. Start the WebLogic Admin Server (it is required for the very first services start, p. 259), then `EPM_ORACLE_INSTANCE/bin/start.sh`. Essbase has its own `essbase_domain/esstools/bin/start.sh` (appendix F). Still to verify: whether the EPM `start.sh` starts Essbase 21c too.
7. Optionally, LCM imports from a mounted `start_scripts/` folder, exactly as the 11.1.2.4 image does.

**Later starts:** start only.

## Requirements checklist

### Host and container

- x86-64 only; Oracle Linux 8. SELinux unsupported (p. 72); ACLs must be off on the Middleware file system (p. 45).
- A non-root install user. The same user must install, configure and patch, and must be in a group with write access to `oraInventory` (p. 45).
- `/tmp`: at least 4 GB free and **not** `noexec`. `ApplyUpdate` cannot redirect TEMP (p. 72; Readme p. 14). The installer checks for twice the disk it needs.
- `ulimit -n` ≥ 8096, otherwise the ODI patch won't apply (p. 73). Set it in compose `ulimits`, as the 11.1.2.4 compose already does.
- **Host name.** EPM uses Java canonical host-name resolution and records host names in the Shared Services Registry. The name must resolve to a name, not an IP, and the first `/etc/hosts` entry should be the FQDN (pp. 43, 78–79, 106). Host names may contain only letters, digits, dash and dot, so **no underscores**: that rules out compose's default `project_service_1` style names. Use a fixed `hostname` + `domainname` in compose, check with `epmsys_hostname.sh` before configuring, and never change it after configuration. Oracle documents no 11.2 procedure for renaming an EPM host. `epmsys_registry.sh viewhosts` shows what the registry recorded. This is the same trap the 11.1.2.4 image hit with `--add-host epmvirt`.
- **Packages:** EPM defers to the FMW 12.2.1.4 list. For OL8 that is binutils, gcc, gcc-c++, glibc(-devel), libaio(-devel), libgcc, libstdc++(-devel), libnsl, sysstat, motif(-devel), redhat-lsb(-core), openssl, make and xorg-x11-utils. Financial Reporting additionally needs `libstdc++.so.6`. FMW also recommends nofile soft 4096 / hard 65536, nproc soft 2047 / hard 16384, and `kernel.shmmax=4294967295`.
- **Disk.** 16 GB for installer media and assemblies, removable after install (p. 46). Installed minimums add up to roughly 16 GB: Planning 8, Essbase 3, WebLogic 1.4, EAS 1, common 0.9, Shared Services 0.8, APS 0.7, FR 0.4 (pp. 47–48). Expect a large image, and give Docker Desktop disk accordingly.
- **Memory.** Published minimums are small: Planning 2 GB, Shared Services 1.5 GB, Essbase 1 GB, FR 1 GB (pp. 47–48). Oracle suggests a 6 GB Planning heap where 4 GB was used (p. 60). Realistically, budget 16 GB or more for the container plus about 2 GB for SQL Server, and measure. Docker Desktop is currently given about 23 GB.

### Media (what we need from Oracle Software Delivery Cloud)

- **Needed:** EPM System 11.2.15 for Linux x86-64 **Parts 1 to 6**, and the 11.2.26 update for Linux.
  - The install guide (p. 68) names only Parts 1–4 as the "common files", but the 11.2.15 media pack readme lists all six for Planning Plus. Parts 5 and 6 appear only for the Planning, HPCM and FDMEE bundles.
  - The 11.2.26 deliverable (`V1057744-01.zip`) is **only** the update: `11.2.26.0-Update-Linux/` with `ApplyUpdate.sh`, `configureLinux.properties` and 25 patch zips. It holds no installer, so the 11.2.15 parts are a separate download.
  - Staged as `media/Hyperion_Planning_11.2.15/{Part_1..Part_6,OHS,Docs}` and `media/Planning_11.2.26_Linux/V1057744-01.zip`.
- **Not needed:** Data Relationship Management (Windows only), the client installers (Windows only, two Smart View extensions), HFM Part 5, and Oracle Internet Directory. OID is an optional external user directory; Planning works with Shared Services' native directory.
- **OPatch IDs at 11.2.26** (Readme p. 22), for reference: Planning `HP=39314811`, Calc Manager `CALC=39276159`, FR `FR=39282548`, Shared Services `HSS=39255769`, Infra `39255786`, InfraCommon `38996464`, Workspace `39243041`.

### SQL Server

- **Databases** (pp. 49, 56–58, 107, 116):
  - EPM database(s) for the Shared Services Registry/Foundation, Calc Manager, EAS and the Planning system tables. One database for all of these is allowed.
  - A separate **RCU** database for the FMW infrastructure schemas. Each RCU schema needs its own login in distributed setups (p. 107); irrelevant for a single host.
  - The **Essbase RCU** schema, which the configurator creates via `schemaPrefixEssbase`/`dbURLEssbase` (format `host:port:databaseName`).
  - **One database per Planning application** (p. 49), so the Vision sample needs its own.
- **Settings:**
  - EPM databases: `COLLATE SQL_Latin1_General_CP1_CI_AS`, `READ_COMMITTED_SNAPSHOT ON`, `ALLOW_SNAPSHOT_ISOLATION ON` (p. 58).
  - RCU database: `READ_COMMITTED_SNAPSHOT ON`, `COLLATE Latin1_General_CS_AS` (case-sensitive; pp. 57–58).
  - Mixed-mode authentication.
  - The login needs `db_owner` and `BULK INSERT`. The guide's own non-admin recipe still assigns `sysadmin` (pp. 57–58). Use `sa` for a dev image.
- **JDBC URL form:** `jdbc:weblogic:sqlserver://host:port;databaseName=db` (pp. 116, appendix E).
- **Password rules, which constrain each other:**
  - `sysDBAPassword` and RCU schema password: at most **16** characters. The RCU password must start with a letter and only `$ # _` are allowed as specials (pp. 108, 112–113, 117). **So the SA password can be at most 16 characters**, while still meeting SQL Server's complexity rule.
  - WebLogic admin password: 8–30 characters, starts with a letter, includes a number, specials only `$ # _` (p. 151).
  - Shared Services admin password: at most 16 characters, at least one digit (p. 137).
  - Simplest is one password of letters, digits and `_`, 16 characters or fewer, starting with a letter.
- **Version:** see Certification. Cessna's notes record that FMW 12c RCU warns that SQL Server 2019 is "more recent than the supported list" but proceeds. EPM 11.2.26 is on FMW 12.2.1.4, so expect the same behaviour.

### Products and configuration choices

- **Install:** Foundation Services (Shared Services + Workspace), Calculation Manager (Planning business rules), Essbase 21c (server + APS + EAS Lite) and Planning. Financial Reporting is optional and pending a decision.
- **Deploy to a single managed server** (`EPMServer0`, 9000/9443). That means less memory, faster start, one port (p. 130), and it matches the 11.1.2.4 image.
- **No OHS.** The installer's embedded WebLogic HTTP proxy is meant for exactly this (dev) case (p. 75). That avoids OHS prerequisites, Node Manager and the OL9 workarounds.
- **Shared Services native directory**; no OID or LDAP.
- **Essbase application port range:** the default is 31768–32768, two ports per application (appendix A). **Don't narrow it.** Cessna found that Essbase 21c sizes its application slots from the range and refuses to configure with "Number of available applications is too small." Leave the range unpublished instead: Planning reaches Essbase inside the container, and Smart View and JAPI go through `/essbase` on 9010.

### Ports (defaults, appendix A)

| Port | What |
| --- | --- |
| 7001 | EPM WebLogic Admin Server (domain `EPMSystem`) |
| 9000 / 9443 | Single managed server `EPMServer0` (all EPM web apps when deployed to one server) |
| 28080 / 28443 | Foundation (Shared Services/Workspace) when not on a single server; `/workspace/refresh` uses it (p. 153) |
| 8300 / 8343 | Planning web app (separate-server deployment) |
| 11333 | Planning RMI server |
| 8500 / 8543 | Calculation Manager (separate-server deployment) |
| 7010 / 7020 | Essbase domain Admin Server |
| 9010 / 9020 | Essbase managed server: APS / `/essbase` (JAPI, Smart View, XMLA) |
| 9110 / 9120 | EAS Lite |
| 1423 / 6423 | Essbase agent / SSL agent |
| 31768–32768 | Essbase application servers (ESSSVR) |
| 9556 | Node Manager |
| 19000 | OHS (not planned) |

Planning's Essbase data source URL is now `http://host:port/essbase/agent?ClusterName=…` (appendix B).

## Gotchas to design around

- **Essbase can't be reconfigured, and components can't be added after the initial configuration** (ch. 3). Configuration must be right the first time, so containers should be disposable. Keep the 11.1.2.4 image's "drop and recreate the databases on first-time configuration" behaviour so a failed attempt can simply be retried.
- **Essbase 21.8.1 on SQL Server needs a manual ODBC fix after the 11.2.26 update.** `odbc.ini` (under `essbase_domain/config/fmwconfig/essconfig/core`) and `odbcinst.ini` must point at the DataDirect 8.0.2 drivers, e.g. `.../oracle.essbase.datadirect.odbc/7.1.6/lib/ARsqls27.so` → `.../8.0.2/lib/ARsqls28.so` (Readme pp. 14–17). Known issues 39039397 and 39010704 say Planning sample (Vision) creation fails on SQL Server without it. Script it into the first-start step.
- **First start after configuration needs the Admin Server running** (p. 259).
- **ApplyUpdate replaces the JDK**, so any `cacerts` customisation has to happen after the update (Readme p. 13). This only matters if we add certificates.
- **Response files must be recorded through the GUI.** That means one session with X11/VNC, in a throwaway OL8 amd64 container or a VM, for each of `installTool.sh -record` and `configtool.sh -record`. Then template them. Whether `-silent` runs with no `DISPLAY` at all is unconfirmed, so test it early. An older known issue (31181551, 11.2.7) says that deploying to a single managed server in silent mode on Linux fails unless `<auto_port_tick>` is true. Check whether it still applies.
- **Configure-time state is one-shot.** Database connection details can't be changed after configuration, a reinstall can't reuse the Shared Services Registry database, and Essbase can't be reconfigured. So host name, database endpoint and passwords are fixed at configure time. Windows authentication to SQL Server can't be configured, and SSL to SQL Server isn't supported for RCU. Neither matters for us.
- **Planning application creation is wizard-only.** Neither the Planning data source nor the application has a documented command line in 11.2. An LCM import creates the application if a data source with the matching name already exists (`EPM_ORACLE_INSTANCE/bin/Utility.sh <definition.xml>`). The data source itself still has to be created first, somehow. This is the main unknown for a fully scripted Vision. The Planning system database (`HSPSYS_*` tables) is created by the configurator's Planning "Configure Database" task.
- **Validation:** `EPM_ORACLE_INSTANCE/bin/validate.sh` runs EPM System Diagnostics. It could serve as a container health check, or at least a post-configuration gate.
- **Configuration under Rosetta will be slow.** Cessna's standalone Essbase 21c first boot takes about 5 minutes on the M1 Max; full EPM configuration is a much bigger job. Measure it before deciding whether to pre-bake a configured snapshot.
- **Coming in 11.2.27 (October 2026):** SSO backward compatibility is removed and HPCM Detailed apps are dropped (Readme pp. 7–8). Neither affects Planning, but it's worth knowing before rebasing.

## Certification

From Oracle's EPM 11.2.x certification matrix (https://www.oracle.com/a/tech/docs/epm-11-2-x-cert-matrix.xlsx, updated July 27, 2026):

- **Server OS:** Oracle Linux 7/8/9 (UL0+, listed with UEK) and RHEL 7/8/9 (UL0+), x64 only. Linux 8 arrived in 11.2.15, Linux 9 in 11.2.25. Planning is supported on Linux; the Linux exclusions are DRM (all), plus HFM on Linux 7.
- **SQL Server:** 2016 SP2+, 2017, 2019, and 2022 (2022 since 11.2.16), as repository and as data source. Drivers: DataDirect ODBC 8.0.2 and WebLogic JDBC. **SQL Server 2022 is certified**, so `mcr.microsoft.com/mssql/server:2022-latest` is the natural pick. The matrix is silent on the database server's own OS, so whether SQL Server *on Linux* (the container) counts is unconfirmed. The FMW 12.2.1.4 RCU check may still warn about newer versions, as Cessna saw with 2019.
- **Middleware/JDK:** WebLogic and OHS 12.2.1.4+; Oracle JDK 1.8.0_491+. A newer Java 8 can be swapped into `Middleware/jdk` (copy `cacerts` across). Another vendor or a newer major version is not certified.
- **Containers:** no public EPM 11.2 document mentions Docker, containers or Kubernetes. Virtualization is referred to MOS Doc ID 2688099.1 (not public). Treat the image as a development and test vehicle, not a supported deployment.

## Open questions

1. **Media:** does the 11.2.26 Linux deliverable contain the 11.2.15 base parts? The folder is empty right now.
2. **Scope:** Foundation + Calc Manager + Essbase + Planning for certain. Financial Reporting too?
3. **First-start configuration vs a pre-configured snapshot:** first-start is simpler and honest about host names. A snapshot (a committed container plus a SQL Server backup) starts fast but freezes the host name and passwords. Suggest starting with first-start and revisiting once timings are known.
4. **Sample application:** creating the data source and application is wizard-only. Options: accept a manual first step, automate the web UI, or pre-create the data source by some undocumented route and then LCM-import a known application. Worth deciding how much "fully scripted" matters.
5. **Where builds run:** Rosetta on the M1 Max, or an x86 host?

## Proposed next steps

1. Land the Linux media and inventory it: part names, the update folder layout, any sample response files.
2. Spike in a throwaway OL8 amd64 container with a GUI (VNC) against a SQL Server container. Record install and configuration response files, and note timings, memory and gotchas.
3. Write the Dockerfile (install + ApplyUpdate) and the entrypoint (database prep, RCU, `RCUSchema.properties`, configtool, ODBC fix, start, LCM imports).
4. Write the compose file: SQL Server + Planning, health checks, `ulimits`, fixed host name, volumes for `start_scripts` and the LCM import/export location.
