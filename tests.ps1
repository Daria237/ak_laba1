$LabScript = Join-Path $PSScriptRoot 'ourlaba.ps1'
if (-not (Test-Path -LiteralPath $LabScript)) { Write-Host "Не найден $LabScript"; exit 1 }

$PsExe = (Get-Process -Id $PID).Path
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('lab1_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
$script:Pass = 0; $script:Fail = 0; $script:n = 0

function Ok([string]$d) { Write-Host "PASS: $d"; $script:Pass++ }
function Bad([string]$d) { Write-Host "FAIL: $d (rc=$($script:RC); $($script:Out))"; $script:Fail++ }
function T([string]$d, [bool]$cond) { if ($cond) { Ok $d } else { Bad $d } }   # T "описание" (условие)

# Run <аргументы...>: запускает ourlaba.ps1 отдельным процессом, запоминает вывод и код возврата
function Run {
    $script:Out = (& $PsExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $LabScript @args 2>&1 | Out-String)
    $script:RC = $LASTEXITCODE
}
function NewDir { $script:n++; $script:D = Join-Path $Tmp "t$($script:n)"; New-Item -ItemType Directory -Path $script:D | Out-Null }
function NewBk { $script:n++; $script:BK = Join-Path $Tmp "b$($script:n)"; New-Item -ItemType Directory -Path $script:BK | Out-Null }
function Arc([string]$bk) { @(Get-ChildItem -LiteralPath $bk -Filter '*.tar.gz') }
function FirstArc([string]$bk) { (Get-ChildItem -LiteralPath $bk -Filter '*.tar.gz' | Select-Object -First 1).FullName }
function Names([string]$a) { ((& tar.exe -tzf $a) | Sort-Object) -join '|' }
function Count([string]$dir) { @(Get-ChildItem -LiteralPath $dir -File).Count }

# MkFile <путь> <секунд назад>: файл 1 МиБ с заданным временем изменения
function MkFile([string]$path, [int]$secAgo) {
    [IO.File]::WriteAllBytes($path, (New-Object byte[] 1048576))
    (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddSeconds(-$secAgo)
}
# MkFiles <папка> <кол-во> [расширение]: f_1..f_n, f_1 самый старый
function MkFiles([string]$dir, [int]$count, [string]$ext = 'log') {
    for ($i = 1; $i -le $count; $i++) { MkFile (Join-Path $dir "f_$i.$ext") (10000 - $i * 10) }
}

try {
    Write-Host '=== Тесты ourlaba.ps1 ==='

    # 1-4. входные данные
    NewDir; NewBk
    Run;                                         T 'без аргументов - ошибка'       ($script:RC -ne 0)
    Run 'C:\no\such\dir' 50 3 10MB '*' $BK;      T 'несуществующая папка - ошибка' ($script:RC -ne 0)
    foreach ($v in '0', '101', 'abc') { Run $D $v 3 10MB '*' $BK; T "N='$v' - ошибка" ($script:RC -ne 0) }
    foreach ($v in '0', 'abc') { Run $D 50 $v 10MB '*' $BK; T "M='$v' - ошибка" ($script:RC -ne 0) }
    Run $D 50 3 'abc' '*' $BK;                   T 'некорректная квота - ошибка'   ($script:RC -ne 0)
    Run $D 50 3;                                 T 'квота не задана - ошибка'      ($script:RC -ne 0)

    # 5. размер в процентах
    NewDir; NewBk; MkFiles $D 10                  # 10 МиБ из 20 МиБ
    Run $D 90 3 20MB '*' $BK
    T 'размер выводится в % (~50%)' ($script:RC -eq 0 -and $script:Out -match '=\s*5\d\.\d+%')

    # 6. ниже порога
    Run $D 60 3 20MB '*' $BK
    T 'ниже порога: архива нет, файлы на месте' ($script:RC -eq 0 -and (Arc $BK).Count -eq 0 -and (Count $D) -eq 10)

    # 7. выше порога: M самых старых
    Run $D 40 3 20MB '*' $BK; $A = FirstArc $BK
    T 'выше порога: создан один архив tar.gz' ($script:RC -eq 0 -and (Arc $BK).Count -eq 1)
    T 'в архиве 3 самых старых файла' ((Names $A) -eq 'f_1.log|f_2.log|f_3.log')
    T 'они удалены из папки, остальные целы' (-not (Test-Path (Join-Path $D 'f_3.log')) -and (Test-Path (Join-Path $D 'f_4.log')) -and (Count $D) -eq 7)
    $x = Join-Path $Tmp 'x'; New-Item -ItemType Directory -Path $x | Out-Null
    & tar.exe -xzf $A -C $x
    T 'содержимое в архиве не повреждено' ((Get-Item (Join-Path $x 'f_1.log')).Length -eq 1048576)

    # 8. M больше числа файлов
    NewDir; NewBk; MkFiles $D 4
    Run $D 50 100 5MB '*' $BK
    T 'M > числа файлов: архивируются все' ($script:RC -eq 0 -and (@(& tar.exe -tzf (FirstArc $BK))).Count -eq 4 -and (Count $D) -eq 0)

    # 9. фильтр по маске
    NewDir; NewBk; MkFiles $D 3 'log'; MkFiles $D 3 'txt'
    foreach ($i in 1, 2, 3) { (Get-Item (Join-Path $D "f_$i.txt")).LastWriteTime = (Get-Date).AddSeconds(-20000 + $i) }   # .txt старее
    Run $D 50 10 10MB '*.log' $BK
    $names = Names (FirstArc $BK)
    T 'маска *.log: в архиве только .log, .txt не тронуты' ($names -eq 'f_1.log|f_2.log|f_3.log' -and @(Get-ChildItem $D -Filter '*.txt').Count -eq 3)

    # 10. пробелы в именах
    NewDir; NewBk
    foreach ($i in 1..4) { MkFile (Join-Path $D "my log $i.log") (5000 - $i) }
    Run $D 50 2 5MB '*' $BK
    T 'имена с пробелами обрабатываются' ((Names (FirstArc $BK)) -eq 'my log 1.log|my log 2.log' -and -not (Test-Path -LiteralPath (Join-Path $D 'my log 1.log')))
}
finally {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=== Результат ==='
Write-Host "Пройдено: $($script:Pass)"
Write-Host "Провалено: $($script:Fail)"
exit ([int]($script:Fail -ne 0))
