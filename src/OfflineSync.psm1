# OfflineSync.psm1
# Dynamic loader: dot-sources every lib\*.ps1 and exports all public functions
# whose names match *-OSync*. New wave files are picked up automatically, so
# later waves never need to edit this file or the manifest.
$libDir = Join-Path $PSScriptRoot 'lib'
Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object {
        . $_.FullName
    }

$publicFunctionNames = @(Get-ChildItem -Path Function:\*-OSync* -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
if ($publicFunctionNames.Count -gt 0) {
    Export-ModuleMember -Function $publicFunctionNames
}
