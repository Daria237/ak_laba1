#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

IMG="${1:-$PWD/xfs.img}"
SIZE="${2:-300M}"
MNT="${3:-/mnt/xfsdisk}"

for cmd in mkfs.xfs xfs_quota losetup; do
    if ! command -v "$cmd" >/dev/null; then
        echo "Ошибка: не найдена команда $cmd (sudo apt install xfsprogs)" >&2
        exit 1
    fi
done

if mountpoint -q "$MNT"; then
    echo "$MNT уже смонтирован:"
    findmnt -T "$MNT"
    exit 0
fi

if [[ ! -f "$IMG" ]]; then
    truncate -s "$SIZE" "$IMG" || exit 1
    mkfs.xfs -q "$IMG" || exit 1
    echo "Создан образ $IMG ($SIZE) с файловой системой XFS"
fi

mkdir -p "$MNT"
mount -o loop,prjquota "$IMG" "$MNT" || exit 1
mkdir -p "$MNT/log" /backup

echo "Диск смонтирован в $MNT (опция prjquota включена)"
echo "Папка для логов: $MNT/log, папка для архивов: /backup"
findmnt -T "$MNT"
