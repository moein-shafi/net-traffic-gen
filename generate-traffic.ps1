param(
  [string]$LinuxPublicIP = '3.96.161.15',
  [string]$LinuxPrivateIP = '10.10.50.90',
  [switch]$PreferPrivate = $true,

  [string]$FtpUser = 'bccc',
  [string]$FtpPass = '0123456789',
  [string]$PgDb = 'bccc',
  [string]$PgUser = 'bccc',
  [string]$PgPass = '0123456789',
  [string]$MongoUser = 'bccc',
  [string]$MongoPass = '0123456789',
  [string]$MongoAuthDb = 'admin',
  [int]$PgPort = 5432,
  [int]$MongoPort = 27017
)

$ErrorActionPreference = 'Stop'

# --- pick target host (private if reachable) ---
$TargetHost = $LinuxPublicIP
if ($PreferPrivate) {
  try {
    if ((Test-NetConnection -ComputerName $LinuxPrivateIP -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
      $TargetHost = $LinuxPrivateIP
    }
  } catch {}
}

# --- helpers: Chocolatey + packages ---
function Ensure-Choco {
  if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  }
}
function Ensure-Package($name, $params = $null) {
  if (-not (choco list --local-only | Select-String -SimpleMatch $name)) {
    if ($params) { choco install $name -y --no-progress --params $params | Out-Null }
    else { choco install $name -y --no-progress | Out-Null }
  }
}

# --- working dir & random file list ---
$WorkDir = Join-Path $env:TEMP ("net-traffic-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WorkDir | Out-Null

$RandomFileUrls = @(
  'https://speed.hetzner.de/1MB.bin',
  'https://speed.hetzner.de/2MB.bin',
  'https://speed.hetzner.de/5MB.bin',
  'https://speed.hetzner.de/10MB.bin',
  'https://proof.ovh.net/files/1Mb.dat',
  'https://proof.ovh.net/files/10Mb.dat'
)

# --- ensure clients available ---
Ensure-Choco
Ensure-Package 'postgresql'   # provides psql.exe
Ensure-Package 'mongosh'
Ensure-Package 'winscp'       # provides winscp.com (CLI), supports SCP protocol

$PsqlPath   = (Get-ChildItem "C:\Program Files\PostgreSQL" -Directory | Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName "bin\psql.exe" })
$MongoshExe = (Get-Command mongosh -ErrorAction SilentlyContinue).Source
$WinScpExe  = (Get-Command winscp.com -ErrorAction SilentlyContinue).Source

if (-not (Test-Path $PsqlPath))   { throw "psql.exe not found" }
if (-not (Test-Path $MongoshExe)) { throw "mongosh not found" }
if (-not (Test-Path $WinScpExe))  { throw "WinSCP (winscp.com) not found" }

# --- FTP helpers ---
function Get-FtpListing($uri, $user, $pass) {
  $req = [System.Net.FtpWebRequest]::Create($uri)
  $req.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectory
  $req.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
  $req.UseBinary = $true; $req.EnableSsl = $false
  $resp = $req.GetResponse()
  try {
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
    ($sr.ReadToEnd() -split "`r?`n") | Where-Object { $_ -and $_ -ne '.' -and $_ -ne '..' }
  } finally { $resp.Close() }
}
function Invoke-FtpDownload($remotePath, $localPath, $user, $pass) {
  $req = [System.Net.FtpWebRequest]::Create($remotePath)
  $req.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
  $req.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
  $req.UseBinary = $true; $req.EnableSsl = $false
  $resp = $req.GetResponse()
  try { $resp.GetResponseStream().CopyTo([System.IO.File]::Create($localPath)) } finally { $resp.Close() }
}
function Invoke-FtpUpload($localPath, $remotePath, $user, $pass) {
  $bytes = [System.IO.File]::ReadAllBytes($localPath)
  $req = [System.Net.FtpWebRequest]::Create($remotePath)
  $req.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
  $req.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
  $req.UseBinary = $true; $req.EnableSsl = $false
  $req.ContentLength = $bytes.Length
  $stream = $req.GetRequestStream()
  try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Close() }
  $req.GetResponse().Close()
}
function Invoke-FtpDelete($remotePath, $user, $pass) {
  $req = [System.Net.FtpWebRequest]::Create($remotePath)
  $req.Method = [System.Net.WebRequestMethods+Ftp]::DeleteFile
  $req.Credentials = New-Object System.Net.NetworkCredential($user, $pass)
  $req.UseBinary = $true; $req.EnableSsl = $false
  $req.GetResponse().Close()
}

# ==== (1) FTP: download random file, then delete locally ====
$ftpBase = "ftp://$($FtpUser):$($FtpPass)@$TargetHost"
$downloads = Get-FtpListing "$ftpBase/downloads" $FtpUser $FtpPass
if (-not $downloads -or $downloads.Count -eq 0) { throw "No files in /downloads on FTP server." }
$pick = Get-Random -InputObject $downloads
$local1 = Join-Path $WorkDir $pick
Invoke-FtpDownload "$ftpBase/downloads/$pick" $local1 $FtpUser $FtpPass
Remove-Item $local1 -Force

# ==== (2) Internet: download 1–10MB → upload to FTP /uploads → delete remote & local ====
$randomUrl = Get-Random -InputObject $RandomFileUrls
$local2 = Join-Path $WorkDir ("netfile-" + [guid]::NewGuid().ToString('N') + "-" + (Split-Path $randomUrl -Leaf))
Invoke-WebRequest -Uri $randomUrl -OutFile $local2 -UseBasicParsing
$remoteUpName = ("winup-" + [guid]::NewGuid().ToString('N') + "-" + (Split-Path $local2 -Leaf))
Invoke-FtpUpload $local2 "$ftpBase/uploads/$remoteUpName" $FtpUser $FtpPass
Invoke-FtpDelete "$ftpBase/uploads/$remoteUpName" $FtpUser $FtpPass
Remove-Item $local2 -Force

# ==== (3) PostgreSQL: TEMP-only activity (no collisions) ====
$pgPassFile = Join-Path $WorkDir "pgpass.txt"
"$TargetHost:$PgPort:$PgDb:$PgUser:$PgPass" | Out-File -FilePath $pgPassFile -Encoding ascii -NoNewline
$env:PGPASSFILE = $pgPassFile

$uniq = [guid]::NewGuid().ToString('N')
$pgSql = @"
CREATE TEMP TABLE t_$uniq (id serial, payload text);
INSERT INTO pg_temp.t_$uniq(payload) SELECT md5(random()::text) FROM generate_series(1,1000);
SELECT COUNT(*) AS temp_tables FROM pg_catalog.pg_tables WHERE schemaname='pg_temp';
SELECT pg_sleep(0.5), NOW();
"@
& "$PsqlPath" -h $TargetHost -p $PgPort -U $PgUser -d $PgDb -v "ON_ERROR_STOP=1" -c $pgSql

# ==== (4) MongoDB: insert→aggregate→drop in GUID collection ====
$col = "col_" + [guid]::NewGuid().ToString('N')
$mongoJs = @"
const dbb = db.getSiblingDB('bccc');
const col = dbb.getCollection('$col');
let bulk = [];
for (let i=0; i<1000; i++) { bulk.push({i, ts:new Date(), s:Math.random().toString(36).slice(2)}); }
col.insertMany
