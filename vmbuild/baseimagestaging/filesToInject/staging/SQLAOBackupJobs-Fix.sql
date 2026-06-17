/*
Purpose: Repair MemLabs SQLAO Ola Hallengren backup agent job steps.

Two historical defects this fix covers:
  1) Unquoted NUL token in @Directory (legacy generator bug): T-SQL parsed
     `@Directory = NUL` as a column reference and the job failed with
     "Invalid column name 'NUL'". Intended value is the string 'NUL', which
     Ola's DatabaseBackup proc special-cases to write to the NUL device.
  2) `@ChangeBackupType = 'Y'` on the FULL step: only supported by Ola for
     differential and log backups (it tells the proc to fall back to FULL
     if the requested type isn't possible -- meaningless for a FULL). The
     current MaintenanceSolution.sql from olahallengren/sql-server-
     maintenance-solution rejects it with: "Setting @ChangeBackupType to
     'Y' is only supported with differential and log backups." Older
     versions silently accepted it.

Idempotent: each branch's IF EXISTS only matches the broken signature; once
repaired, re-runs are no-ops.
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
@ExcludeLogShippedFromLogBackup = ''N''';

-- LOG step: only repair the legacy unquoted-NUL form. Quoted form + the
-- ChangeBackupType parameter are both valid for LOG backups (the proc
-- uses ChangeBackupType to fall back to FULL when no FULL exists yet).
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
    PRINT 'Repaired LOG job step (unquoted NUL)';
END
ELSE
    PRINT 'LOG job step OK or not present';

-- FULL step: repair both the legacy unquoted-NUL form AND the current
-- @ChangeBackupType = 'Y' form (invalid for FULL in current Ola releases).
IF EXISTS (
    SELECT 1
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
    WHERE j.name = N'MemLabs DatabaseBackup - AVAILABILITY_GROUP_DATABASES - FULL'
      AND s.step_id = 1
      AND (s.command LIKE N'%@Directory = NUL,%'
           OR s.command LIKE N'%@ChangeBackupType%')
)
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
         @job_name = N'MemLabs DatabaseBackup - AVAILABILITY_GROUP_DATABASES - FULL',
         @step_id  = 1,
         @command  = @fullCmd;
    PRINT 'Repaired FULL job step (removed @ChangeBackupType / fixed NUL)';
END
ELSE
    PRINT 'FULL job step OK or not present';
