param(
  [string]$LinuxPublicIP = '3.96.161.15',
  [string]$LinuxPrivateIP = '10.10.50.90',
  [switch]$PreferPrivate = $true,
  [string]$FtpUser='bccc',[string]$FtpPass='0123456789',
  [string]$PgDb='bccc',[string]$PgUser='bccc',[string]$PgPass='0123456789',
  [string]$MongoUser='bccc',[string]$MongoPass='0123456789',[string]$MongoAuthDb='admin',
  [int]$PgPort=5432,[int]$MongoPort=27017
)
$ErrorActionPreference='Stop'
$Log=Join-Path $env:TEMP 'trafficgen.log'
function Log($m){$ts=(Get-Date).ToString('s');"$ts $m"|Add-Content -Encoding UTF8 -Path $Log}

$TargetHost=$LinuxPublicIP
if($PreferPrivate){
  try{ if((Test-NetConnection -ComputerName $LinuxPrivateIP -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded){$TargetHost=$LinuxPrivateIP} }catch{}
}
Log "Using target $TargetHost"

function Ensure-Choco{ if(-not(Get-Command choco -ErrorAction SilentlyContinue)){ Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) } }
function Ensure-Package($n,$p=$null){ if(-not(choco list --local-only|Select-String -SimpleMatch $n)){ if($p){choco install $n -y --no-progress --params $p|Out-Null}else{choco install $n -y --no-progress|Out-Null} } }
Ensure-Choco; Ensure-Package 'postgresql'; Ensure-Package 'mongosh'; Ensure-Package 'winscp'
$PsqlPath=(Get-ChildItem "C:\Program Files\PostgreSQL" -Directory|Sort-Object Name -Descending|Select-Object -First 1|%{Join-Path $_.FullName "bin\psql.exe"})
$MongoshExe=(Get-Command mongosh -ErrorAction SilentlyContinue).Source
$WinScpExe=(Get-Command winscp.com -ErrorAction SilentlyContinue).Source
if(-not(Test-Path $PsqlPath)){throw "psql.exe not found"}
if(-not(Test-Path $MongoshExe)){throw "mongosh not found"}
if(-not(Test-Path $WinScpExe)){throw "WinSCP not found"}

function Get-FtpListing($u,$user,$pass){$r=[System.Net.FtpWebRequest]::Create($u);$r.Method=[System.Net.WebRequestMethods+Ftp]::ListDirectory;$r.Credentials=New-Object System.Net.NetworkCredential($user,$pass);$r.UseBinary=$true;$r.EnableSsl=$false;$resp=$r.GetResponse();try{$sr=New-Object IO.StreamReader($resp.GetResponseStream());($sr.ReadToEnd()-split "`r?`n")|?{$_ -and $_ -ne '.' -and $_ -ne '..'}}finally{$resp.Close()}}
function Invoke-FtpDownload($rp,$lp,$user,$pass){$r=[System.Net.FtpWebRequest]::Create($rp);$r.Method=[System.Net.WebRequestMethods+Ftp]::DownloadFile;$r.Credentials=New-Object System.Net.NetworkCredential($user,$pass);$r.UseBinary=$true;$r.EnableSsl=$false;$resp=$r.GetResponse();try{$resp.GetResponseStream().CopyTo([IO.File]::Create($lp))}finally{$resp.Close()}}
function Invoke-FtpUpload($lp,$rp,$user,$pass){$b=[IO.File]::ReadAllBytes($lp);$r=[System.Net.FtpWebRequest]::Create($rp);$r.Method=[System.Net.WebRequestMethods+Ftp]::UploadFile;$r.Credentials=New-Object System.Net.NetworkCredential($user,$pass);$r.UseBinary=$true;$r.EnableSsl=$false;$r.ContentLength=$b.Length;$s=$r.GetRequestStream();try{$s.Write($b,0,$b.Length)}finally{$s.Close()}$r.GetResponse().Close()}
function Invoke-FtpDelete($rp,$user,$pass){$r=[System.Net.FtpWebRequest]::Create($rp);$r.Method=[System.Net.WebRequestMethods+Ftp]::DeleteFile;$r.Credentials=New-Object System.Net.NetworkCredential($user,$pass);$r.UseBinary=$true;$r.EnableSsl=$false;$r.GetResponse().Close()}

while($true){
  $iter=[guid]::NewGuid().ToString('N')
  $work=Join-Path $env:TEMP ("net-traffic-"+$iter); New-Item -ItemType Directory -Path $work -Force|Out-Null
  Log "Iteration $iter start"
  try{
    # 1) FTP download -> delete
    $ftpBase="ftp://$($FtpUser):$($FtpPass)@$TargetHost"
    $files=Get-FtpListing "$ftpBase/downloads" $FtpUser $FtpPass
    if(-not $files -or $files.Count -eq 0){throw "No files in /downloads"}
    $pick=Get-Random -InputObject $files
    $local1=Join-Path $work $pick; Invoke-FtpDownload "$ftpBase/downloads/$pick" $local1 $FtpUser $FtpPass; Remove-Item $local1 -Force
    Log "FTP download ok ($pick)"

    # 2) Internet download -> upload -> delete
    $urls=@('https://speed.hetzner.de/1MB.bin','https://speed.hetzner.de/2MB.bin','https://speed.hetzner.de/5MB.bin','https://speed.hetzner.de/10MB.bin','https://proof.ovh.net/files/1Mb.dat','https://proof.ovh.net/files/10Mb.dat')
    $u=Get-Random -InputObject $urls
    $local2=Join-Path $work ("netfile-"+[guid]::NewGuid().ToString('N')+"-"+(Split-Path $u -Leaf))
    Invoke-WebRequest -Uri $u -OutFile $local2 -UseBasicParsing
    $up="winup-"+[guid]::NewGuid().ToString('N')+"-"+(Split-Path $local2 -Leaf)
    Invoke-FtpUpload $local2 "$ftpBase/uploads/$up" $FtpUser $FtpPass; Invoke-FtpDelete "$ftpBase/uploads/$up" $FtpUser $FtpPass; Remove-Item $local2 -Force
    Log "FTP upload ok ($up)"

    # 3) Postgres temp-only
    $pgpass=Join-Path $work "pgpass.txt"
    ('{0}:{1}:{2}:{3}:{4}' -f $TargetHost,$PgPort,$PgDb,$PgUser,$PgPass) | Out-File -FilePath $pgpass -Encoding ascii -NoNewline
    $env:PGPASSFILE=$pgpass
    $uniq=[guid]::NewGuid().ToString('N')
    $pgSql=@"
CREATE TEMP TABLE t_$uniq (id serial, payload text);
INSERT INTO pg_temp.t_$uniq(payload) SELECT md5(random()::text) FROM generate_series(1,1000);
SELECT COUNT(*) AS temp_tables FROM pg_catalog.pg_tables WHERE schemaname='pg_temp';
SELECT pg_sleep(0.5), NOW();
"@
    & "$PsqlPath" -h $TargetHost -p $PgPort -U $PgUser -d $PgDb -v "ON_ERROR_STOP=1" -c $pgSql
    Log "Postgres ok (t_$uniq)"

    # 4) Mongo via temp JS (no $ expansion)
    $col="col_"+[guid]::NewGuid().ToString('N')
    $js=@'
const c="__COL__";
const dbb=db.getSiblingDB("bccc");
const col=dbb.getCollection(c);
let bulk=[];
for(let i=0;i<1000;i++){bulk.push({i,ts:new Date(),s:Math.random().toString(36).slice(2)})}
col.insertMany(bulk);
col.aggregate([{ $match:{ i:{ $gte:500 } }},{ $group:{ _id:null, c:{ $sum:1 }}}]).toArray();
col.drop();
'@
    $js=$js -replace '__COL__',$col
    $jsFile=Join-Path $work ("mongo-"+$col+".js"); Set-Content -Path $jsFile -Value $js -Encoding ascii
    & "$MongoshExe" "mongodb://$($MongoUser):$($MongoPass)@$TargetHost:$MongoPort/$MongoAuthDb?tls=false" --quiet --file $jsFile
    Log "Mongo ok ($col)"

    # 5) SCP (WinSCP) pull os-release -> delete
    $wc=Join-Path $work 'winscp.txt'
@"
open scp://$FtpUser:$FtpPass@$TargetHost/ -hostkey=*
get /etc/os-release "$work\os-release"
exit
"@ | Out-File -FilePath $wc -Encoding ascii
    & "$WinScpExe" "/ini=nul" "/script=$wc"|Out-Null
    Remove-Item (Join-Path $work 'os-release') -Force -ErrorAction SilentlyContinue
    Log "SCP ok"
  }catch{ Log "ERROR: $($_.Exception.Message)" }finally{ try{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}catch{} }
  $mins=Get-Random -Minimum 1 -Maximum 61; Log "Sleeping $mins minutes"; Start-Sleep -Seconds ($mins*60)
}
