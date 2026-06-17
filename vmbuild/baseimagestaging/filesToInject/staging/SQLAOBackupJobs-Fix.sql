/*
Purpose: Repair MemLabs SQLAO Ola Hallengren backup agent job steps that were
created with an unquoted NUL token. T-SQL parses `@Directory = NUL` as a
column reference and the job fails with "Invalid column name 'NUL'".
The intended value is the string 'NUL', which Ola's DatabaseBackup proc
special-cases to write to the NUL device for log-chain hygiene.

Idempotent: only updates job steps whose @command still contains the broken
pattern. Safe to re-run.
*/

USE msdb;

DECLARE @logCmd NVARCHAR(MAX) = N'EXECUTE [dbo].[DatabaseBackup]
@Databases = ''AVAILABILITY_GROUP_DATABASES'',
@Directory = ''NUL'',
@BackupType = ''LOG'',
@Verify = ''N'',
@CleanupTime = NULL,
@CheckSum = ''N'',
@LogToTable = ''Y'',
@ChangeBackupType = ''Y'',
@ExcludeLogShippedFromLogBackup = ''N''';

DECLARE @fullCmd NVARCHAR(MAX) = N'EXECUTE [dbo].[DatabaseBackup]
@Databases = ''AVAILABILITY_GROUP_DATABASES'',
@Directory = ''NUL'',
@BackupType = ''FULL'',
@Verify = ''N'',
@CleanupTime = NULL,
@CheckSum = ''N'',
@LogToTable = ''Y'',
@ChangeBackupType = ''Y'',
@ExcludeLogShippedFromLogBackup = ''N''';

IF EXISTS (
    SELECT 1
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
    WHERE j.name = N'MemLabs DatabaseBackup - AVAILABILITY_GROUP_DATABASES - LOG'
      AND s.step_id = 1
      AND s.command LIKE N'%@Directory = NUL,%'
)
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
         @job_name = N'MemLabs DatabaseBackup - AVAILABILITY_GROUP_DATABASES - LOG',
         @step_id  = 1,
         @command  = @logCmd;
    PRINT 'Repaired LOG job step';
END
ELSE
    PRINT 'LOG job step OK or not present';

IF EXISTS (
    SELECT 1
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
    WHERE j.name = N'MemLabs DatabaseBackup - AVAILABILITY_GROUP_DATABASES - FULL'
      AND s.step_id = 1
      AND s.command LIKE N'%@Directory = NUL,%'
)
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
         @job_name = N'MemLabs DatabaseBackup - AVAILABILITY_GROUP_DATABASES - FULL',
         @step_id  = 1,
         @command  = @fullCmd;
    PRINT 'Repaired FULL job step';
END
ELSE
    PRINT 'FULL job step OK or not present';
