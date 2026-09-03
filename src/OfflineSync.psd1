@{
    RootModule        = 'OfflineSync.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a1b2c3d4-1111-4222-8333-94a5b6c7d8e9'
    Author            = 'PakageSync'
    CompanyName       = 'PakageSync'
    Copyright         = '(c) PakageSync'
    Description       = 'PakageSync offline one-way sync shared library (config, logging, utils, winget common). Loads every script under lib\ and exports all public *-OSync* functions.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('*')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('PakageSync', 'OfflineSync')
        }
    }
}
