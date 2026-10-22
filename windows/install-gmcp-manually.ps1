# Installs the gMCP extension by hand, for when Claude Desktop's installer fails
# with "EPERM: operation not permitted, chmod".
#
# Run in PowerShell. Point $Bundle at the gmcp.mcpb you downloaded.
# Close Claude Desktop first.

param(
    [string]$Bundle = "$env:USERPROFILE\Downloads\gmcp.mcpb"
)

if (-not (Test-Path $Bundle)) {
    Write-Error "Bundle not found at $Bundle. Pass -Bundle <path> to point at it."
    exit 1
}

# Where Claude Desktop keeps extensions depends on its version: newer ones use
# %LOCALAPPDATA%\Claude-Data\claude_<id>, older ones a virtualised Packages folder.
# The id varies, so look in both, newest layout first.
$candidates = @()
$candidates += Get-ChildItem "$env:LOCALAPPDATA\Claude-Data" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "claude*" } |
    ForEach-Object { Join-Path $_.FullName "Claude Extensions" }
$candidates += Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*laude*" } |
    ForEach-Object { Join-Path $_.FullName "LocalCache\Roaming\Claude\Claude Extensions" }
$extRoot = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $extRoot) {
    Write-Error "Couldn't find the Claude Extensions folder. Is Claude Desktop installed and run at least once?"
    exit 1
}

$target = Join-Path $extRoot "local.mcpb.ben-johnston.gmcp"
Write-Output "Installing to: $target"

# The usual cause of the installer's "EPERM: chmod" failure is a running gmcp.exe
# holding the file open, so clear that first rather than fighting it.
# Only copies run from this extension folder: any other gmcp.exe (another app's) is
# left alone.
$running = Get-Process gmcp -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($target, [System.StringComparison]::OrdinalIgnoreCase) }
if ($running) {
    Write-Output "Stopping $($running.Count) running gmcp process(es) holding the binary open."
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
}
# Matched by install location, not just name: Claude Code's CLI is also claude.exe.
$desktop = Get-Process -Name "Claude" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "*\WindowsApps\Claude_*" -or $_.Path -like "*\AnthropicClaude\*" }
if ($desktop) {
    Write-Warning "Claude Desktop is still running. Quit it completely (check the system tray) and re-run this, or the binary may stay locked."
}

if (Test-Path $target) { Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $target -Force | Out-Null

# A .mcpb is a zip. Expand-Archive needs the extension to match, so copy it first.
$tmpZip = Join-Path $env:TEMP "gmcp-bundle.zip"
Copy-Item $Bundle $tmpZip -Force
Expand-Archive -Path $tmpZip -DestinationPath $target -Force
Remove-Item $tmpZip -Force

Write-Output ""
Write-Output "Installed files:"
Get-ChildItem $target -Recurse -File | ForEach-Object { "{0,12}  {1}" -f $_.Length, $_.FullName.Replace($target, '.') }

$exe = Join-Path $target "server\gmcp.exe"
if (Test-Path $exe) {
    Write-Output ""
    Write-Output "Checking the binary runs:"
    & $exe --help | Select-Object -First 2
    Write-Output ""
    Write-Output "Done. Open Claude Desktop, check gMCP's settings under Settings, Extensions (it needs"
    Write-Output "the Client ID and Secret of your Desktop app OAuth client), then ask Claude to"
    Write-Output "open the gMCP Connect page to connect your Google services."
} else {
    Write-Error "server\gmcp.exe is missing. Download gmcp.exe from the Releases page and place it at $exe"
}
