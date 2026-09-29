# Signs a packed hap with the SDK's debug profile + OpenHarmony test keystore (Windows).
# Usage: sign-hap.ps1 -Toolchain <toolchains/lib> -In <unsigned.hap> -Out <signed.hap>
#                      -Bundle <bundle-name> [-Udid "id1,id2"]
param(
    [Parameter(Mandatory = $true)][string]$Toolchain,
    [Parameter(Mandatory = $true)][string]$In,
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string]$Bundle,
    [string]$Udid = ""
)
$ErrorActionPreference = "Stop"

$work = Join-Path (Split-Path -Parent $Out) "profile-work"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# 1) debug profile from the SDK template (validity refreshed, bundle name + UDID applied)
$template = Join-Path $Toolchain "UnsgnedDebugProfileTemplate.json"
$profile = Join-Path $work "profile.json"
$json = Get-Content -Raw -Path $template | ConvertFrom-Json
$now = [int][double]::Parse((Get-Date -UFormat %s))
$json.validity.'not-before' = $now - 3600
$json.validity.'not-after' = $now + (10 * 365 * 24 * 3600)
$json.'bundle-info'.'bundle-name' = $Bundle
if ($Udid -ne "") {
    $ids = $Udid.Split(",") | Where-Object { $_ -ne "" }
    $json | Add-Member -NotePropertyName 'debug-info' -NotePropertyValue @{ 'device-ids' = $ids } -Force
}
$json | ConvertTo-Json -Depth 10 | Set-Content -Path $profile

$hapSign = Join-Path $Toolchain "hap-sign-tool.cmd"
if (-not (Test-Path $hapSign)) { $hapSign = Join-Path $Toolchain "hap-sign-tool.bat" }
if (-not (Test-Path $hapSign)) {
    # the dotnet tool ships as a jar next to a launcher; try the plain name on PATH
    $hapSign = "hap-sign-tool"
}

# 2) sign the profile, 3) sign the hap, 4) verify
& $hapSign sign-profile -keyAlias "openharmony application profile debug" -signAlg SHA256withECDSA `
    -mode localSign -profileCertFile (Join-Path $Toolchain "OpenHarmonyProfileDebug.pem") `
    -inFile $profile -keystoreFile (Join-Path $Toolchain "OpenHarmony.p12") `
    -outFile (Join-Path $work "debug.p7b") -keyPwd 123456 -keystorePwd 123456
& $hapSign sign-app -keyAlias "openharmony application release" -signAlg SHA256withECDSA `
    -mode localSign -appCertFile (Join-Path $Toolchain "OpenHarmonyApplication.pem") `
    -profileFile (Join-Path $work "debug.p7b") -inFile $In `
    -keystoreFile (Join-Path $Toolchain "OpenHarmony.p12") -outFile $Out `
    -keyPwd 123456 -keystorePwd 123456 -signCode 1
& $hapSign verify-app -inFile $Out -outCertChain (Join-Path $work "out.cer") -outProfile (Join-Path $work "out.p7b")

Write-Host "signed: $Out"
