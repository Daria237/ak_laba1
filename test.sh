#!/bin/bash

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

SCRIPT="$(cd "$(dirname "$0")" && pwd)/ourlaba.sh"
[[ -f $SCRIPT ]] || { echo "Не найден $SCRIPT"; exit 1; }

TMP=$(mktemp -d); MNT=$TMP/mnt; XFS=false; PASS=0; FAIL=0; SKIP=0
cleanup() {
    if $XFS; then
        sed -i "\|^[0-9]*:$MNT/|d" /etc/projects 2>/dev/null
        sed -i '/^proj_[0-9]*:/d' /etc/projid 2>/dev/null
        umount "$MNT" 2>/dev/null
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

if command -v mkfs.xfs >/dev/null && command -v xfs_quota >/dev/null; then
    truncate -s 300M "$TMP/disk.img"; mkdir -p "$MNT"
    mkfs.xfs -q "$TMP/disk.img" 2>/dev/null && mount -o loop,prjquota "$TMP/disk.img" "$MNT" 2>/dev/null && XFS=true
fi
if $XFS; then FS=$MNT; echo "=== Тесты: виртуальный XFS-диск с prjquota ==="
else FS=$TMP/plain; mkdir -p "$FS"; echo "=== Тесты: XFS недоступен, режим ручного порога ==="; fi

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1 ${2:+($2)}"; FAIL=$((FAIL + 1)); }
t()   { if eval "$2"; then ok "$1"; else bad "$1" "rc=$RC; $OUT"; fi; }   # t "описание" "условие"

mkfiles() {
    local i base=$(( $(date +%s) - 10000 ))
    for ((i = 1; i <= $2; i++)); do
        head -c 1048576 /dev/zero > "$1/f_$i.${3:-log}"; touch -d "@$((base + i * 10))" "$1/f_$i.${3:-log}"
    done
}
n=0; newdir() { n=$((n + 1)); D=$FS/t$n; mkdir -p "$D"; }
newbk()  { mktemp -d -p "$TMP"; }
narch()  { find "$1" -name '*.tar.gz' | wc -l; }
arch()   { find "$1" -name '*.tar.gz' | head -n1; }
run()    { OUT=$("$SCRIPT" "$@" </dev/null 2>&1); RC=$?; }

# 1-4. входные данные
newdir; BK=$(newbk)
run;                                  t "без аргументов - ошибка"          '[[ $RC -ne 0 ]]'
run /no/such 50 3 10M "*" "$BK";      t "несуществующая папка - ошибка"    '[[ $RC -ne 0 && $OUT == *"не существует"* ]]'
for v in 0 101 abc; do run "$D" $v 3 10M "*" "$BK"; t "N='$v' - ошибка" '[[ $RC -ne 0 ]]'; done
for v in 0 abc;     do run "$D" 50 $v 10M "*" "$BK"; t "M='$v' - ошибка" '[[ $RC -ne 0 ]]'; done

# 5. размер в процентах
newdir; BK=$(newbk); mkfiles "$D" 10
run "$D" 90 3 20M "*" "$BK"
t "размер выводится в % (~50%)" '[[ $RC -eq 0 && $OUT =~ Занято:.*=\ 5[0-9]\.[0-9]+% ]]'

# 6. ниже порога
run "$D" 60 3 20M "*" "$BK"
t "ниже порога: архива нет, файлы на месте" '[[ $RC -eq 0 && $(narch "$BK") -eq 0 && $(ls "$D" | wc -l) -eq 10 ]]'

# 7. выше порога: M самых старых
run "$D" 40 3 20M "*" "$BK"; A=$(arch "$BK")
t "выше порога: создан один архив tar.gz"   '[[ $RC -eq 0 && $(narch "$BK") -eq 1 ]]'
t "в архиве 3 самых старых файла"           '[[ $(tar -tzf "$A" | sort | tr "\n" " ") == "f_1.log f_2.log f_3.log " ]]'
t "они удалены из папки, остальные целы"    '[[ ! -e $D/f_3.log && -e $D/f_4.log && $(ls "$D" | wc -l) -eq 7 ]]'
mkdir "$TMP/x"; tar -xzf "$A" -C "$TMP/x"
t "содержимое в архиве не повреждено"       '[[ $(stat -c %s "$TMP/x/f_1.log") -eq 1048576 ]]'

# 8. M больше числа файлов
newdir; BK=$(newbk); mkfiles "$D" 4
run "$D" 50 100 5M "*" "$BK"
t "M > числа файлов: архивируются все" '[[ $RC -eq 0 && $(tar -tzf "$(arch "$BK")" | wc -l) -eq 4 && $(ls "$D" | wc -l) -eq 0 ]]'

# 9. фильтр по маске
newdir; BK=$(newbk); mkfiles "$D" 3 log; mkfiles "$D" 3 txt
for i in 1 2 3; do touch -d "@$(( $(date +%s) - 20000 + i ))" "$D/f_$i.txt"; done   # .txt старее
run "$D" 50 10 10M "*.log" "$BK"
t "маска *.log: в архиве только .log, .txt не тронуты" '[[ $(tar -tzf "$(arch "$BK")" | grep -c "\.log$") -eq 3 && $(ls "$D"/*.txt | wc -l) -eq 3 ]]'

# 10. пробелы в именах
newdir; BK=$(newbk); base=$(( $(date +%s) - 5000 ))
for i in 1 2 3 4; do head -c 1048576 /dev/zero > "$D/my log $i.log"; touch -d "@$((base + i))" "$D/my log $i.log"; done
run "$D" 50 2 5M "*" "$BK"
LIST=$(tar -tzf "$(arch "$BK")" | sort | tr '\n' '|')
t "имена с пробелами обрабатываются" '[[ $LIST == "my log 1.log|my log 2.log|" && ! -e "$D/my log 1.log" ]]'

# 11. квота XFS
if $XFS; then
    newdir; BK=$(newbk); mkfiles "$D" 4
    run "$D" 90 2 20M "*" "$BK"
    t "создана квота проекта 20M" 'xfs_quota -x -c "report -p -b -N" "$MNT" | awk "\$4 == 20480 {f = 1} END {exit !f}"'
    run "$D" 90 2 "" "*" "$BK"
    t "повторный запуск использует существующую квоту" '[[ $OUT == *"Квота:   20.00MiB"* ]]'
else
    SKIP=1; echo "SKIP: квота XFS (нет xfsprogs/loop - запустите на ВМ с Ubuntu)"
fi

echo; echo "=== Результат ==="; echo "Пройдено: $PASS"; echo "Провалено: $FAIL"; echo "Пропущено: $SKIP"
[[ $FAIL -eq 0 ]]

