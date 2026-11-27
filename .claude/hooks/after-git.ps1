# PostToolUse(Bash|PowerShell) 훅: git commit / master push 직후 test-runner 에이전트 호출을 메인 에이전트에게 알린다.
# 훅은 에이전트를 직접 띄울 수 없으므로 additionalContext 로 지시를 주입한다.
# Node 없이 Windows 기본 PowerShell 5.1 에서 돈다. 한글이 있으므로 이 파일은 UTF-8 BOM 으로 저장해야 한다.
$ErrorActionPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# 진단 로그: 훅이 실행됐는지, 무엇을 출력했는지 남긴다(.gitignore 대상). 64KB 넘으면 새로 시작.
$LogPath = Join-Path $PSScriptRoot 'after-git.log'
function Write-HookLog([string]$line) {
  try {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 64KB) { Remove-Item $LogPath -Force }
    [IO.File]::AppendAllText($LogPath, "$((Get-Date).ToUniversalTime().ToString('o')) $line`n", [Text.UTF8Encoding]::new($false))
  } catch {}
}

$repo = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
function Invoke-HookGit([string[]]$gitArgs) {
  try { ((& git -C $repo @gitArgs 2>$null) -join "`n").Trim() } catch { '' }
}

$raw = [Console]::In.ReadToEnd()
try {
  $hookInput = $raw | ConvertFrom-Json
  $cmd = [string]$hookInput.tool_input.command
  $tool = if ($hookInput.tool_name) { [string]$hookInput.tool_name } else { '?' }
} catch {
  Write-HookLog "stdin 파싱 실패: $($_.Exception.Message) ($($raw.Length)자)"
  exit 0
}
$firstLine = ($cmd -split "`r?`n")[0]
$brief = $firstLine.Substring(0, [Math]::Min(100, $firstLine.Length))

# 명령의 시작이나 ; && || | ( 뒤에 오는 git 만 본다(문자열 안의 "git push" 오탐 방지).
$GIT = '(?m)(?:^|[;&|(])\s*git(?:\s+-[cC]\s+\S+)*\s+'
$isCommit = ($cmd -match ($GIT + 'commit\b')) -and ($cmd -notmatch '--dry-run')
$pushMatch = [regex]::Match($cmd, $GIT + 'push\b([^;&|]*)')
$pushRest = if ($pushMatch.Success) { $pushMatch.Groups[1].Value } else { '' }
$isPush = $pushMatch.Success -and ($pushRest -notmatch '--dry-run|\s-n\b')
if (-not $isCommit -and -not $isPush) {
  if ($cmd -match '\bgit\b') { Write-HookLog "[$tool] 해당 없음: $brief" }
  exit 0
}

# 명령 안에서 cd 로 다른 저장소에 들어가거나 git -C <경로>로 다른 저장소를 가리킨 경우는
# 이 프로젝트 일이 아니므로 건너뛴다. 경로를 확인하지 못해도 이 프로젝트로 단정하지 않는다.
function Resolve-HookTarget([string]$raw) {
  $t = $raw.Trim('"', "'")
  # 같은 명령 안의 NAME=값 대입을 찾아 $NAME / ${NAME} 을 펼친다(예: R=/c/...; cd "$R").
  foreach ($m in [regex]::Matches($cmd, '(?m)(?:^|[;&|(\s])([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|''[^'']*''|[^\s;&|]+)')) {
    $name = $m.Groups[1].Value; $val = $m.Groups[2].Value.Trim('"', "'")
    $t = $t.Replace('${' + $name + '}', $val).Replace('$' + $name, $val)
  }
  $t = $t.Replace('$HOME', $HOME).Replace('${HOME}', $HOME)
  if ($t -match '^~(.*)$') { $t = $HOME + $Matches[1] }
  if ($t -match '^/([a-zA-Z])/(.*)$') { $t = "$($Matches[1]):/$($Matches[2])" }
  # 상대 경로(cd .., cd Soso)는 훅의 작업 폴더가 아니라 명령이 실행된 폴더(cwd) 기준으로 푼다.
  if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path $shellCwd $t }
  $top = try { ((& git -C $t rev-parse --show-toplevel 2>$null) -join '').Trim() } catch { '' }
  return @($t, $top)
}
# 명령이 실행된 폴더. 훅 입력의 cwd가 없으면 프로젝트 폴더로 본다.
$shellCwd = if ($hookInput.cwd) { [string]$hookInput.cwd } else { $repo }
if ($shellCwd -match '^/([a-zA-Z])/(.*)$') { $shellCwd = "$($Matches[1]):/$($Matches[2])" }
$targets = @()
$cdMatches = [regex]::Matches($cmd, '(?m)(?:^|[;&|(])\s*(?:cd|Set-Location)\s+("[^"]+"|''[^'']+''|[^\s;&|]+)')
if ($cdMatches.Count -gt 0) { $targets += $cdMatches[$cdMatches.Count - 1].Groups[1].Value }
foreach ($m in [regex]::Matches($cmd, '\bgit\s+-C\s+("[^"]+"|''[^'']+''|[^\s;&|]+)')) { $targets += $m.Groups[1].Value }
# cd도 -C도 없으면 명령이 실행된 폴더 자체가 대상이다(쉘이 이미 다른 저장소에 있을 수 있음).
if ($targets.Count -eq 0) { $targets += '.' }
if ($targets.Count -gt 0) {
  $projectTop = Invoke-HookGit @('rev-parse', '--show-toplevel')
  foreach ($raw in $targets) {
    $resolved = Resolve-HookTarget $raw
    if ($projectTop -and ($resolved[1] -ne $projectTop)) {
      $where = if ($resolved[1]) { $resolved[1] } else { "확인 불가: $($resolved[0])" }
      Write-HookLog "[$tool] 다른 저장소($where): $brief"
      exit 0
    }
  }
}

$branch = Invoke-HookGit @('rev-parse', '--abbrev-ref', 'HEAD')
$head = Invoke-HookGit @('rev-parse', '--short', 'HEAD')
$messages = @()

if ($isCommit) {
  $files = @((Invoke-HookGit @('diff', '--name-only', 'HEAD~1..HEAD')) -split "`n" | Where-Object { $_ })
  $docsOnly = $files.Count -gt 0 -and -not ($files | Where-Object { $_ -notmatch '\.md$|^docs/|^\.claude/|^scripts/|^\.git(ignore|attributes)$' })
  if ($docsOnly) {
    $messages += "[test-runner 훅] 커밋 $head($branch)은 문서/에이전트 설정만 바뀌어 local 테스트를 생략한다."
  } else {
    $shown = ($files | Select-Object -First 15) -join ', '
    $more = if ($files.Count -gt 15) { ' ...' } else { '' }
    $messages += "[test-runner 훅] 커밋 $head($branch)이 생성됐다. 다음 작업 전에 Agent 도구로 subagent_type `"test-runner`"를 호출한다. " +
      "프롬프트: `"local 모드, 범위 HEAD~1..HEAD`". 변경 파일 $($files.Count)개: $shown$more"
  }
}

# 위치 인자: [remote, refspec...]. refspec 이 있으면 그 목적지로, 없으면 현재 브랜치로 판단한다.
$pushedMaster = $false
if ($isPush -and $pushRest -notmatch '--delete|\s-d\b') {
  $pushArgs = @($pushRest.Trim() -split '\s+' | Where-Object { $_ -and -not $_.StartsWith('-') })
  $refspecs = @($pushArgs | Select-Object -Skip 1)
  if ($refspecs.Count -gt 0) {
    $pushedMaster = [bool]($refspecs | Where-Object { $_ -match '^\+?(?:[^:]*:)?(?:refs/heads/)?master$' -or ($_ -eq 'HEAD' -and $branch -eq 'master') })
  } else {
    $pushedMaster = $branch -eq 'master'
  }
}
if ($pushedMaster) {
  $messages += "[test-runner 훅] master 가 push 됐다($head). 운영 배포가 시작된다. Agent 도구로 subagent_type `"test-runner`"를 호출한다. " +
    "프롬프트: `"deploy 모드, 대상 커밋 $head`". 앱 코드 변경 없이 문서/설정만 push 했다면 에이전트 대신 ``bash scripts/smoke.sh --quick`` 만 실행해도 된다."
}

$joined = if ($messages.Count) { $messages -join ' | ' } else { '(출력 없음)' }
Write-HookLog "[$tool] commit=$isCommit push=$isPush master=${pushedMaster}: $brief`n    -> $joined"
if ($messages.Count -eq 0) { exit 0 }
$out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = ($messages -join "`n") } } | ConvertTo-Json -Compress -Depth 4
[Console]::Out.Write($out)
exit 0
