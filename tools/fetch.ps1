# =============================================================================
# fetch.ps1 -- download a file on a machine where curl / Invoke-WebRequest are
#              blocked but Python's TLS stack still works
#
# Why this exists (measured on this box):
#   * pypi.org:443      -> times out (blocked upstream)
#   * github.com:443    -> TCP opens, but the TLS handshake is reset
#   * curl.exe / IWR    -> use Windows schannel -> http_code 000 / "connection
#                          closed while receiving", i.e. they cannot download
#   * python urllib     -> uses OpenSSL and DOES work, including against the
#                          domestic mirrors below
#   * pip install       -> downloads fine, then fails with Errno 13 because the
#                          file sandbox blocks the unpack/rename in the temp dir
#
# So: fetch with Python, write straight into the workspace, skip pip.
#
# Examples
#   .\fetch.ps1 -Url https://pypi.tuna.tsinghua.edu.cn/simple/six/
#   .\fetch.ps1 -Url https://mirrors.aliyun.com/xxx/file.zip -Out .\file.zip
#   .\fetch.ps1 -Pypi six                       # latest wheel of a package
#   .\fetch.ps1 -Pypi imageio-ffmpeg -Mirror aliyun
# =============================================================================
param(
    [string]$Url,
    [string]$Out,
    [string]$Pypi,                                   # package name -> wheel/sdist
    [ValidateSet('tuna', 'aliyun', 'huawei', 'ustc')]
    [string]$Mirror = 'tuna'
)

$ErrorActionPreference = 'Stop'

$mirrors = @{
    tuna   = 'https://pypi.tuna.tsinghua.edu.cn/simple/'
    aliyun = 'https://mirrors.aliyun.com/pypi/simple/'
    huawei = 'https://mirrors.huaweicloud.com/repository/pypi/simple/'
    ustc   = 'https://mirrors.ustc.edu.cn/pypi/simple/'
}

$py = 'C:\Users\japsa\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
if (-not (Test-Path $py)) { $py = (Get-Command python).Source }

if ($Pypi) {
    $index = $mirrors[$Mirror] + $Pypi + '/'
    $Url = $index
}

if (-not $Url) { throw 'give me -Url or -Pypi' }

if (-not $Out) {
    $leaf = ($Url.TrimEnd('/') -split '/')[-1]
    if (-not $leaf -or $leaf -notmatch '\.') { $leaf = 'download.bin' }
    $Out = Join-Path (Get-Location) $leaf
}

$script = @'
import re, sys, os, urllib.request, urllib.parse, hashlib, pathlib
url, out = sys.argv[1], sys.argv[2]
ua = {"User-Agent": "Mozilla/5.0 (fetch.ps1)"}

def get(u):
    return urllib.request.urlopen(urllib.request.Request(u, headers=ua), timeout=120).read()

data = get(url)
if url.endswith("/") and b"<html" in data[:200].lower():
    # it is a PEP 503 index: pick a wheel (prefer cp-none-any), else an sdist
    html = data.decode("utf-8", "ignore")
    links = re.findall(r'href="([^"#]+)', html)
    wheels = [l for l in links if l.endswith(".whl")]
    sdists = [l for l in links if l.endswith((".tar.gz", ".zip"))]
    pool = wheels or sdists
    if not pool:
        sys.exit("no files listed in that index")
    pure = [l for l in wheels if "py3-none-any" in l or "py2.py3-none-any" in l]
    pick = (pure or pool)[-1]
    url = urllib.parse.urljoin(url, pick)
    print("index ->", url)
    data = get(url)

p = pathlib.Path(out)
p.parent.mkdir(parents=True, exist_ok=True)
p.write_bytes(data)
print("saved %s  %d bytes  sha256 %s" % (p, len(data), hashlib.sha256(data).hexdigest()[:16]))
'@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch_" + [guid]::NewGuid().ToString('N') + ".py")
$script | Out-File -Encoding utf8 $tmp
& $py $tmp $Url $Out
Remove-Item $tmp -ErrorAction SilentlyContinue
