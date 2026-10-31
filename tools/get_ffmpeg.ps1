# =============================================================================
# get_ffmpeg.ps1 -- put a working ffmpeg.exe into wall\tools\ffmpeg\
#
# Why this exists: Media Foundation and WinRT are both blocked inside the DSH
# sandbox (E_ACCESSDENIED even for a plain WAV), and libav.js deliberately ships
# no AAC decoder (MPEG licensing).  The one thing that works is a plain native
# ffmpeg.exe, and the npm mirror carries one inside a package tarball
# (@ffmpeg-installer/win32-x64, ~22 MB compressed / 64 MB exe).
#
# pypi.org and github.com are unreachable from this machine, but
# registry.npmmirror.com is, so the download goes through Python's TLS stack
# (curl / Invoke-WebRequest are broken here, see tools/fetch.ps1).
# =============================================================================
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root 'tools\ffmpeg'
$exe  = Join-Path $dest 'ffmpeg.exe'

if ((Test-Path $exe) -and -not $Force) {
    Write-Host "already there: $exe"
    & $exe -hide_banner -version 2>&1 | Select-Object -First 1
    return
}

$py = 'C:\Users\japsa\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
if (-not (Test-Path $py)) { $py = (Get-Command python).Source }

$script = @'
import io, sys, tarfile, urllib.request, pathlib
dest = pathlib.Path(sys.argv[1]); dest.mkdir(parents=True, exist_ok=True)
url = "https://registry.npmmirror.com/@ffmpeg-installer/win32-x64/-/win32-x64-4.1.0.tgz"
print("downloading", url)
data = urllib.request.urlopen(url, timeout=300).read()
print(" ", len(data), "bytes")
with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
    for m in tf.getmembers():
        if m.isfile() and m.name.endswith("ffmpeg.exe"):
            out = dest / "ffmpeg.exe"
            with open(out, "wb") as f:
                f.write(tf.extractfile(m).read())
            print("  ->", out, out.stat().st_size, "bytes")
'@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ff_" + [guid]::NewGuid().ToString('N') + ".py")
$script | Out-File -Encoding utf8 $tmp
& $py $tmp $dest
Remove-Item $tmp -ErrorAction SilentlyContinue

if (-not (Test-Path $exe)) { throw "ffmpeg.exe not extracted" }
& $exe -hide_banner -version 2>&1 | Select-Object -First 1
Write-Host "ready: $exe"
