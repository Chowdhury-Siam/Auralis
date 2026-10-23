#requires -Version 7.4
param([ValidateRange(1, 32)][int]$Jobs = 2)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:VCPKG_DISABLE_METRICS = '1'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$BuildRoot = Join-Path $ProjectRoot '.native-build'
$TdRevision = 'a94b83d67ab4c8397c6245e541b31a4131ea2f79'
$VcpkgRevision = '664933b8d385dfc01f4e0cdff4c7c74e71f6a740'
New-Item -ItemType Directory -Force $BuildRoot | Out-Null

function Get-PinnedRepository([string]$Url, [string]$Revision, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) {
        git init $Destination
        git -C $Destination remote add origin $Url
        git -C $Destination fetch --depth 1 origin $Revision
        git -C $Destination checkout --detach FETCH_HEAD
    }
    $ActualRevision = git -C $Destination rev-parse HEAD
    if ($ActualRevision -ne $Revision) { throw "Unexpected revision in $Destination. Use a fresh build directory." }
}

$TdSource = Join-Path $BuildRoot 'td'
$VcpkgRoot = Join-Path $BuildRoot 'vcpkg'
Get-PinnedRepository 'https://github.com/tdlib/td.git' $TdRevision $TdSource
Get-PinnedRepository 'https://github.com/microsoft/vcpkg.git' $VcpkgRevision $VcpkgRoot
& (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
& (Join-Path $VcpkgRoot 'vcpkg.exe') install openssl:x64-windows zlib:x64-windows gperf:x64-windows --classic
$Installed = Join-Path $VcpkgRoot 'installed/x64-windows'
$Gperf = Join-Path $Installed 'tools/gperf/gperf.exe'
if (-not (Test-Path -LiteralPath $Gperf)) { throw 'vcpkg did not install gperf.' }
$env:PATH = "$(Split-Path $Gperf -Parent);$env:PATH"
$TdBuild = Join-Path $BuildRoot 'td-build'
cmake -S $TdSource -B $TdBuild -G 'Visual Studio 17 2022' -A x64 `
    "-DCMAKE_TOOLCHAIN_FILE=$VcpkgRoot/scripts/buildsystems/vcpkg.cmake" `
    -DVCPKG_TARGET_TRIPLET=x64-windows "-DGPERF_EXECUTABLE=$Gperf" `
    -DTD_ENABLE_JNI=OFF -DTD_ENABLE_DOTNET=OFF -DTD_ENABLE_LTO=OFF `
    -DTD_INSTALL_STATIC_LIBRARIES=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build $TdBuild --config Release --target tdjson --parallel $Jobs
$Native = Join-Path $ProjectRoot 'native'
$Licenses = Join-Path $Native 'licenses'
New-Item -ItemType Directory -Force $Licenses | Out-Null
Copy-Item -LiteralPath (Join-Path $TdBuild 'Release/tdjson.dll') -Destination $Native
Get-ChildItem -LiteralPath (Join-Path $Installed 'bin') -Filter '*.dll' | Copy-Item -Destination $Native
Copy-Item -LiteralPath (Join-Path $TdSource 'LICENSE_1_0.txt') -Destination (Join-Path $Licenses 'TDLib.txt')
Copy-Item -LiteralPath (Join-Path $Installed 'share/openssl/copyright') -Destination (Join-Path $Licenses 'OpenSSL.txt')
Copy-Item -LiteralPath (Join-Path $Installed 'share/zlib/copyright') -Destination (Join-Path $Licenses 'zlib.txt')
@{tdlib=$TdRevision;vcpkg=$VcpkgRevision;triplet='x64-windows';configuration='Release'} |
    ConvertTo-Json | Set-Content (Join-Path $Native 'build-manifest.json')
Write-Output "TDLib built from pinned source in $Native"
