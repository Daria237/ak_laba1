#!/bin/bash

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

die() { echo "Ошибка: $*" >&2; exit 1; }
human() { numfmt --to=iec-i --suffix=B --format="%.2f" "$1"; }

DIR=$1 N=$2 M=$3 QUOTA=$4 MASK=${5:-*} BACKUP=${6:-/backup}

# проверка параметров
[[ -n $DIR && -n $N && -n $M ]] || die "использование: $0 <папка> <N%> <M> [квота] [маска] [backup]"
[[ -d $DIR ]] || die "папка '$DIR' не существует"
[[ $N =~ ^[0-9]+$ ]] && ((N >= 1 && N <= 100)) || die "N должно быть от 1 до 100"
[[ $M =~ ^[1-9][0-9]*$ ]] || die "M должно быть положительным числом"
if [[ -n $QUOTA ]]; then
    QB=$(numfmt --from=iec "$QUOTA" 2>/dev/null)
    [[ $QB =~ ^[0-9]+$ ]] && ((QB > 0)) || die "некорректный размер квоты '$QUOTA'"
fi
DIR=$(realpath "$DIR")
BACKUP=$(realpath -m "$BACKUP")

# квота = порог на XFS
FSTYPE=$(findmnt -n -o FSTYPE -T "$DIR")
MNT=$(findmnt -n -o TARGET -T "$DIR")
size_files() { find "$DIR" -type f -not -path "$BACKUP/*" -printf '%s\n' | awk '{s += $1} END {printf "%d", s}'; }

if [[ $FSTYPE == xfs ]]; then
    findmnt -n -o OPTIONS -T "$DIR" | grep -Eq 'prjquota|pquota|pqnoenforce' \
        || die "диск '$MNT' смонтирован без prjquota"
    touch /etc/projects /etc/projid
    ID=$(awk -F: -v p="$DIR" '$2 == p {print $1; exit}' /etc/projects)
    NAME=$(awk -F: -v i="$ID" '$2 == i {print $1; exit}' /etc/projid)
    if [[ -z $NAME ]]; then   # у папки ещё нет проекта - создаём
        [[ -n $QB ]] || die "у папки нет квоты: укажите её размер 4-м параметром"
        if [[ -z $ID ]]; then
            ID=$(cat /etc/projects /etc/projid | awk -F: '{for (i = 1; i <= 2; i++) if ($i ~ /^[0-9]+$/ && $i > m) m = $i} END {print (m < 100 ? 100 : m) + 1}')
            echo "$ID:$DIR" >> /etc/projects
        fi
        NAME=proj_$ID
        echo "$NAME:$ID" >> /etc/projid
        xfs_quota -x -c "project -s $NAME" "$MNT" >/dev/null
    fi
    [[ -n $QB ]] && xfs_quota -x -c "limit -p bhard=$((QB / 1024))k $NAME" "$MNT"
    used() { xfs_quota -x -c "report -p -b -N" "$MNT" | awk -v n="$NAME" '$1 == n {print $2 * 1024; exit}'; }
    LIMIT=$(xfs_quota -x -c "report -p -b -N" "$MNT" | awk -v n="$NAME" '$1 == n {print $4 * 1024; exit}')
    [[ $LIMIT =~ ^[0-9]+$ ]] && ((LIMIT > 0)) || die "у проекта $NAME нет лимита: укажите квоту 4-м параметром"
else
    [[ -n $QB ]] || die "папка не на XFS задайте порог 4-м параметром"
    LIMIT=$QB
    used() { size_files; }
fi

# размер в %
pct() { awk -v s="$1" -v l="$LIMIT" 'BEGIN {printf "%.2f", s * 100 / l}'; }
USED=$(used)
echo "Папка:   $DIR"
echo "Квота:   $(human "$LIMIT")"
echo "Занято:  $(human "$USED") = $(pct "$USED")% (допустимо до ${N}%)"

((USED * 100 > N * LIMIT)) || { echo "Папка занята не более чем на ${N}% - архивация не требуется."; exit 0; }
echo "Превышено ${N}% - архивирую $M самых старых файлов."

# фильтрация обычные файлы по маске (кроме backup), M самых старых
mapfile -d '' FILES < <(find "$DIR" -type f -name "$MASK" -not -path "$BACKUP/*" -printf '%T@ %P\0' \
    | sort -z -n | head -z -n "$M" | cut -z -d' ' -f2-)
((${#FILES[@]} > 0)) || { echo "Нет файлов под фильтр (маска '$MASK') - архивировать нечего."; exit 0; }

# архив tar.gz в backup, исходники удаляем только после проверки архива
mkdir -p "$BACKUP" || die "не удалось создать '$BACKUP'"
ARC=$BACKUP/log_$(date +%Y%m%d_%H%M%S)_$$.tar.gz
{ printf '%s\0' "${FILES[@]}" | tar -czf "$ARC" -C "$DIR" --null -T - && tar -tzf "$ARC" >/dev/null; } \
    || { rm -f "$ARC"; die "не
ь создать архив, файлы не удалены"; }
(cd "$DIR" && rm -f -- "${FILES[@]}")

echo "Заархивировано файлов: ${#FILES[@]}"
echo "Архив: $ARC"
USED=$(used)
echo "После архивации: $(human "$USED") = $(pct "$USED")%"
