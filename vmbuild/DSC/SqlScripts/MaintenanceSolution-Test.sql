use master

if (select count(name) from sys.tables where name = 'CommandLog') = 0
BEGIN
    RAISERROR ('MaintenanceSolution is not installed', 16, 1)
END
ELSE
BEGIN
    PRINT ('MaintenanceSolution is installed')
END
