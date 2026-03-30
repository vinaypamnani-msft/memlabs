/*
Author: Tim Helton (Timhe)
Date: Jan 15, 2025
Purpose: This script changes the compatibility levels of all CM_xxx databases to 150 if they are greater than 150.
*/

DECLARE @exec NVARCHAR(MAX)
DECLARE @dbName NVARCHAR(128)
DECLARE @sql NVARCHAR(MAX)
DECLARE @level INT

SELECT @level =
    MAX(compatibility_level)
FROM sys.databases
WHERE name LIKE 'CM[_]___'

PRINT @level

IF @level <= 150
BEGIN
    PRINT 'DB is already below level 150'
    RETURN
END

DECLARE db_cursor CURSOR FOR
SELECT name
FROM sys.databases
WHERE name LIKE 'CM[_]___'
  AND is_read_only = 0

OPEN db_cursor
FETCH NEXT FROM db_cursor INTO @dbName

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT @dbName
    BEGIN TRY
        SET @exec = QUOTENAME(@dbname) + N'.sys.sp_executesql'
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@dbname) + N' SET COMPATIBILITY_LEVEL = 150'
        EXEC @exec @sql
    END TRY
    BEGIN CATCH
        PRINT 'Error occurred in database: ' + @dbName
        PRINT 'Error Message: ' + ERROR_MESSAGE()
    END CATCH

    FETCH NEXT FROM db_cursor INTO @dbName
END

CLOSE db_cursor
DEALLOCATE db_cursor
