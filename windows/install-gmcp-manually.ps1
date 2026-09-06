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

# Claude Desktop's data is virtualised under a Packages folder, so the id varies.
$extRoot = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*laude*" } |
    ForEach-Object { Join-Path $_.FullName "LocalCache\Roaming\Claude\Claude Extensions" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if (-not $extRoot) {
    Write-Error "Couldn't find the Claude Extensions folder. Is Claude Desktop installed and run at least once?"
    exit 1
}

$target = Join-Path $extRoot "local.mcpb.ben-johnston.gmcp"
Write-Output "Installing to: $target"

# The usual cause of the installer's "EPERM: chmod" failure is a running gmcp.exe
# holding the file open, so clear that first rather than fighting it.
$running = Get-Process gmcp -ErrorAction SilentlyContinue
if ($running) {
    Write-Output "Stopping $($running.Count) running gmcp process(es) holding the binary open."
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
}
if (Get-Process -Name "Claude" -ErrorAction SilentlyContinue) {
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
    Write-Output "Done. Start Claude Desktop, then run setup to connect your Google services:"
    Write-Output "  & `"$exe`" setup"
} else {
    Write-Error "server\gmcp.exe is missing. Download gmcp.exe from the Releases page and place it at $exe"
}
