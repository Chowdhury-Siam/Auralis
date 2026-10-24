#requires -Version 7.4
param([switch]$Installer, [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Metadata = Get-Content -LiteralPath (Join-Path $ProjectRoot 'pubspec.yaml') -Raw
$Match = [regex]::Match($Metadata, '(?m)^version:\s*(?<version>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\+\d+\s*$')
if (-not $Match.Success) { throw 'pubspec.yaml needs a stable version such as 0.1.1+2.' }
$Version = $Match.Groups['version'].Value
if ($env:GITHUB_REF_TYPE -eq 'tag' -and $env:GITHUB_REF_NAME -ne "v$Version") {
    throw "Tag $env:GITHUB_REF_NAME does not match pubspec version v$Version."
}
if ($ValidateOnly) { Write-Output $Version; exit 0 }
$Release = Join-Path $ProjectRoot 'build/windows/x64/runner/Release'
$Dist = Join-Path $ProjectRoot 'dist'
foreach ($File in @('auralis.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'native/tdjson.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Release $File))) { throw "Build output missing: $File" }
}
New-Item -ItemType Directory -Force $Dist | Out-Null
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENSE') -Destination $Release
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'README.md') -Destination $Release
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'THIRD_PARTY_NOTICES.md') -Destination $Release
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'docs') -Destination $Release -Recurse -Force
# A distributable Flutter bundle contains its DLLs and data directory as well as the EXE.
Compress-Archive -Path (Join-Path $Release '*') -DestinationPath (Join-Path $Dist "auralis-$Version-windows-x64.zip") -Force
if ($Installer) {
    $Iscc = $env:ISCC_PATH
    if ([string]::IsNullOrWhiteSpace($Iscc)) {
        $Iscc = @(
            "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe",
            "$env:ProgramFiles/Inno Setup 6/ISCC.exe",
            "$env:ProgramFiles/Inno Setup 7/ISCC.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    if ([string]::IsNullOrWhiteSpace($Iscc) -or -not (Test-Path -LiteralPath $Iscc -PathType Leaf)) {
        throw 'Install Inno Setup 6.7+ or set ISCC_PATH to its ISCC.exe before requesting an installer.'
    }
    & $Iscc /Qp (Join-Path $PSScriptRoot 'installer-compiler-check.iss')
    & $Iscc "/DAuralisVersion=$Version" (Join-Path $PSScriptRoot 'installer.iss')
}
$Source = Join-Path $Dist "auralis-$Version-source.zip"
git -C $ProjectRoot archive --format=zip --prefix=auralis/ "--output=$Source" HEAD
Get-ChildItem -LiteralPath $Dist -File -Filter "auralis-$Version-*" | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([System.IO.Path]::GetFileName($_.Path))" } |
    Set-Content (Join-Path $Dist 'SHA256SUMS.txt')
