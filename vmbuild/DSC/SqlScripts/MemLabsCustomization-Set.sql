/*
Author: Larry Mosley (lamosley)
Date: May 6, 2025
Purpose: This script creates a stored procedure named [dbo].[SearchAllTables] that searches all columns of all tables in specified databases for a given search string. 
It also includes logic to drop the existing stored procedure if it already exists.
The SearchAllTables script is courtesy Narayana Vyas Kondreddi
*/


DECLARE @sql NVARCHAR(MAX)
DECLARE @dropSql NVARCHAR(MAX)
DECLARE @exec NVARCHAR(MAX)

-- Define the SQL script to drop the existing stored procedure if it exists
SET @dropSql = '
IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N''[dbo].[SearchAllTables]'') AND type in (N''P'', N''PC''))
BEGIN
    DROP PROCEDURE [dbo].[SearchAllTables]
END
'

-- Define the SQL script to create the SearchAllTables
SET @sql = '
CREATE PROC [dbo].[SearchAllTables]
(
                @SearchStr nvarchar(100)
)
AS
BEGIN

                -- Purpose: To search all columns of all tables for a given search string
                -- Written by: Narayana Vyas Kondreddi
                -- Site: http://vyaskn.tripod.com
                -- Tested on: SQL Server 7.0 and SQL Server 2000
                -- Date modified: 28th July 2002 22:50 GMT


                CREATE TABLE #Results (ColumnName nvarchar(370), ColumnValue nvarchar(3630))

                SET NOCOUNT ON

                DECLARE @TableName nvarchar(256), @ColumnName nvarchar(128), @SearchStr2 nvarchar(110)
                SET  @TableName = ''''
                SET @SearchStr2 = QUOTENAME(''%'' + @SearchStr + ''%'','''''''')

                WHILE @TableName IS NOT NULL
                BEGIN
                                SET @ColumnName = ''''
                                SET @TableName = 
                                (
                                                SELECT MIN(QUOTENAME(TABLE_SCHEMA) + ''.'' + QUOTENAME(TABLE_NAME))
                                                FROM   INFORMATION_SCHEMA.TABLES
                                                WHERE                                 TABLE_TYPE = ''BASE TABLE''
                                                                AND       QUOTENAME(TABLE_SCHEMA) + ''.'' + QUOTENAME(TABLE_NAME) > @TableName
                                                                AND       OBJECTPROPERTY(
                                                                                                OBJECT_ID(
                                                                                                                QUOTENAME(TABLE_SCHEMA) + ''.'' + QUOTENAME(TABLE_NAME)
                                                                                                                 ), ''IsMSShipped''
                                                                                                       ) = 0
                                )

                                WHILE (@TableName IS NOT NULL) AND (@ColumnName IS NOT NULL)
                                BEGIN
                                                SET @ColumnName =
                                                (
                                                                SELECT MIN(QUOTENAME(COLUMN_NAME))
                                                                FROM   INFORMATION_SCHEMA.COLUMNS
                                                                WHERE                                 TABLE_SCHEMA               = PARSENAME(@TableName, 2)
                                                                                AND       TABLE_NAME    = PARSENAME(@TableName, 1)
                                                                                AND       DATA_TYPE IN (''char'', ''varchar'', ''nchar'', ''nvarchar'', ''uniqueidentifier'',''text'',''ntext'',''xml'',''varbinary'')
                                                                                AND       QUOTENAME(COLUMN_NAME) > @ColumnName

                                                )
                
                                                IF @ColumnName IS NOT NULL
                                                BEGIN
                                                                INSERT INTO #Results
                                                                EXEC
                                                                (
                                                                                ''SELECT '''''' + @TableName + ''.'' + @ColumnName + '''''', LEFT(CAST('' + @ColumnName + '' AS nvarchar(max)), 3630) 
                                                                                FROM '' + @TableName + '' (NOLOCK) '' +
                                                                                '' WHERE CAST('' + @ColumnName + '' AS nvarchar(max)) LIKE '' + @SearchStr2
                                                
                                                                )
                                                                --Print @TableName
                                                END

                                END       
                END

                SELECT ColumnName, ColumnValue FROM #Results
END
'

-- Iterate through databases and add the stored procedure
DECLARE @dbName NVARCHAR(128)
DECLARE db_cursor CURSOR FOR
SELECT name
FROM sys.databases
WHERE (name = 'SUSDB' OR name LIKE 'CM[_]___') -- Only match CM_XXX databases
AND is_read_only = 0

OPEN db_cursor
FETCH NEXT FROM db_cursor INTO @dbName

WHILE @@FETCH_STATUS = 0
BEGIN
	PRINT @dbName
	BEGIN TRY
		--When running scripts, you cannot just 'USE database' as it doesn't change the context from SSMS, and the CREATE PROCEDURE command must be in its own batch
		SET @exec = QUOTENAME(@dbname) + N'.sys.sp_executesql'		--example CM_PS1.sys.sp_executesql
		EXEC @exec @dropSql		--drop the SP if it exists
		EXEC @exec @sql			--add the SP
	END TRY
	    BEGIN CATCH
        PRINT 'Error occurred in database: ' + @dbName
        PRINT 'Error Message: ' + ERROR_MESSAGE()
    END CATCH

    FETCH NEXT FROM db_cursor INTO @dbName
END

CLOSE db_cursor
DEALLOCATE db_cursor
