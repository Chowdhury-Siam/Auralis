#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Repository = $env:GITHUB_REPOSITORY
if ($env:GITHUB_EVENT_NAME -notin @('push', 'workflow_dispatch') -or
    ($env:GITHUB_REF_TYPE -ne 'tag' -and
     -not ($env:GITHUB_REF_TYPE -eq 'branch' -and $env:GITHUB_REF_NAME -eq 'main'))) {
    throw 'Only main builds and stable version tags can publish a release.'
}
if ($Repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid GitHub repository.' }
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Version = & (Join-Path $PSScriptRoot 'package.ps1') -ValidateOnly
$Tag = "v$Version"
$Commit = $env:GITHUB_SHA
if ($Commit -notmatch '^[0-9a-f]{40}$' -or (git -C $ProjectRoot rev-parse HEAD) -ne $Commit) {
    throw 'The checkout must match the tested GitHub commit.'
}
$Dist = Join-Path $ProjectRoot 'dist'
$Names = @("auralis-$Version-windows-x64.zip", "auralis-$Version-windows-x64-setup.exe", "auralis-$Version-source.zip", 'SHA256SUMS.txt')
$Files = $Names | ForEach-Object {
    $Path = Join-Path $Dist $_
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Release asset missing: $_" }
    $Path
}
$Pages = gh api --paginate --slurp "repos/$Repository/releases?per_page=100" | ConvertFrom-Json
$Releases = @($Pages | ForEach-Object { $_ })
$Existing = $Releases | Where-Object tag_name -eq $Tag
if ($Existing -and -not $Existing.draft) {
    if ($Existing.prerelease) { throw 'This version is already a prerelease. Choose a new stable version.' }
    Write-Output "$Tag is already stable. Bump pubspec.yaml for another release; published assets are never replaced."
    exit 0
}
$TagRef = gh api "repos/$Repository/git/matching-refs/tags/$Tag" `
    --jq "[.[] | select(.ref == `"refs/tags/$Tag`")]" | ConvertFrom-Json
if ($TagRef) {
    $TaggedCommit = gh api "repos/$Repository/commits/$Tag" --jq '.sha'
    if ($TaggedCommit -ne $Commit) { throw "$Tag points to another commit. Bump pubspec.yaml; tags are never moved." }
} elseif ($env:GITHUB_REF_TYPE -eq 'tag') {
    throw "The triggering tag $Tag does not exist."
} else {
    gh api --method POST "repos/$Repository/git/refs" -f "ref=refs/tags/$Tag" -f "sha=$Commit" | Out-Null
}
if (-not $Existing) {
    gh release create $Tag --repo $Repository --verify-tag --draft --prerelease=false --title "Auralis $Version" --generate-notes
}
$ReleaseId = gh release view $Tag --repo $Repository --json databaseId --jq '.databaseId'
if ($ReleaseId -notmatch '^[1-9]\d*$') { throw 'GitHub returned an invalid draft release ID.' }
$Draft = gh api "repos/$Repository/releases/$ReleaseId" | ConvertFrom-Json
if ($Draft.tag_name -ne $Tag -or -not $Draft.draft -or $Draft.prerelease) {
    throw 'Expected an unpublished stable draft for this version; no assets were changed.'
}
gh release upload $Tag @Files --repo $Repository --clobber
# Keep the release unpublished until every server-side digest matches its file.
$Release = gh api "repos/$Repository/releases/$ReleaseId" | ConvertFrom-Json
foreach ($Path in $Files) {
    $Name = [System.IO.Path]::GetFileName($Path)
    $Asset = @($Release.assets | Where-Object name -eq $Name)
    $Expected = 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Asset.Count -ne 1 -or $Asset[0].digest -ne $Expected) { throw "GitHub digest mismatch for $Name. Release remains a draft." }
}
$Newer = @($Releases | Where-Object {
    -not $_.draft -and -not $_.prerelease -and
    $_.tag_name -match '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -and
    [version]$_.tag_name.Substring(1) -gt [version]$Version
})
$Latest = if ($Newer.Count) { 'false' } else { 'true' }
gh release edit $Tag --repo $Repository --draft=false --prerelease=false "--latest=$Latest"
