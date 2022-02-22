SELECT jv.name from msdb.dbo.sysjobs_view jv Where jv.Name = N'DatabaseBackup - AVAILABILITY_GROUP_DATABASES - LOG' FOR JSON AUTO
