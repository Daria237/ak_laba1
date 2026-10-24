$Lab = Join-Path $PSScriptRoot 'ourlaba.ps1'
$Root = Join-Path $env:TEMP 'lab1_test'
$Dir = Join-Path $Root 'log'        # тестовая папка с логами
$Bk = Join-Path $Root 'backup'     # сюда попадёт архив

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Dir, $Bk | Out-Null

# 10 файлов по 1 МиБ, f_1 самый старый, f_10 самый новый
foreach ($i in 1..10) {
    $f = Join-Path $Dir "f_$i.log"
    [IO.File]::WriteAllBytes($f, (New-Object byte[] 1048576))
    (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddDays($i - 11)
}

$script:$Pass = 0; $Fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS: $name"; $script:Pass++ }
    else { Write-Host "FAIL: $name"; $script:Fail++ }
}

function Run {
    $script:Out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $Lab @args 2>&1 | Out-String)
    $script:RC = $LASTEXITCODE
}

# 1. неверный параметр
Run $Dir 101 3 20MB '*' $Bk
Check 'N=101 - ошибка' ($RC -ne 0)

# 2. занято 50%, порог 60% - ничего не делаем
Run $Dir 60 3 20MB '*' $Bk
Write-Host $Out
Check 'порог не превышен - архива нет' ($RC -eq 0 -and -not (Get-ChildItem -LiteralPath $Bk))

# 3. размер выводится в процентах
Check 'размер выводится в % (~50%)' ($Out -match '=\s*5\d\.\d+%')

# 4. порог 40% превышен - архивируем 3 самых старых
Run $Dir 40 3 20MB '*' $Bk
Write-Host $Out
$arc = (Get-ChildItem -LiteralPath $Bk -Filter '*.tar.gz' | Select-Object -First 1).FullName
$names = ((& tar.exe -tzf $arc) | Sort-Object) -join ' '
Check 'в архиве 3 самых старых файла' ($names -eq 'f_1.log f_2.log f_3.log')

# 5. оригиналы удалены, остальные на месте
Check 'старые удалены, новые целы' (-not (Test-Path (Join-Path $Dir 'f_3.log')) -and (Test-Path (Join-Path $Dir 'f_4.log')))

Write-Host ''
Write-Host '=== Результат ==='
Write-Host "Пройдено: $Pass"
Write-Host "Провалено: $Fail"
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
exit ([int]($Fail -ne 0))
