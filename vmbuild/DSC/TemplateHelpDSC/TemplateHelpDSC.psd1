﻿@{

# Script module or binary module file associated with this manifest.
RootModule = 'TemplateHelpDSC.psm1'

DscResourcesToExport = @(
    'InstallADK',
    'InstallSSMS',
    'InstallDotNet4',
    'InstallODBCDriver',
    'InstallReportBuilder',
    'InstallOleDbDriver',
    'InstallVCRedist',
    'InstallSqlClient',
    'InstallAndConfigWSUS',
    'WriteEvent',
    'WaitForEvent',
    'DelegateControl',
    'AddNtfsPermissions',
    'WaitForDomainReady',
    'VerifyComputerJoinDomain',
    'SetDNS',
    'WriteStatus',
    'WriteFileOnce',
    'ChangeSqlInstancePort',
    'ChangeSQLServicesAccount',
    'RegisterTaskScheduler',
    'DownloadSCCM',
    'DownloadFile',
    'WaitForExtendSchemaFile',
    'InitializeDisks',
    'AddUserToLocalAdminGroup',
    'JoinDomain',
    'OpenFirewallPortForSCCM',
    'InstallFeatureForSCCM',
    'SetCustomPagingFile',
    'FileReadAccessShare',
    'InstallCA',
    'ModuleAdd',
    'ClusterRemoveUnwantedIPs',
    'ClusterSetOwnerNodes',
    'ConfigureWSUS',
    'WSUSSync',
    'InstallPBIRS',
    'AddCertificateTemplate',
    'ImportCertifcateTemplate',
    'AddCertificateToIIS',
    'RebootNow',
    'AddToAdminGroup',
    'UpdateCAPrefs',
    'InstallRootCertificate',
    'RunPkiSync',
    'GpUpdate'


)

# Version number of this module.
ModuleVersion = '1.0'

# ID used to uniquely identify this module
GUID = 'dade476b-0e1f-4c41-91c6-8b39ea182f40'

# Author of this module
Author = 'Microsoft Corporation'

# Company or vendor of this module
CompanyName = 'Microsoft Corporation'

# Copyright statement for this module
Copyright = '(c) 2014 Microsoft. All rights reserved.'

# Description of the functionality provided by this module
# Description = ''

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '5.0'

# Name of the Windows PowerShell host required by this module
# PowerShellHostName = ''
}