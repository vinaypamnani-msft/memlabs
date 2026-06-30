/*
Author: Tim Helton (Timhe)
Date: Jan 15, 2025 (updated Jun 25, 2026)
Purpose:
  Aligns the compatibility level of every CM_xxx database to the level the
  current ConfigMgr build + SQL engine support, raising OR lowering as needed:
      170  ->  ConfigMgr 2603+  AND  SQL Server 2025+ (ProductMajorVersion >= 17)
      150  ->  everything else  (the long-standing supported cap)
  The "CM >= 2603" half of the gate is decided by the caller (Fix-RunSQL.ps1)
  from the top-level site server's cmOptions.version and passed in as the
  CMSupports170 sqlcmd variable (0/1). The "SQL >= 2025" half is enforced here
  so we never attempt to set 170 on an engine that cannot support it.
*/

DECLARE @cmSupports170 INT = $(CMSupports170)
DECLARE @sqlMajor INT = TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT)
DECLARE @target INT = 150

IF @cmSupports170 = 1 AND @sqlMajor IS NOT NULL AND @sqlMajor >= 17
    SET @target = 170

PRINT 'Target compatibility level: ' + CAST(@target AS NVARCHAR(10))
    + ' (CMSupports170=' + CAST(@cmSupports170 AS NVARCHAR(10))
    + ', SQL ProductMajorVersion=' + ISNULL(CAST(@sqlMajor AS NVARCHAR(10)), 'unknown') + ')'

DECLARE @exec NVARCHAR(MAX)
DECLARE @dbName NVARCHAR(128)
DECLARE @sql NVARCHAR(MAX)
DECLARE @current INT

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'CM[_]___')
BEGIN
    PRINT 'No CM_xxx databases present - nothing to do'
    RETURN
END

IF NOT EXISTS (
    SELECT 1 FROM sys.databases
    WHERE name LIKE 'CM[_]___' AND is_read_only = 0 AND compatibility_level <> @target
)
BEGIN
    PRINT 'All CM_xxx databases already at compatibility level ' + CAST(@target AS NVARCHAR(10))
    RETURN
END

DECLARE db_cursor CURSOR FOR
SELECT name, compatibility_level
FROM sys.databases
WHERE name LIKE 'CM[_]___'
  AND is_read_only = 0
  AND compatibility_level <> @target

OPEN db_cursor
FETCH NEXT FROM db_cursor INTO @dbName, @current

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT 'Setting ' + @dbName + ' from ' + CAST(@current AS NVARCHAR(10)) + ' to ' + CAST(@target AS NVARCHAR(10))
    BEGIN TRY
        SET @exec = QUOTENAME(@dbname) + N'.sys.sp_executesql'
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@dbname) + N' SET COMPATIBILITY_LEVEL = ' + CAST(@target AS NVARCHAR(10))
        EXEC @exec @sql
    END TRY
    BEGIN CATCH
        PRINT 'Error occurred in database: ' + @dbName
        PRINT 'Error Message: ' + ERROR_MESSAGE()
    END CATCH

    FETCH NEXT FROM db_cursor INTO @dbName, @current
END

CLOSE db_cursor
DEALLOCATE db_cursor
