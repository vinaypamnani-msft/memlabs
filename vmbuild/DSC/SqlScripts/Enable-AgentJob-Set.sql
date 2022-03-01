USE MSDB;
GO

DECLARE @job_id uniqueidentifier

DECLARE job_cursor CURSOR READ_ONLY FOR  
SELECT job_id
FROM msdb.dbo.sysjobs
WHERE enabled = 0
  AND [name] like N'MemLabs%'

OPEN job_cursor   
FETCH NEXT FROM job_cursor INTO @job_id  

WHILE @@FETCH_STATUS = 0
BEGIN
   EXEC msdb.dbo.sp_update_job @job_id = @job_id, @enabled = 1
   FETCH NEXT FROM job_cursor INTO @job_id  
END

CLOSE job_cursor   
DEALLOCATE job_cursor