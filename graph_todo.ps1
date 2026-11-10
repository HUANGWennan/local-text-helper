param(
    [ValidateSet('create','connect')][string]$Operation='create',
    [string]$Tenant='consumers'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$WarningPreference='SilentlyContinue'
$PSStyle.OutputRendering='PlainText'
$root=Join-Path $HOME 'Library/Application Support/LocalTextHelperPublic'
$configPath=Join-Path $root 'todo-connection.json'
$ledgerPath=Join-Path $root 'todo-write-state.json'
$graph='https://graph.microsoft.com/v1.0/'
$confirmed=[Collections.Generic.List[string]]::new()

function Request-Graph([string]$method,[string]$uri,$body=$null) {
    if (-not $uri.StartsWith($graph, [StringComparison]::Ordinal)) {throw '任务接口地址无效。'}
    if ($null -eq $body) {return Invoke-MgGraphRequest -Method $method -Uri $uri}
    return Invoke-MgGraphRequest -Method $method -Uri $uri -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 8 -Compress)
}

function Read-Pages([string]$uri) {
    while ($uri) {
        $page=Request-Graph GET $uri
        $page.value
        $uri=$page.'@odata.nextLink'
    }
}

function Save-Json([string]$path,$data) {
    $temp=$path+'.tmp'
    [IO.File]::WriteAllText($temp,($data | ConvertTo-Json -Depth 8 -Compress))
    [IO.File]::Move($temp,$path,$true)
}

function Canonical([string]$title) {
    return [regex]::Replace($title.Normalize([Text.NormalizationForm]::FormKC),'\s+',' ').Trim()
}

function Due-Day($task) {
    if (-not $task.dueDateTime) {return ''}
    $stamp=$task.dueDateTime.dateTime
    if ($stamp -is [DateTime] -or $stamp -is [DateTimeOffset]) {return $stamp.ToString('yyyy-MM-dd')}
    $value=[string]$stamp
    if ($value -match '^\d{4}-\d{2}-\d{2}(?:T|$)') {return $value.Substring(0,10)}
    throw 'Microsoft Graph 返回了无法确认的截止日期。'
}

try {
    Import-Module Microsoft.Graph.Authentication
    if ($Operation -eq 'connect') {
        Connect-MgGraph -TenantId $Tenant -Scopes Tasks.ReadWrite -UseDeviceAuthentication -ContextScope CurrentUser -NoWelcome
        $context=Get-MgContext
        $defaultList=@(Read-Pages ($graph+'me/todo/lists') | Where-Object {$_.wellknownListName -eq 'defaultList'})
        if ($defaultList.Count -ne 1 -or -not $context.Account) {throw '未能确认当前账号的默认 Tasks 列表。'}
        [void][IO.Directory]::CreateDirectory($root)
        & /bin/chmod 700 $root
        if ($LASTEXITCODE -ne 0) {throw '无法保护本机连接配置。'}
        Save-Json $configPath @{tenant=$Tenant;account=$context.Account;list_id=$defaultList[0].id}
        Write-Output '已连接 Microsoft To Do 默认 Tasks 列表。'
        exit 0
    }

    $data=[Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    if (-not $data.events -or $data.events.Count -gt 8) {throw '待办数据无效。'}
    $config=Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json -AsHashtable
    # The setup command already obtained delegated consent and seeded the SDK cache.
    Connect-MgGraph -TenantId $config.tenant -Scopes Tasks.ReadWrite -ContextScope CurrentUser -NoWelcome
    $context=Get-MgContext
    if ($context.Account -ine $config.account) {throw '当前 Microsoft 账号与连接时不同，请重新连接。'}
    Set-MgRequestContext -MaxRetry 0 -ClientTimeout 30 | Out-Null
    $base=$graph+'me/todo/lists/'+[Uri]::EscapeDataString($config.list_id)+'/tasks'
    $ledger=@{}
    if (Test-Path -LiteralPath $ledgerPath) {
        $ledger=Get-Content -Raw -LiteralPath $ledgerPath | ConvertFrom-Json -AsHashtable
    }
    $results=[Collections.Generic.List[object]]::new()
    foreach ($event in $data.events) {
        $title=[string]$event.title
        $due=[string]$event.due_date
        $canonical=Canonical $title
        if (-not $canonical -or $title.Length -gt 255) {throw '任务标题无效。'}
        if ($due) {[void][DateTime]::ParseExact($due,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)}
        $keyText=$config.list_id+[char]0+$canonical
        $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyText)))
        $existing=@(Read-Pages ($base+'?$top=100') | Where-Object {$_.status -ne 'completed' -and (Canonical $_.title) -ceq $canonical})
        if ($existing.Count -gt 1) {throw '发现多个同名任务，请先核对。'}
        if ($existing.Count -eq 1) {
            if ((Due-Day $existing[0]) -ne $due) {throw '已有同名任务的截止日期不同，请先核对。'}
            if ($ledger.Contains($key)) {
                $ledger.Remove($key)
                Save-Json $ledgerPath $ledger
            }
            $message='已存在：'+$title
        } else {
            if ($ledger.Contains($key)) {throw '上次提交结果仍不确定，请先在 To Do 核对。'}
            $body=@{title=$title}
            if ($due) {$body.dueDateTime=@{dateTime=$due+'T00:00:00';timeZone='UTC'}}
            # Retain a marker across crashes/timeouts so the same task is never blindly POSTed again.
            $ledger[$key]=$true
            Save-Json $ledgerPath $ledger
            $created=Request-Graph POST $base $body
            if (-not $created.id) {throw '提交后未能确认任务。'}
            $check=Request-Graph GET ($base+'/'+[Uri]::EscapeDataString($created.id))
            if ((Canonical $check.title) -cne $canonical -or (Due-Day $check) -ne $due) {
                throw '任务已提交，但标题或日期尚未核验。'
            }
            $ledger.Remove($key)
            Save-Json $ledgerPath $ledger
            $message='已加入：'+$title
        }
        $confirmed.Add($message)
        $results.Add(@{title=$title;due_date=$due;message=$message;verified=$true})
    }
    @{results=$results.ToArray();text=($confirmed -join [Environment]::NewLine)} | ConvertTo-Json -Depth 5 -Compress
} catch {
    if ($Operation -eq 'connect') {
        Write-Error 'Microsoft To Do 未连接。请检查登录是否完成，以及账号或组织是否允许 Tasks.ReadWrite。'
    } else {
        $message=$_.Exception.Message
        # SDK errors may contain account IDs or HTTP details. Display a generic fallback.
        if ($message -notmatch '^(任务|提交|已有|当前|发现|上次|待办|Microsoft Graph)') {
            $message='Microsoft To Do 未返回确认。请核对账号连接和已有任务。'
        }
        if ($confirmed.Count) {$message=($confirmed -join [Environment]::NewLine)+[Environment]::NewLine+$message}
        @{error=$message} | ConvertTo-Json -Compress
    }
    exit 1
}
