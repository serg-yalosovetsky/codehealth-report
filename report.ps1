<#
codehealth SergPC reporter — the Windows side of the code-quality catalog.
Enumerates local repos, runs PSScriptAnalyzer (PowerShell) + ruff (Python) + a
git-hotspot pass, then POSTs normalized results to codehealth.ibotz.fun/api/ingest.
Mirrors the mesh push model (services_report / outlook_agent): no inbound port, the
VPS never reaches into SergPC. Run under Task Scheduler; token in .ingest_token.
#>
[CmdletBinding()]
param(
  [string]$Endpoint = "https://codehealth.ibotz.fun/api/ingest",
  [string]$TokenFile = ""   # resolved in body — $PSScriptRoot is unset at param-bind
)
$ErrorActionPreference = "Stop"
# resolve script dir robustly (param defaults can't see $PSScriptRoot in some hosts)
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $TokenFile) { $TokenFile = Join-Path $Root ".ingest_token" }
$LogFile = Join-Path $Root "report.log"
trap { try { Add-Content -Path $LogFile -Value ("{0} FATAL: {1}" -f (Get-Date -Format o), $_) -Encoding utf8 } catch {}; exit 1 }

# --- config: which local roots to catalog -----------------------------------------
$ToolsRoot = "C:\Users\sergy\tools"
$ExtraRepos = @("g:\code\MapsCreator", "C:\Users\sergy\alicepc", "G:\ai\video-summarizer")
$ExtLang = @{
  ".py"="python"; ".ps1"="powershell"; ".psm1"="powershell"; ".sh"="shell";
  ".kt"="kotlin"; ".kts"="kotlin"; ".rs"="rust"; ".go"="go"; ".ts"="typescript";
  ".js"="javascript"; ".dart"="dart"; ".java"="java"
}
$NonCode = @(".md",".txt",".json",".lock",".yaml",".yml",".toml",".xml",".html",
  ".css",".csv",".log",".png",".jpg",".svg",".vbs",".bat",".cfg",".ini",".env",".bak")

function Log($m){
  $line = "{0} {1}" -f (Get-Date -Format o), $m
  try { Write-Host $line } catch {}
  try { Add-Content -Path $LogFile -Value $line -Encoding utf8 } catch {}
}

function Get-CodeFiles($repo){
  Get-ChildItem -Path $repo -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(\.git|\.venv|venv|node_modules|__pycache__|build|dist)\\' }
}
function Detect-Language($files){
  $counts = @{}
  foreach($f in $files){
    $e = $f.Extension.ToLower()
    if($NonCode -contains $e){ continue }
    if($ExtLang.ContainsKey($e)){ $l=$ExtLang[$e]; if($counts.ContainsKey($l)){$counts[$l]++}else{$counts[$l]=1} }
  }
  if($counts.Count -eq 0){ return @{ lang=""; n=0 } }
  $top = $counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
  $n = ($counts.Values | Measure-Object -Sum).Sum
  return @{ lang=$top.Key; n=$n }
}

# --- git hotspot -------------------------------------------------------------------
$FixGrep = @("--grep=fix","--grep=bug","--grep=hotfix","--grep=regression","--grep=patch")
function Git-Stats($repo){
  $n = (git -C $repo rev-list --count HEAD 2>$null)
  $nc = 0; if($n){ [int]::TryParse($n.Trim(), [ref]$nc) | Out-Null }
  $fixLines = git -C $repo log -i @FixGrep --oneline 2>$null
  $fc = 0; if($fixLines){ $fc = ($fixLines | Measure-Object -Line).Lines }
  $share = 0.0; if($nc -gt 0){ $share = [math]::Round($fc/$nc,4) }
  return @{ n_commits=$nc; fix_share=$share }
}
function Git-Hotspots($repo){
  $churn=@{}; $fix=@{}
  (git -C $repo log --format= --name-only 2>$null) | Where-Object {$_ -ne ""} | ForEach-Object {
    if($churn.ContainsKey($_)){$churn[$_]++}else{$churn[$_]=1} }
  (git -C $repo log -i @FixGrep --format= --name-only 2>$null) | Where-Object {$_ -ne ""} | ForEach-Object {
    if($fix.ContainsKey($_)){$fix[$_]++}else{$fix[$_]=1} }
  $rows = foreach($k in $churn.Keys){
    $ft = 0; if($fix.ContainsKey($k)){$ft=$fix[$k]}
    [pscustomobject]@{ file=$k; churn=$churn[$k]; fix_touches=$ft }
  }
  return @($rows | Sort-Object fix_touches,churn -Descending | Select-Object -First 15)
}

# --- linters -----------------------------------------------------------------------
function Run-PSSA($repo){
  $out=@()
  try{
    $res = Invoke-ScriptAnalyzer -Path $repo -Recurse -ErrorAction SilentlyContinue
    foreach($r in $res){
      $sev = switch("$($r.Severity)"){ "Error"{"error"} "Warning"{"warning"} default{"info"} }
      $rel = $r.ScriptPath; if($rel){ $rel = $rel.Replace($repo,"").TrimStart("\","/") }
      $out += @{ file=$rel; line=[int]$r.Line; tool="PSScriptAnalyzer";
                 rule="$($r.RuleName)"; severity=$sev; message="$($r.Message)" }
    }
  }catch{ Log "PSSA failed on $repo : $_" }
  return $out
}
function Run-Ruff($repo){
  $out=@()
  $ruff = (Get-Command ruff -ErrorAction SilentlyContinue).Source
  if(-not $ruff){ return $out }
  try{
    $json = & $ruff check --output-format=json --exit-zero --no-cache $repo 2>$null
    if($json){ ($json | ConvertFrom-Json) | ForEach-Object {
      $rel=$_.filename; if($rel){ $rel=$rel.Replace($repo,"").TrimStart("\","/") }
      $out += @{ file=$rel; line=[int]$_.location.row; tool="ruff";
                 rule="$($_.code)"; severity="warning"; message="$($_.message)" } } }
  }catch{ Log "ruff failed on $repo : $_" }
  return $out
}
function Run-Detekt($repo){
  $out=@()
  $jar = Join-Path $Root "bin\detekt-cli.jar"
  if(-not (Test-Path $jar)){ return $out }
  if(-not (Get-Command java -ErrorAction SilentlyContinue)){ return $out }
  $sarif = Join-Path $env:TEMP ("detekt-{0}.sarif" -f ([guid]::NewGuid().ToString("N")))
  try{
    & java -jar $jar --input $repo --report ("sarif:{0}" -f $sarif) 2>$null | Out-Null
    if(Test-Path $sarif){
      $s = Get-Content $sarif -Raw | ConvertFrom-Json
      foreach($run in $s.runs){ foreach($r in $run.results){
        $pl = $r.locations[0].physicalLocation
        $file = "$($pl.artifactLocation.uri)"
        if($file){ $file = ($file -replace '^file:/*','') -replace [regex]::Escape($repo.Replace('\','/')),'' }
        $sev = switch("$($r.level)"){ "error"{"error"} "warning"{"warning"} default{"info"} }
        $out += @{ file=$file.TrimStart('/'); line=[int]$pl.region.startLine; tool="detekt";
                   rule="$($r.ruleId)"; severity=$sev; message="$($r.message.text)" }
      }}
    }
  }catch{ Log "detekt failed on $repo : $_" }
  finally{ Remove-Item $sarif -ErrorAction SilentlyContinue }
  return $out
}
function Count-Loc($files,$lang){
  $exts = @{ python=@(".py"); powershell=@(".ps1",".psm1"); shell=@(".sh");
            javascript=@(".js"); kotlin=@(".kt",".kts") }[$lang]
  if(-not $exts){ return 0 }
  $total=0
  foreach($f in $files){ if($exts -contains $f.Extension.ToLower()){
    try{ $total += (Get-Content $f.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines }catch{} } }
  return $total
}

# --- standard checklist ------------------------------------------------------------
function Grep-Any($files,$pattern){
  foreach($f in $files){
    if($f.Length -gt 400000){ continue }
    try{ if(Select-String -Path $f.FullName -Pattern $pattern -Quiet -ErrorAction SilentlyContinue){ return $true } }catch{}
  }
  return $false
}
function Std-Checks($repo,$files){
  $names = $files | ForEach-Object { $_.Name.ToLower() }
  $rel   = $files | ForEach-Object { $_.FullName.Substring($repo.Length).ToLower() }
  return @{
    git     = (Test-Path (Join-Path $repo ".git"))
    sentry  = (Grep-Any $files 'sentry_sdk|init_sentry|Sentry')
    logging = (Grep-Any $files 'RotatingFileHandler|Start-Transcript|Write-Log|logging\.getLogger')
    config  = (($names -contains "config.json") -or (Grep-Any $files 'config-store|CONFIG_STORE|config\.json'))
    tests   = [bool](($rel | Where-Object { $_ -match 'test' }) )
    readme  = [bool](($names | Where-Object { $_ -like "readme*" }))
    deploy  = [bool](($names | Where-Object { $_ -match '\.service$|^deploy\.|dockerfile|install\.ps1|\.nginx$' }))
    ci      = (Test-Path (Join-Path $repo ".github\workflows"))
  }
}

# --- collect repos -----------------------------------------------------------------
$repoDirs = @()
if(Test-Path $ToolsRoot){ $repoDirs += (Get-ChildItem $ToolsRoot -Directory | ForEach-Object { $_.FullName }) }
foreach($e in $ExtraRepos){ if(Test-Path $e){ $repoDirs += $e } }

$inventory=@(); $projects=@()
foreach($repo in $repoDirs){
  $name = (Split-Path $repo -Leaf).ToLower()
  Log "scanning $name"
  $files = @(Get-CodeFiles $repo)
  $lg = Detect-Language $files
  $hasGit = Test-Path (Join-Path $repo ".git")
  $remote = ""; if($hasGit){ $remote = (git -C $repo remote get-url origin 2>$null); if(-not $remote){$remote=""} }

  $inventory += @{ name=$name; path=$repo; remote="$remote"; language=$lg.lang;
                   n_code_files=$lg.n; has_git=[bool]$hasGit; is_vendor=$false }

  $findings=@(); $linted=$false
  if($lg.lang -eq "powershell"){ $findings += Run-PSSA $repo; $linted=$true }
  elseif($lg.lang -eq "python"){ $findings += Run-Ruff $repo; $linted=$true }
  elseif($lg.lang -eq "kotlin"){ $findings += Run-Detekt $repo; $linted=$true }
  # PowerShell scripts inside a non-PS repo still get analyzed
  if($lg.lang -ne "powershell" -and ($files | Where-Object {$_.Extension -eq ".ps1"})){ $findings += Run-PSSA $repo }

  $git=@{ n_commits=0; fix_share=0.0 }; $hot=@()
  if($hasGit){ $git = Git-Stats $repo; $hot = Git-Hotspots $repo }

  $projects += @{ name=$name; language=$lg.lang; loc=(Count-Loc $files $lg.lang);
                  findings=@($findings); hotspots=@($hot); checks=(Std-Checks $repo $files);
                  git=$git; linted=$linted }
}

# --- push --------------------------------------------------------------------------
if(-not (Test-Path $TokenFile)){ Log "FATAL: token file missing: $TokenFile"; exit 1 }
$token = (Get-Content $TokenFile -Raw).Trim()
$payload = @{ host=$env:COMPUTERNAME; inventory=@($inventory); projects=@($projects) }
$body = $payload | ConvertTo-Json -Depth 8
Log ("posting {0} inventory / {1} projects ({2} bytes)" -f $inventory.Count, $projects.Count, $body.Length)
try{
  $resp = Invoke-RestMethod -Uri $Endpoint -Method Post -ContentType "application/json" `
            -Headers @{ Authorization = "Bearer $token" } -Body $body -TimeoutSec 30
  Log ("ingest OK: {0}" -f ($resp | ConvertTo-Json -Compress))
}catch{
  Log "ingest FAILED: $($_.Exception.Message)"; exit 1
}
