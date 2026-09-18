$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$version = (Get-Content -LiteralPath (Join-Path $repo 'package.json') -Raw | ConvertFrom-Json).version
$stage = Join-Path $repo ('dist/stage-' + [guid]::NewGuid().ToString('N'))
$resource = Join-Path $stage 'bckt'
New-Item -ItemType Directory -Path $resource -Force | Out-Null
foreach ($item in @('fxmanifest.lua', 'config.lua', 'server', 'client', 'web', 'docs', 'examples', 'README.md', 'LICENSE', 'CHANGELOG.md')) {
    Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $resource -Recurse
}
$archive = Join-Path $repo "dist/bckt-cfx-$version.zip"
Compress-Archive -LiteralPath $resource -DestinationPath $archive -Force
Write-Output $archive
