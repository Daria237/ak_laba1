param(
    [string]$Path,
    [string]$N,
    [string]$M,
    [string]$Quota,
    [string]$Mask = '*',
    [string]$Backup = 'C:\backup'
)

$inv = [Globalization.CultureInfo]::InvariantCulture

function Fail([string]$Message) {
    [Console]::Error.WriteLine("Ошибка: $Message")
    exit 1
}

function Format-Size([double]$Bytes) {
    $units = 'Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    '{0} {1}' -f $Bytes.ToString('0.00', $inv), $units[$i]
}

# ---- проверка параметров ----
if (-not $Path -or -not $N -or -not $M -or -not $Quota) {
    Fail 'использование: .\ourlaba.ps1 <папка> <N%> <M> <квота> [маска] [backup]'
}
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "папка '$Path' не существует" }
if ($N -notmatch '^\d{1,3}$' -or [int]$N -lt 1 -or [int]$N -gt 100) { Fail 'N должно быть от 1 до 100' }
if ($M -notmatch '^[1-9]\d{0,8}$') { Fail 'M должно быть положительным числом' }

if ($Quota -match '^(\d+)\s*([KMGT]?)I?B?$') {
    $mult = @{ '' = 1; 'K' = 1KB; 'M' = 1MB; 'G' = 1GB; 'T' = 1TB }
    $limit = [int64]$Matches[1] * $mult[$Matches[2].ToUpper()]
}
else {
    Fail "некорректный размер квоты '$Quota'"
}
if ($limit -le 0) { Fail "некорректный размер квоты '$Quota'" }

$Path = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath).TrimEnd('\')
$Backup = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Backup).TrimEnd('\')

# ---- размер папки (без папки backup, если она внутри) ----
function Get-Files {
    Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.FullName.StartsWith($Backup + '\', [StringComparison]::OrdinalIgnoreCase) }
}
function Get-Used {
    $sum = (Get-Files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { [int64]0 } else { [int64]$sum }
}
function Get-Pct([int64]$Bytes) { ([double]$Bytes * 100 / $limit).ToString('0.00', $inv) }

$used = Get-Used
Write-Output "Папка:   $Path"
Write-Output "Квота:   $(Format-Size $limit)"
Write-Output "Занято:  $(Format-Size $used) = $(Get-Pct $used)% (допустимо до ${N}%)"

if ($used * 100 -le [int64]$N * $limit) {
    Write-Output "Папка занята не более чем на ${N}% - архивация не требуется."
    exit 0
}
Write-Output "Превышено ${N}% - архивирую $M самых старых файлов."

# ---- фильтрация: файлы по маске, M самых старых ----
$files = @(Get-Files | Where-Object { $_.Name -like $Mask } |
        Sort-Object LastWriteTime | Select-Object -First ([int]$M))
if ($files.Count -eq 0) {
    Write-Output "Нет файлов под фильтр (маска '$Mask') - архивировать нечего."
    exit 0
}

# ---- архив tar.gz в backup, исходники удаляем только после проверки архива ----
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Fail 'не найден tar.exe' }
New-Item -ItemType Directory -Force -Path $Backup | Out-Null
$arc = Join-Path $Backup ('log_{0}_{1}.tar.gz' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $PID)

$rel = [string[]]@($files | ForEach-Object { $_.FullName.Substring($Path.Length).TrimStart('\') })
$list = [IO.Path]::GetTempFileName()
[IO.File]::WriteAllLines($list, $rel, (New-Object Text.UTF8Encoding $false))

& tar.exe -czf $arc -C $Path -T $list
$ok = ($LASTEXITCODE -eq 0)
if ($ok) {
    & tar.exe -tzf $arc | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
}
Remove-Item -LiteralPath $list -Force
if (-not $ok) {
    Remove-Item -LiteralPath $arc -Force -ErrorAction SilentlyContinue
    Fail 'не удалось создать архив, файлы не удалены'
}

foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force }

Write-Output "Заархивировано файлов: $($files.Count)"
Write-Output "Архив: $arc"
$used = Get-Used
Write-Output "После архивации: $(Format-Size $used) = $(Get-Pct $used)%"
