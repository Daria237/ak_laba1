#!/bin/bash

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

SCRIPT=$(dirname "$(readlink -f "$0")")/ourlaba.sh
DIR=${DIR:-/mnt/xfsdisk/test}
BK=/tmp/test_backup

mkdir -p "$DIR" "$BK"; rm -f "$DIR"/* "$BK"/*

# 10 файлов по 1 МБ, f_1 самый старый, f_10 самый новый
for i in 1 2 3 4 5 6 7 8 9 10; do
    head -c 1048576 /dev/zero > "$DIR/f_$i.log"
    touch -d "$((11 - i)) days ago" "$DIR/f_$i.log"
done

PASS=0; FAIL=0
check() {
    if eval "$2"; then echo "PASS: $1"; PASS=$((PASS + 1))
    else echo "FAIL: $1"; FAIL=$((FAIL + 1)); fi
}

# 1. неверный параметр
check "N=101 - ошибка" '! "$SCRIPT" "$DIR" 101 3 20M "*" "$BK" >/dev/null 2>&1'

# 2. занято 50%, порог 60% - ничего не делаем
"$SCRIPT" "$DIR" 60 3 20M "*" "$BK"
check "порог не превышен - архива нет" '[[ -z $(ls "$BK") ]]'

# 3. порог 40% превышен - архивируем 3 самых старых
"$SCRIPT" "$DIR" 40 3 20M "*" "$BK"
check "в архиве 3 самых старых файла" '[[ $(tar -tzf "$BK"/*.tar.gz | sort | tr "\n" " ") == "f_1.log f_2.log f_3.log " ]]'

# 4. оригиналы удалены, остальные на месте
check "старые удалены, новые целы" '[[ ! -e $DIR/f_3.log && -e $DIR/f_4.log ]]'

# 5. квота XFS создана (20 МБ = 20480 КБ)
check "квота XFS 20M создана" 'xfs_quota -x -c "report -p -b -N" "$(findmnt -n -o TARGET -T "$DIR")" | grep -q 20480'

echo; echo "=== Результат ==="
echo "Пройдено: $PASS"
echo "Провалено: $FAIL"
[[ $FAIL -eq 0 ]]
