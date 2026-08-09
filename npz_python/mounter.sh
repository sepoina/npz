#!/usr/bin/env bash
#
# mounter.sh — un ext4 in loopback su cui provare `freeze`.
#
# Serve perche' il disco che ospita il progetto e' NTFS via ntfs-3g: non
# conserva i permessi POSIX e non puo' reggere un upperdir di overlayfs, quindi
# `freeze init` lo rifiuta. Dentro l'immagine c'e' invece un ext4 vero, con le
# sue semantiche, indipendente dal filesystem che ospita il file.
#
# Uso:
#   ./mounter.sh crea      crea e formatta l'immagine (una volta sola)
#   ./mounter.sh monta     la monta e la intesta all'utente        [sudo]
#   ./mounter.sh smonta    la smonta e stacca il loop device       [sudo]
#   ./mounter.sh stato     dove sta, quanto e' piena, se e' montata
#   ./mounter.sh butta     smonta e cancella l'immagine            [sudo]
#
# Variabili:
#   FREEZE_IMG    percorso dell'immagine   (default: accanto a questo script)
#   FREEZE_MNT    punto di montaggio       (default: /var/tmp/freeze-prova)
#   FREEZE_SIZE   dimensione               (default: 1G)

set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${FREEZE_IMG:-$QUI/prova.ext4.img}"
# Il punto di montaggio non sta accanto all'immagine ed e' senza spazi di
# proposito: il percorso del progetto ne contiene, e fuse-overlayfs spezza il
# proprio `lowerdir` sui due punti senza saper gestire gli spazi.
MNT="${FREEZE_MNT:-/var/tmp/freeze-prova}"
SIZE="${FREEZE_SIZE:-1G}"

V=$'\033[32m'; X=$'\033[31m'; G=$'\033[33m'; D=$'\033[2m'; Z=$'\033[0m'
[ -t 1 ] || { V=; X=; G=; D=; Z=; }
ok()   { printf '%s✓%s %s\n' "$V" "$Z" "$*"; }
ko()   { printf '%s✗%s %s\n' "$X" "$Z" "$*" >&2; }
nota() { printf '%s  %s%s\n' "$D" "$*" "$Z"; }
die()  { ko "$*"; exit 1; }

loop_di() { losetup -j "$IMG" 2>/dev/null | cut -d: -f1 | head -1; }
montato() { mountpoint -q "$MNT" 2>/dev/null; }

serve_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    die "serve root: rilancia con  sudo $0 $1"
}

# ── crea ─────────────────────────────────────────────────────────────────────

cmd_crea() {
    if [ -e "$IMG" ]; then
        [ "${1:-}" = "--forza" ] || die "l'immagine esiste gia': $IMG
   Usa --forza per rifarla da zero (i dati dentro si perdono), oppure  $0 monta"
        montato && die "smontala prima di rifarla:  sudo $0 smonta"
        rm -f "$IMG"
    fi
    command -v mkfs.ext4 >/dev/null || die "manca mkfs.ext4"

    # Un file sparso: occupa spazio solo per cio' che ci si scrive dentro.
    truncate -s "$SIZE" "$IMG" || die "non riesco a creare $IMG"
    mkfs.ext4 -q -F "$IMG" >/dev/null 2>&1 || die "mkfs.ext4 fallito"
    ok "immagine creata: $IMG ($SIZE, sparsa: occupa $(du -sh "$IMG" | cut -f1))"

    local tipo; tipo=$(findmnt -n -o FSTYPE -T "$IMG" 2>/dev/null)
    case "$tipo" in
        fuse*|ntfs*|exfat|vfat)
            printf '%sattenzione:%s l immagine sta su %s, cioe su FUSE.\n' "$G" "$Z" "$tipo"
            nota "Un loop device su FUSE fa passare ogni scrittura dal demone in"
            nota "user space. Sotto carico sostenuto la memoria puo esaurirsi: e"
            nota "gia successo con immagini da 8 GB e centinaia di migliaia di file."
            nota "Con 1 GB e qualche albero di prova va bene, ma se vuoi spingere"
            nota "sposta l immagine:  FREEZE_IMG=/var/tmp/prova.img $0 crea" ;;
    esac
    nota "ora:  sudo $0 monta"
}

# ── monta ────────────────────────────────────────────────────────────────────

cmd_monta() {
    [ -e "$IMG" ] || die "nessuna immagine: lancia prima  $0 crea"
    montato && { ok "gia' montata su $MNT"; return 0; }
    serve_root monta

    mkdir -p "$MNT"
    # Loop device esplicito invece di `mount -o loop`: quest'ultimo lo marca
    # AUTOCLEAR e lo rilascia in modo asincrono, cosi' il numero successivo puo'
    # essere riassegnato con la page cache ancora sporca del filesystem prima.
    local dev; dev=$(loop_di)
    [ -n "$dev" ] || dev=$(losetup --find --show "$IMG") || die "losetup fallito"
    blockdev --flushbufs "$dev" 2>/dev/null
    mount "$dev" "$MNT" || { losetup -d "$dev"; die "mount fallito"; }

    # Intestata all'utente che ha invocato sudo, altrimenti freeze girerebbe
    # come utente normale su una directory di root e non potrebbe scriverci.
    local utente="${SUDO_USER:-root}"
    chown "$utente:$(id -gn "$utente" 2>/dev/null || echo "$utente")" "$MNT"
    chmod 755 "$MNT"

    ok "montata: $MNT  ($dev)"
    nota "cd $MNT && \"$QUI/lanciatore.py\" attach"
}

# ── smonta ───────────────────────────────────────────────────────────────────

cmd_smonta() {
    serve_root smonta
    # Prima i mount di freeze che stanno dentro, altrimenti l'ext4 e' occupato.
    local interni
    interni=$(findmnt -rn -o TARGET | grep "^$MNT/" | sort -r)
    if [ -n "$interni" ]; then
        nota "smonto prima i mount di freeze che stanno dentro:"
        while read -r p; do
            [ -n "$p" ] || continue
            printf '    %s\n' "$p"
            fusermount3 -u "$p" 2>/dev/null || umount "$p" 2>/dev/null
        done <<<"$interni"
    fi
    if montato; then
        umount "$MNT" || die "non riesco a smontare $MNT: qualcosa lo sta usando.
   Guarda con:  fuser -vm $MNT"
    fi
    local dev; dev=$(loop_di)
    [ -n "$dev" ] && losetup -d "$dev"
    ok "smontata"
}

# ── stato ────────────────────────────────────────────────────────────────────

cmd_stato() {
    printf 'immagine   %s\n' "$IMG"
    if [ -e "$IMG" ]; then
        printf 'dimensione %s dichiarati, %s occupati davvero\n' \
            "$(numfmt --to=iec-i --suffix=B "$(stat -c %s "$IMG")")" \
            "$(du -sh "$IMG" | cut -f1)"
        printf 'ospitata su %s\n' "$(findmnt -n -o FSTYPE -T "$IMG" 2>/dev/null)"
    else
        printf 'dimensione (non esiste ancora)\n'
    fi
    printf 'punto      %s\n' "$MNT"
    if montato; then
        ok "montata su $(loop_di)"
        df -h "$MNT" | tail -1 | awk '{printf "           %s usati su %s (%s)\n", $3, $2, $5}'
        local n; n=$(findmnt -rn -o TARGET | grep -c "^$MNT/")
        [ "$n" -gt 0 ] && nota "$n mount di npz attivi dentro"
        # Le due grafie sono i due nomi della cartella di servizio: `.npz` da
        # montati, `node_modules.frozen` da fermi. Cfr. §5 del piano, "il nome e'
        # lo stato".
        local prog; prog=$(find "$MNT" -maxdepth 3 -type d \
            \( -name .npz -o -name node_modules.frozen \) 2>/dev/null | wc -l)
        if [ "$prog" -gt 0 ]; then
            nota "$prog progetti npz, $(find "$MNT" -maxdepth 5 -path '*/static/*.img' 2>/dev/null | wc -l) immagini"
        fi
    else
        printf '           non montata\n'
    fi
}

# ── butta ────────────────────────────────────────────────────────────────────

cmd_butta() {
    serve_root butta
    cmd_smonta
    rm -f "$IMG"
    rmdir "$MNT" 2>/dev/null
    ok "immagine cancellata"
}

case "${1:-stato}" in
    crea)   shift; cmd_crea "$@" ;;
    monta)  cmd_monta ;;
    smonta) cmd_smonta ;;
    stato)  cmd_stato ;;
    butta)  cmd_butta ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "comando sconosciuto: $1 (crea, monta, smonta, stato, butta)" ;;
esac
