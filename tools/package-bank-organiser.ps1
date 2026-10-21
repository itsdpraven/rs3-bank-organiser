# Builds the Plugin Hub upload for Bank Organiser:
#   dist\bank-organiser-<version>.zip  containing only main.lua, plugin.json and src\
# (tests\, the README and the dev-only probe/testkit plugins never ship).
# Stops with an error if anything would get the plugin rejected.
#
#   powershell -ExecutionPolicy Bypass -File tools\package-bank-organiser.ps1
#   (add -AllowPlaceholderEmail to build a test zip before the email is set)
param([switch]$AllowPlaceholderEmail)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$plugin = Join-Path $root "bank-organiser"
$problems = @()

# plugin.json: valid JSON, a numbers-and-dots version, a real contact email,
# and no empty arrays (the client fails to read those).
$manifestText = Get-Content (Join-Path $plugin "plugin.json") -Raw
try { $manifest = $manifestText | ConvertFrom-Json } catch { throw "plugin.json is not valid JSON: $_" }
if ($manifest.version -notmatch '^\d+(\.\d+)*$') { $problems += "version must be numbers and dots only (is '$($manifest.version)')" }
if ($manifestText -match '\[\s*\]') { $problems += "plugin.json has an empty array; remove it" }
if (-not $AllowPlaceholderEmail -and ($manifest.contactEmailAddress -match 'CHANGE-ME|example\.com' -or -not $manifest.contactEmailAddress)) {
    $problems += "contactEmailAddress is still a placeholder; use the plugin's public contact address"
}

# Shipped code: no development leftovers.
$files = @(Get-Item (Join-Path $plugin "main.lua")) + @(Get-ChildItem (Join-Path $plugin "src") -Recurse -File)
foreach ($file in $files) {
    $text = Get-Content $file.FullName -Raw
    if ($file.Name -eq "devlog.lua") { $problems += "src\devlog.lua is development-only" }
    if ($text -match 'ExecuteConsoleCommand') { $problems += "$($file.Name) runs console commands" }
    if ($text -match 'require\("src/devlog"\)') { $problems += "$($file.Name) uses the development log" }
}

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "PROBLEM: $_" -ForegroundColor Red }
    throw "Not packaged: fix the problems above."
}

# Zip: main.lua and plugin.json at the top level, plus src/. Written entry by
# entry so paths use "/" (Compress-Archive in Windows PowerShell uses "\",
# which other systems read as part of the file name).
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist ("bank-organiser-" + $manifest.version + ".zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    $shipped = @(Get-Item (Join-Path $plugin "main.lua"), (Join-Path $plugin "plugin.json")) +
        @(Get-ChildItem (Join-Path $plugin "src") -Recurse -File)
    foreach ($file in $shipped) {
        $entry = $file.FullName.Substring($plugin.Length + 1).Replace("\", "/")
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry) | Out-Null
    }
} finally {
    $archive.Dispose()
}

Write-Host "Packaged $zip"
$read = [IO.Compression.ZipFile]::OpenRead($zip)
$read.Entries | ForEach-Object { "  " + $_.FullName }
$read.Dispose()
