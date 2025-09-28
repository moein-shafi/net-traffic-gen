# Create a fresh, self-contained generator at C:\Windows\Temp\trafficgen.ps1
$scriptPath = 'C:\Windows\Temp\trafficgen.ps1'
$script = @"
param(
  [string]$LinuxPublicIP = '3.96.161.15',
  [string]$LinuxPrivateIP = '10.10.50.90',
  [switch]$PreferPrivate = \$true,

  [string]$FtpUser = 'bccc',
  [string]$FtpPass = '0123456789',
  [string]$PgDb    = 'bccc',
  [string]$PgUser  = 'bccc',
  [string]$PgPass  = '0123456789',
  [string]$MongoUser  = 'bccc',
  [string]$MongoPass  = '0123456789',
  [string]$MongoAuthDb= 'admin',
  [int]$PgPort = 5432,
  [int]$MongoPort = 27017
)

# ---------- helpers ----------
\$LogFile = 'C:\Windows\Temp\trafficgen.log'
function Log(\$m){ \$ts=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Add-Content -Path \$LogFile -Value "\$ts \$m" }

# Ensure we only ever run one instance
Add-Type -AssemblyName System.Core
\$mutex = New-Object System.Threading.Mutex(\$false,'Global\\TrafficGenMutex')
if(-not \$mutex.WaitOne(0)){ Log 'Another instance is running. Exiting.'; return }

try {
  # TLS12 for downloads
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

  function Ensure-Choco {
    if(-not (Get-Command choco -ErrorAction SilentlyContinue)){
      Log 'Installing Chocolatey...'
      Set-ExecutionPolicy Bypass -Scope Process -Force
      Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
      Log 'Chocolatey installed.'
    }
  }
  function Ensure-Package(\$name){
    if(-not (choco list --local-only --exact \$name 2>\$null | Select-String -SimpleMatch \$name)){
      Log "Installing package \$name ..."
      choco install \$name -y --no-progress | Out-Null
      Log "Installed package \$name."
    } else {
      Log "Package \$name already present."
    }
  }

  function Resolve-TargetHost {
    \$target = \$LinuxPublicIP
    if(\$PreferPrivate){
      try{
        \$ok = (Test-NetConnection -ComputerName \$LinuxPrivateIP -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded
        if(\$ok){ \$target = \$LinuxPrivateIP }
      }catch{}
    }
    return \$target
  }

  # .NET FTP helpers (passive)
  function Get-FtpListing(\$uri,\$user,\$pass){
    \$req = [System.Net.FtpWebRequest]::Create(\$uri)
    \$req.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectory
    \$req.Credentials = New-Object System.Net.NetworkCredential(\$user,\$pass)
    \$req.UseBinary = \$true; \$req.EnableSsl = \$false; \$req.UsePassive=\$true
    \$resp = \$req.GetResponse()
    try{
      \$sr = New-Object System.IO.StreamReader(\$resp.GetResponseStream())
      (\$sr.ReadToEnd() -split "`r?`n") | Where-Object { \$_ -and \$_ -ne '.' -and \$_ -ne '..' }
    } finally { \$resp.Close() }
  }
  function Invoke-FtpDownload(\$remote,\$local,\$user,\$pass){
    \$req = [System.Net.FtpWebRequest]::Create(\$remote)
    \$req.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
    \$req.Credentials = New-Object System.Net.NetworkCredential(\$user,\$pass)
    \$req.UseBinary=\$true; \$req.EnableSsl=\$false; \$req.UsePassive=\$true
    \$resp = \$req.GetResponse()
    try { \$resp.GetResponseStream().CopyTo([System.IO.File]::Create(\$local)) } finally { \$resp.Close() }
  }
  function Invoke-FtpUpload(\$local,\$remote,\$user,\$pass){
    \$bytes = [System.IO.File]::ReadAllBytes(\$local)
    \$req = [System.Net.FtpWebRequest]::Create(\$remote)
    \$req.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
    \$req.Credentials = New-Object System.Net.NetworkCredential(\$user,\$pass)
    \$req.UseBinary=\$true; \$req.EnableSsl=\$false; \$req.UsePassive=\$true
    \$req.ContentLength = \$bytes.Length
    \$stream = \$req.GetRequestStream(); try { \$stream.Write(\$bytes,0,\$bytes.Length) } finally { \$stream.Close() }
    \$req.GetResponse().Close()
  }
  function Invoke-FtpDelete(\$remote,\$user,\$pass){
    \$req = [System.Net.FtpWebRequest]::Create(\$remote)
    \$req.Method = [System.Net.WebRequestMethods+Ftp]::DeleteFile
    \$req.Credentials = New-Object System.Net.NetworkCredential(\$user,\$pass)
    \$req.UseBinary=\$true; \$req.EnableSsl=\$false; \$req.UsePassive=\$true
    \$req.GetResponse().Close()
  }

  # Download pool (1–10MB)
  \$RandomFileUrls = @(
    'https://speed.hetzner.de/1MB.bin',
    'https://speed.hetzner.de/2MB.bin',
    'https://speed.hetzner.de/5MB.bin',
    'https://speed.hetzner.de/10MB.bin',
    'https://proof.ovh.net/files/1Mb.dat',
    'https://proof.ovh.net/files/10Mb.dat'
  )

  # Ensure client tooling
  Ensure-Choco
  Ensure-Package 'postgresql'   # for psql.exe
  # mongosh: try 'mongosh' first, fallback to mongodb-shell
  if(-not (Get-Command mongosh -ErrorAction SilentlyContinue)){ Ensure-Package 'mongosh' }
  if(-not (Get-Command mongosh -ErrorAction SilentlyContinue)){ Ensure-Package 'mongodb-shell' }
  Ensure-Package 'winscp'

  # Resolve tool paths
  \$PsqlPath = \$null
  \$pgDirs = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
  if(\$pgDirs){ \$PsqlPath = Join-Path \$pgDirs[0].FullName 'bin\psql.exe' }
  if(-not (Test-Path \$PsqlPath)){ throw 'psql.exe not found (PostgreSQL client not installed?)' }

  \$MongoshExe = (Get-Command mongosh -ErrorAction SilentlyContinue).Source
  if(-not (Test-Path \$MongoshExe)){ throw 'mongosh not found (MongoDB Shell not installed?)' }

  \$WinScpExe = \$null
  foreach(\$p in @('C:\Program Files\WinSCP\winscp.com','C:\Program Files (x86)\WinSCP\winscp.com')){
    if(Test-Path \$p){ \$WinScpExe = \$p; break }
  }
  if(-not \$WinScpExe){ throw 'WinSCP (winscp.com) not found' }

  # Main loop forever
  while(\$true){
    try{
      \$TargetHost = Resolve-TargetHost
      Log "TargetHost=\$TargetHost"

      # Work dir
      \$WorkDir = Join-Path \$env:TEMP ("net-traffic-" + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path \$WorkDir -Force | Out-Null

      # --- 1) FTP: download a random file from /downloads and delete local copy
      \$ftpBase = "ftp://\$FtpUser:`\$FtpPass@\$TargetHost"
      \$list = Get-FtpListing "\$ftpBase/downloads" \$FtpUser \$FtpPass
      if(-not \$list -or \$list.Count -eq 0){ Log 'No FTP files to download in /downloads'; }
      else{
        \$pick = Get-Random -InputObject \$list
        \$local1 = Join-Path \$WorkDir \$pick
        Log "FTP GET downloads/\$pick"
        Invoke-FtpDownload "\$ftpBase/downloads/\$pick" \$local1 \$FtpUser \$FtpPass
        Remove-Item \$local1 -Force -ErrorAction SilentlyContinue
      }

      # --- 2) Internet download 1–10MB → upload to /uploads → delete remote & local
      \$url = Get-Random -InputObject \$RandomFileUrls
      \$local2 = Join-Path \$WorkDir ("netfile-" + [guid]::NewGuid().ToString('N') + "-" + (Split-Path \$url -Leaf))
      Log "HTTP GET \$url"
      Invoke-WebRequest -UseBasicParsing -Uri \$url -OutFile \$local2
      \$remoteName = ("winup-" + [guid]::NewGuid().ToString('N') + "-" + (Split-Path \$local2 -Leaf))
      Log "FTP PUT uploads/\$remoteName"
      Invoke-FtpUpload \$local2 "\$ftpBase/uploads/\$remoteName" \$FtpUser \$FtpPass
      Invoke-FtpDelete "\$ftpBase/uploads/\$remoteName" \$FtpUser \$FtpPass
      Remove-Item \$local2 -Force -ErrorAction SilentlyContinue

      # --- 3) PostgreSQL: TEMP operations (no shared state)
      \$pgpass = Join-Path \$WorkDir 'pgpass.txt'
      \$pgLine = "{0}:{1}:{2}:{3}:{4}" -f \$TargetHost,\$PgPort,\$PgDb,\$PgUser,\$PgPass
      \$pgLine | Out-File -FilePath \$pgpass -Encoding ascii -NoNewline
      \$env:PGPASSFILE = \$pgpass

      \$pgSql = @"
DO \$\$ BEGIN END \$\$;
CREATE TEMP TABLE t_$(Get-Random) (id serial, payload text);
INSERT INTO pg_temp.t_$(Get-Random)(payload) SELECT md5(random()::text) FROM generate_series(1,500);
SELECT COUNT(*) AS c FROM pg_catalog.pg_tables WHERE schemaname='pg_temp';
SELECT pg_sleep(0.5), NOW();
"@
      Log 'psql TEMP ops'
      & "\$PsqlPath" -h \$TargetHost -p \$PgPort -U \$PgUser -d \$PgDb -v "ON_ERROR_STOP=1" -c \$pgSql | Out-Null

      # --- 4) MongoDB: insert → aggregate → drop in a GUID collection
      \$col = "col_" + [guid]::NewGuid().ToString('N')
      \$mongoConn = ("mongodb://{0}:{1}@{2}:{3}/{4}?tls=false" -f \$MongoUser,\$MongoPass,\$TargetHost,\$MongoPort,\$MongoAuthDb)
      \$mongoJs = @"
const dbb = db.getSiblingDB('bccc');
const col = dbb.getCollection('$col');
let bulk = [];
for (let i=0; i<1000; i++) { bulk.push({i:i, ts:new Date(), s:Math.random().toString(36).slice(2)}); }
col.insertMany(bulk);
col.aggregate([{ \$match:{ i:{ \$gte:500 } }},{ \$group:{ _id:null, c:{ \$sum:1 }}}]).toArray();
col.drop();
"@
      Log 'mongosh ops'
      & "\$MongoshExe" "\$mongoConn" --quiet --eval \$mongoJs | Out-Null

      # --- 5) SFTP via WinSCP: pull /etc/os-release then delete
      \$ws = @"
option batch on
option confirm off
open sftp://\$FtpUser:\$FtpPass@\$TargetHost/ -hostkey=*
get /etc/os-release "\$WorkDir\\os-release"
exit
"@
      \$wsPath = Join-Path \$WorkDir 'winscp.txt'
      Set-Content -Path \$wsPath -Value \$ws -Encoding ascii
      Log 'WinSCP get /etc/os-release'
      & "\$WinScpExe" "/ini=nul" "/script=\$wsPath" | Out-Null
      Remove-Item (Join-Path \$WorkDir 'os-release') -Force -ErrorAction SilentlyContinue

      # --- Sleep 1–60 minutes
      \$mins = Get-Random -Minimum 1 -Maximum 61
      Log "Sleeping \$mins minutes"
      Start-Sleep -Seconds (\$mins*60)

      Remove-Item \$WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
      Log ("ERROR: " + \$_.Exception.Message)
      Start-Sleep -Seconds 10
    }
  }
}
finally {
  try { \$mutex.ReleaseMutex() } catch {}
  \$mutex.Dispose()
}
"@
Set-Content -Path $scriptPath -Value $script -Encoding UTF8
Write-Host "Wrote $scriptPath"
