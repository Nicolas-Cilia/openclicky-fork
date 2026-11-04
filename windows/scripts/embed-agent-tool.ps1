# Copies the openclicky tool that agent tasks run through into the published app's agent-tool
# folder, laid out like the repository because the tool finds config\ and skills\ from where it
# sits. Needs `npm ci` and `npm run build -w agent` first. Run by the windows-release workflow.
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$tool = Join-Path $Destination 'agent-tool'
if (Test-Path $tool) { Remove-Item $tool -Recurse -Force }
foreach ($folder in 'agent\dist', 'agent\node_modules', 'config', 'macos\OpenClicky') {
    New-Item -ItemType Directory -Force -Path (Join-Path $tool $folder) | Out-Null
}
Copy-Item (Join-Path $repository 'agent\dist\*.js') (Join-Path $tool 'agent\dist')
Copy-Item (Join-Path $repository 'agent\package.json') (Join-Path $tool 'agent')
Copy-Item (Join-Path $repository 'node_modules\commander') (Join-Path $tool 'agent\node_modules') -Recurse
Copy-Item (Join-Path $repository 'config\codex-config.toml') (Join-Path $tool 'config')
Copy-Item (Join-Path $repository 'skills') $tool -Recurse
Copy-Item (Join-Path $repository 'macos\OpenClicky\VERSION') (Join-Path $tool 'macos\OpenClicky')
if (-not (Test-Path (Join-Path $tool 'agent\dist\cli.js'))) { throw 'the agent tool was not embedded' }
Write-Host "embedded the agent tool in $tool"
