param(
  [string]$LinuxPublicIP = '3.96.161.15',
  [string]$LinuxPrivateIP = '10.10.50.90',
  [switch]$PreferPrivate = $true,

  [string]$FtpUser = 'bccc',
  [string]$FtpPass = '0123456789',
  [string]$PgDb   = 'bccc',
  [string]$PgUser = 'bccc',
  [string]$PgPass = '0123456789',
  [string]$MongoUser = 'bccc',
  [string]$MongoPass = '0123456789',
  [string]$MongoAuthDb = 'admin',
  [int]$PgPort = 5432,
  [int]$MongoPort = 27017
)

$ErrorActionPreference = 'Stop'
$Log = Join-Path $env:TEMP "trafficgen.log"
function Log($m){ $ts = (Get-Date).ToString("s"); "$ts $m" | Add-Content -Encoding UTF8 -Path $Log }

# --- choose target host (prefer private if reachable) ---
$TargetHost = $LinuxPublicIP
if ($PreferPrivate) {
  try {
    if ((Test-NetConnection -ComputerName $LinuxPrivateIP -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded) {
      $TargetHost = $LinuxPrivateIP
    }
  } catch {}
}
Log "Using target $TargetHost"

# --- choco + clients (once) ---
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
Ensure-Choco
Ensure-Package 'postgresql'
Ensure-Package 'mongosh'
Ensure-Package 'winscp'

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

# --- Forever loop ---
while ($true) {
  $iterId = [guid]::NewGuid().ToString('N')
  $work = Join-Path $env:TEMP ("net-traffic-" + $iterId)
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  Log "Iteration $iterId start"

  try {
    # 1) FTP download random file, delete locally
    $ftpBase = "ftp://$($FtpUser):$($FtpPass)@$TargetHost"
    $downloads = Get-FtpListing "$ftpBase/downloads" $FtpUser $FtpPass
    if (-not $downloads -or $downloads.Count -eq 0) { throw "No files in /downloads on FTP server." }
    $pick = Get-Random -InputObject $downloads
    $local1 = Join-Path $work $pick
    Invoke-FtpDownload "$ftpBase/downloads/$pick" $local1 $FtpUser $FtpPass
    Remove-Item $local1 -Force
    Log "FTP ok (downloaded & deleted $pick)"

    # 2) Internet download (1–10MB) -> upload to FTP /uploads -> delete both
    $urls = @(
      'https://speed.hetzner.de/1MB.bin',
      'https://speed.hetzner.de/2MB.bin',
      'https://speed.hetzner.de/5MB.bin',
      'https://speed.hetzner.de/10MB.bin',
      'https://proof.ovh.net/files/1Mb.dat',
      'https://proof.ovh.net/files/10Mb.dat'
    )
    $randomUrl = Get-Random -InputObject $urls
    $local2 = Join-Path $work ("netfile-" + [guid]::NewGuid().ToString('N') + "-" + (Split-Path $randomUrl -Leaf))
    Invoke-WebRequest -Uri $randomUrl -OutFile $local2 -UseBasicParsing
    $remoteUpName = ("winup-" + [guid]::NewGuid().ToString('N') + "-" + (Split-Path $local2 -Leaf))
    Invoke-FtpUpload $local2 "$ftpBase/uploads/$remoteUpName" $FtpUser $FtpPass
    Invoke-FtpDelete "$ftpBase/uploads/$remoteUpName" $FtpUser $FtpPass
    Remove-Item $local2 -Force
    Log "FTP upload ok ($remoteUpName)"

    # 3) PostgreSQL temp-only activity
    $pgPassFile = Join-Path $work "pgpass.txt"
    "{0}:{1}:{2}:{3}:{4}" -f $TargetHost,$PgPort,$PgDb,$PgUser,$PgPass | Out-File -FilePath $pgPassFile -Encoding ascii -NoNewline
    $env:PGPASSFILE = $pgPassFile

    $uniq = [guid]::NewGuid().ToString('N')
    $pgSql = @"
CREATE TEMP TABLE t_$uniq (id serial, payload text);
INSERT INTO pg_temp.t_$uniq(payload) SELECT md5(random()::text) FROM generate_series(1,1000);
SELECT COUNT(*) AS temp_tables FROM pg_catalog.pg_tables WHERE schemaname='pg_temp';
SELECT pg_sleep(0.5), NOW();
"@
    & "$PsqlPath" -h $TargetHost -p $PgPort -U $PgUser -d $PgDb -v "ON_ERROR_STOP=1" -c $pgSql
    Log "Postgres ok (temp table t_$uniq)"

    # 4) MongoDB insert→aggregate→drop via temp JS file (no $ expansion issues)
    $col = "col_" + [guid]::NewGuid().ToString('N')
    $mongoJsTemplate = @'
const c = "__COL__";
const dbb = db.getSiblingDB("bccc");
const col = dbb.getCollection(c);
let bulk = [];
for (let i=0; i<1000; i++) { bulk.push({i, ts:new Date(), s:Math.random().toString(36).slice(2)}); }
col.insertMany(bulk);
col.aggregate([{ $match:{ i:{ $gte:500 } }},{ $group:{ _id:null, c:{ $sum:1 }}}]).toArray();
col.drop();
'@
    $mongoJs = $mongoJsTemplate -replace '__COL__', $col
    $mongoFile = Join-Path $work "mongo-$($col).js"
    Set-Content -Path $mongoFile -Value $mongoJs -Encoding ascii
    & "$MongoshExe" "mongodb://$($MongoUser):$($MongoPass)@$TargetHost:$MongoPort/$MongoAuthDb?tls=false" --quiet --file $mongoFile
    Log "Mongo ok ($col)"

    # 5) SCP (WinSCP): pull /etc/os-release then delete locally
    $winscpScript = Join-Path $work "winscp.txt"
    @"
open scp://$FtpUser:$FtpPass@$TargetHost/ -hostkey=*
get /etc/os-release "$work\os-release"
exit
"@ | Out-File -FilePath $winscpScript -Encoding ascii
    & "$WinScpExe" "/ini=nul" "/script=$winscpScript" | Out-Null
    Remove-Item (Join-Path $work "os-release") -Force -ErrorAction SilentlyContinue
    Log "SCP ok"

  } catch {
    Log "ERROR: $($_.Exception.Message)"
  } finally {
    try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }

  # 6) Sleep random 1–60 minutes and loop again
  $mins = Get-Random -Minimum 1 -Maximum 61
  Log "Sleeping $mins minutes before next iteration"
  Start-Sleep -Seconds ($mins * 60)
}
