-- Databases for EPM 11.2.26 on SQL Server, created the way Oracle's install guide
-- requires (Preparing a Database / Using a Microsoft SQL Server Database). Run by the
-- mssql-init service with sqlcmd variables EPM_DB, RCU_DB and PLANNING_APP_DB.
--
-- Settings are made at creation and only changed when wrong, because changing them
-- needs exclusive access: RCU can't re-collate a database it has open, and this script
-- runs on every `docker compose up`, possibly with EPM already connected.

SET NOCOUNT ON;

-- EPM repository (Shared Services registry, Calculation Manager, EAS, Planning system
-- tables) and the Planning application database: case-insensitive, with read committed
-- snapshot and snapshot isolation on. Each Planning application needs its own database.
IF DB_ID(N'$(EPM_DB)') IS NULL
    CREATE DATABASE [$(EPM_DB)] COLLATE SQL_Latin1_General_CP1_CI_AS;
IF DB_ID(N'$(PLANNING_APP_DB)') IS NULL
    CREATE DATABASE [$(PLANNING_APP_DB)] COLLATE SQL_Latin1_General_CP1_CI_AS;

-- RCU's database: case-sensitive, with read committed snapshot on.
IF DB_ID(N'$(RCU_DB)') IS NULL
    CREATE DATABASE [$(RCU_DB)] COLLATE Latin1_General_CS_AS;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(EPM_DB)' AND is_read_committed_snapshot_on = 0)
    ALTER DATABASE [$(EPM_DB)] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(EPM_DB)' AND snapshot_isolation_state = 0)
    ALTER DATABASE [$(EPM_DB)] SET ALLOW_SNAPSHOT_ISOLATION ON;

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(PLANNING_APP_DB)' AND is_read_committed_snapshot_on = 0)
    ALTER DATABASE [$(PLANNING_APP_DB)] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(PLANNING_APP_DB)' AND snapshot_isolation_state = 0)
    ALTER DATABASE [$(PLANNING_APP_DB)] SET ALLOW_SNAPSHOT_ISOLATION ON;

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(RCU_DB)' AND is_read_committed_snapshot_on = 0)
    ALTER DATABASE [$(RCU_DB)] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

SELECT name,
       collation_name,
       is_read_committed_snapshot_on AS rcsi,
       snapshot_isolation_state_desc AS snapshot_isolation
  FROM sys.databases
 WHERE name IN (N'$(EPM_DB)', N'$(RCU_DB)', N'$(PLANNING_APP_DB)')
 ORDER BY name;
GO
