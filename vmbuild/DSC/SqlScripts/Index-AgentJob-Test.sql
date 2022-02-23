
if (select count(jv.name) from msdb.dbo.sysjobs_view jv Where jv.Name = N'MemLabs IndexOptimize - USER_DATABASES') = 0
BEGIN
    RAISERROR ('AgentJob is not installed', 16, 1)
END
ELSE
BEGIN
    PRINT ('AgentJob is installed')
END
