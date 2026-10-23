param([string]$Publisher)
$ErrorActionPreference = 'Stop'

# Process-local stand-in: tests never contact or publish to GitHub.
function gh {
    $Arguments = @($args | ForEach-Object { [string]$_ })
    ConvertTo-Json -InputObject $Arguments -Compress |
        Add-Content -LiteralPath $env:AURALIS_FIXTURE_CALLS
    $Scenario = $env:AURALIS_FIXTURE_SCENARIO
    if ($Arguments[0] -eq 'api') {
        $Endpoint = $Arguments | Where-Object { $_ -like 'repos/*' } | Select-Object -First 1
        if ($Endpoint -like '*/releases?per_page=100') {
            if ($Scenario -eq 'read-failure') { throw 'Fixture GitHub permission failure' }
            switch ($Scenario) {
                'published' { return '[[{"tag_name":"v0.9.0","draft":false,"prerelease":false}]]' }
                'pagination' { return '[[],[{"tag_name":"v0.9.0","draft":false,"prerelease":false}]]' }
                'prerelease' { return '[[{"tag_name":"v0.9.0","draft":false,"prerelease":true}]]' }
                'draft' { return '[[{"tag_name":"v0.9.0","draft":true,"prerelease":false}]]' }
                'older-version' { return '[[{"tag_name":"v1.0.0","draft":false,"prerelease":false}]]' }
                default { return '[[]]' }
            }
        }
        if ($Endpoint -like '*/git/matching-refs/tags/*') {
            if ($Scenario -in @('tag', 'wrong-tag-commit', 'draft')) {
                return '[{"ref":"refs/tags/v0.9.0"}]'
            }
            return '[]'
        }
        if ($Endpoint -like '*/commits/v*') {
            if ($Scenario -eq 'wrong-tag-commit') { return ('0' * 40) }
            return $env:GITHUB_SHA
        }
        if ($Endpoint -like '*/git/refs' -and $Arguments -contains 'POST') { return '{}' }
        if ($Endpoint -like '*/releases/tags/v*') {
            throw 'Fixture HTTP 404: the by-tag endpoint does not return drafts.'
        }
        if ($Endpoint -eq 'repos/fixture/auralis/releases/101') {
            $Assets = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../dist') -File | ForEach-Object {
                $Digest = 'sha256:' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($Scenario -eq 'bad-digest') { $Digest = 'sha256:' + ('0' * 64) }
                @{name=$_.Name;digest=$Digest}
            })
            $Draft = $Scenario -ne 'draft-became-published'
            $TagName = if ($Scenario -eq 'wrong-draft-tag') { 'v0.8.0' } else { 'v0.9.0' }
            return ConvertTo-Json -Depth 5 -InputObject @{id=101;tag_name=$TagName;draft=$Draft;prerelease=$false;assets=$Assets}
        }
    }
    if ($Arguments[0] -eq 'release' -and $Arguments[1] -eq 'view') {
        if ($Scenario -eq 'lookup-failure') { throw 'Fixture draft lookup permission failure' }
        if ($Scenario -eq 'invalid-release-id') { return 'invalid/id' }
        return '101'
    }
    if ($Arguments[0] -eq 'release' -and $Arguments[1] -in @('create', 'upload', 'edit')) { return }
    throw "Unexpected fixture GitHub command: $Arguments"
}

& $Publisher
