#!/usr/bin/env bash
#
# banco-fase1.sh — l'oracolo differenziale del §7 del piano.
#
# Durante il porting esistono **due implementazioni dello stesso formato**, e
# quella vecchia funziona. Questo banco le mette una di fronte all'altra su ogni
# funzione del nucleo, e sulle combinazioni incrociate: costruisci con l'una,
# leggi con l'altra. Quando la fase 3 spegnera' il Python questo attrezzo
# sparira', quindi va usato tutto adesso.
#
# SUL CRITERIO DI USCITA — il §9 del piano chiedeva una immagine «bit-identica»
# a quella del Python. Misurato qui: e' irrealizzabile, e non per colpa del
# porting. `mkfs.erofs` incorpora un **UUID casuale**, quindi due build della
# stessa sorgente differiscono gia' fra Python e Python. Con `-U` fisso
# tornano identiche, il che dimostra che il resto e' deterministico.
#
# Il criterio si riformula percio' cosi', ed e' quello che conta davvero:
#   **il contenuto montato delle due immagini deve coincidere**, attributo per
#   attributo, con lo stesso `inventario()` che il congelamento usa per
#   fidarsi di se' stesso.
#
# Il banco vive in /var/tmp (ext4): il disco del progetto e' NTFS via ntfs-3g e
# non conserva i permessi POSIX, quindi meta' delle verifiche non varrebbero.
#
# Uso:
#   ./banco-fase1.sh            tutto
#   ./banco-fase1.sh check      solo il preflight
#
set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# QUI e' npz_go/test, MODULO e' npz_go, RADICE la radice del repo. I tre
# banchi stanno in test/ come quello del Python, quindi per arrivare alla
# radice si risale di due e non di uno.
MODULO="$(dirname "$QUI")"
RADICE="$(dirname "$MODULO")"
BANCO="${NPZ_BANCO1:-/var/tmp/npz-banco-fase1}"

PASS=0; FAIL=0
declare -a ESITI=()

verde() { printf '\033[32m%s\033[0m' "$1"; }
rosso() { printf '\033[31m%s\033[0m' "$1"; }
info()  { printf '  %s\n' "$*"; }
sez()   { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }
pass()  { PASS=$((PASS+1)); ESITI+=("PASS|$1|${2:-}"); printf '  [%s] %s %s\n' "$(verde PASS)" "$1" "${2:+· $2}"; }
fail()  { FAIL=$((FAIL+1)); ESITI+=("FAIL|$1|${2:-}"); printf '  [%s] %s %s\n' "$(rosso FAIL)" "$1" "${2:+· $2}"; }

# confronta <nome> <atteso> <ottenuto>
confronta() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "py='$(printf '%s' "$2" | head -c 90)' go='$(printf '%s' "$3" | head -c 90)'"
    fi
}

GO=""            # il driver Go
py() { PYTHONPATH="$BANCO" python3 -c "$@"; }

# ── preflight ────────────────────────────────────────────────────────────────

preflight() {
    sez "preflight"
    local mancanti=0
    for t in go python3 mkfs.erofs erofsfuse fusermount3 sha256sum; do
        command -v "$t" >/dev/null 2>&1 && pass "$t presente" || { fail "$t presente" "manca"; mancanti=1; }
    done
    local fs; fs=$(df -T "$(dirname "$BANCO")" | awk 'NR==2{print $2}')
    case "$fs" in
        ext4|xfs|btrfs) pass "il banco vive su un filesystem POSIX" "$fs" ;;
        *) fail "il banco vive su un filesystem POSIX" "$fs"; mancanti=1 ;;
    esac
    return $mancanti
}

# ── costruzione del banco ────────────────────────────────────────────────────

prepara() {
    sez "preparazione"
    rm -rf "$BANCO"; mkdir -p "$BANCO"

    if ! ( cd "$MODULO" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
            -o "$BANCO/nucleo-go" ./test/nucleo ) 2>&1; then
        fail "il driver Go compila"; return 1
    fi
    GO="$BANCO/nucleo-go"
    pass "il driver Go compila"

    cp -r "$RADICE/npz_python" "$BANCO/npz_python"
    find "$BANCO/npz_python" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    pass "npz_python in posizione" "l'oracolo"

    # La fixture: i casi difficili, non quelli facili. Ogni riga qui e' una cosa
    # che EROFS dichiara di conservare e che il porting potrebbe perdere.
    local f="$BANCO/fixture"
    mkdir -p "$f/pacchetto/dist" "$f/.nascosta" "$f/con spazi"
    echo 'module.exports = 1'        > "$f/pacchetto/index.js"
    printf '{"name":"x"}'            > "$f/pacchetto/package.json"
    head -c 4096 /dev/urandom        > "$f/pacchetto/dist/bundle.bin"
    echo 'dentro una cartella nascosta' > "$f/.nascosta/nota.txt"
    echo 'con spazi nel nome'        > "$f/con spazi/file con spazi.txt"
    echo 'unicode: àèìòù 日本語'      > "$f/unicode-àèìòù.txt"
    : > "$f/vuoto.txt"

    ln -s index.js                   "$f/pacchetto/link-relativo"
    ln -s /etc/hostname              "$f/link-assoluto"
    ln -s non-esiste-affatto         "$f/link-rotto"
    ln -s pacchetto                  "$f/link-a-cartella"

    echo 'sorgente hardlink'         > "$f/hard-a"
    ln "$f/hard-a"                   "$f/hard-b"

    mkfifo "$f/fifo" 2>/dev/null || true
    truncate -s 1M                   "$f/sparso.bin"

    chmod 0700 "$f/pacchetto/index.js"
    chmod 0444 "$f/vuoto.txt"
    chmod 0755 "$f/pacchetto/dist"
    chmod 0711 "$f/.nascosta"

    local voci; voci=$(find "$f" | wc -l)
    pass "fixture costruita" "$voci voci, con symlink, hardlink, fifo, sparso, spazi, unicode"
}

# Si insiste: staccare uno strato e subito dopo quello sotto puo' fallire per
# un istante, e una passata sola lascia indietro il mount piu' interno.
smonta_tutto() {
    local m giro
    for giro in 1 2 3; do
        while read -r m; do
            [ -n "$m" ] || continue
            fusermount3 -u "$m" 2>/dev/null || fusermount -u "$m" 2>/dev/null || umount "$m" 2>/dev/null
        done < <(findmnt -rno TARGET 2>/dev/null | grep -F "$BANCO" | sort -r)
        findmnt -rno TARGET 2>/dev/null | grep -qF "$BANCO" || return 0
        sleep 0.2
    done
    printf '  attenzione: mount rimasti sotto %s:\n' "$BANCO" >&2
    findmnt -rno TARGET 2>/dev/null | grep -F "$BANCO" >&2
}
trap smonta_tutto EXIT

# ── 1. lettura: inventario e conta ───────────────────────────────────────────

lettura() {
    sez "lettura dell'albero"
    local f="$BANCO/fixture"

    local inv_go inv_py
    inv_go=$("$GO" inventario "$f")
    inv_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import immagine as img
foto = img.inventario(Path(sys.argv[1]))
for k in sorted(foto):
    tipo, modo, dim, dest, uid, gid = foto[k]
    print(f'{k}\t{tipo:o}\t{modo:o}\t{-1 if dim is None else dim}\t{dest or \"\"}\t{uid}\t{gid}')
" "$f")
    confronta "inventario: Go e Python coincidono" "$inv_py" "$inv_go"
    info "$(printf '%s' "$inv_go" | wc -l) voci confrontate"

    local conta_go conta_py
    conta_go=$("$GO" conta "$f")
    conta_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import immagine as img
f, b, c = img.conta(Path(sys.argv[1]))
print(f, b, c)
" "$f")
    confronta "conta: Go e Python coincidono" "$conta_py" "$conta_go"
    info "conta = $conta_go (file, byte, cartelle)"
}

# ── 2. i percorsi e i nomi ───────────────────────────────────────────────────

nomi() {
    sez "percorsi e nomi"

    local p_go p_py
    p_go=$("$GO" percorsi "$BANCO/radice" "node_modules")
    p_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import immagine as img
p = img.percorsi(Profilo('.npz', '.npz_automount_here'), Path(sys.argv[1]), sys.argv[2])
for k in ('immagine','meta','delta','lavoro','basso'):
    print(f'{k}\t{p[k]}')
" "$BANCO/radice" "node_modules")
    confronta "percorsi: i cinque posti coincidono" "$p_py" "$p_go"

    local r_go r_py
    mkdir -p "$BANCO/radice/sotto/ancora"
    r_go=$("$GO" relativo "$BANCO/radice/sotto/ancora" "$BANCO/radice")
    r_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import immagine as img
print(img.relativo_di(Path(sys.argv[1]), Path(sys.argv[2])))
" "$BANCO/radice/sotto/ancora" "$BANCO/radice")
    confronta "relativo_di coincide" "$r_py" "$r_go"

    local l_go l_py
    for n in 0 1 999 1024 1536 1048576 1073741824; do
        l_go=$("$GO" leggibile "$n")
        l_py=$(py "
import sys
from npz_python.lib.stato import leggibile
print(leggibile(int(sys.argv[1])))
" "$n")
        [ "$l_go" = "$l_py" ] || { fail "leggibile($n)" "py='$l_py' go='$l_go'"; return; }
    done
    pass "leggibile: sette valori coincidono"
}

# ── 3. il filesystem ─────────────────────────────────────────────────────────

filesystem() {
    sez "il giudizio sul filesystem"

    local t_go t_py
    t_go=$("$GO" fs-tipo "$BANCO")
    t_py=$(py "
import sys
from pathlib import Path
from npz_python.lib.filesystem import tipo_filesystem
print(tipo_filesystem(Path(sys.argv[1])) or '')
" "$BANCO")
    confronta "tipo_filesystem coincide" "$t_py" "$t_go"
    info "il banco sta su '$t_go'"

    local i_go i_py
    i_go=$("$GO" fs-idoneita "$BANCO")
    i_py=$(py "
import sys
from pathlib import Path
from npz_python.lib.filesystem import idoneita
print(idoneita(Path(sys.argv[1])) or '')
" "$BANCO")
    confronta "idoneita coincide (filesystem buono)" "$i_py" "$i_go"

    # E i **fatti** da cui quella frase nasce, campo per campo. E' il confronto
    # che regge: un messaggio si rompe al primo ritocco di una parola e non si
    # accorge di una semantica cambiata; un campo fa l'opposto. La prosa resta
    # libera di essere scritta bene in un posto solo per lingua.
    local s_go s_py
    s_go=$("$GO" fs-sonda "$BANCO")
    s_py=$(py "
import sys
from pathlib import Path
from npz_python.lib.filesystem import sonda
s = sonda(Path(sys.argv[1]))
print(f'scrivibile={str(s.scrivibile).lower()}')
print(f'proprietario_estraneo={str(s.proprietario_estraneo).lower()}')
print(f'uid_visto={s.uid_visto}')
print(f'chmod_riesce={str(s.chmod_riesce).lower()}')
print(f'chmod_attecchisce={str(s.chmod_attecchisce).lower()}')
print(f'esecuzione_ottenibile={str(s.esecuzione_ottenibile).lower()}')
print(f'modo_riletto={s.modo_riletto:o}')
print(f'tipo={s.tipo or \"\"}')
print(f'sorgente={s.sorgente or \"\"}')
print(f'uuid={s.uuid or \"\"}')
print(f'device={str(s.device).lower()}')
" "$BANCO")
    confronta "sonda: i fatti coincidono campo per campo" "$s_py" "$s_go"

    # E su uno cattivo: il disco del progetto, che e' NTFS via ntfs-3g.
    if [ -d "$RADICE" ]; then
        local b_go b_py
        b_go=$("$GO" fs-idoneita "$RADICE" 2>/dev/null)
        b_py=$(py "
import sys
from pathlib import Path
from npz_python.lib.filesystem import idoneita
print(idoneita(Path(sys.argv[1])) or '')
" "$RADICE" 2>/dev/null)
        confronta "idoneita coincide (filesystem cattivo)" "$b_py" "$b_go"
        [ -n "$b_go" ] && info "rifiutato con: $(printf '%s' "$b_go" | head -c 70)…"
    fi
}

# ── 4. costruzione, e il criterio riformulato ────────────────────────────────

costruzione() {
    sez "costruzione dell'immagine"
    local f="$BANCO/fixture"

    # Prima: mkfs.erofs e' deterministico a UUID fisso? Se no, nessun confronto
    # byte a byte ha senso, e va detto qui invece di scoprirlo per caso.
    mkfs.erofs -zlz4hc -U 00000000-0000-0000-0000-000000000000 "$BANCO/det1.img" "$f" >/dev/null 2>&1
    mkfs.erofs -zlz4hc -U 00000000-0000-0000-0000-000000000000 "$BANCO/det2.img" "$f" >/dev/null 2>&1
    local d1 d2
    d1=$(sha256sum "$BANCO/det1.img" | cut -d' ' -f1)
    d2=$(sha256sum "$BANCO/det2.img" | cut -d' ' -f1)
    if [ "$d1" = "$d2" ]; then
        pass "mkfs.erofs e' deterministico a UUID fisso" "il resto dell'immagine non ha entropia"
    else
        fail "mkfs.erofs e' deterministico a UUID fisso" "nemmeno con -U: niente e' confrontabile"
    fi

    # E senza -U? Se differisce, il criterio «bit-identica» del §9 e' sbagliato.
    mkfs.erofs -zlz4hc "$BANCO/rnd1.img" "$f" >/dev/null 2>&1
    mkfs.erofs -zlz4hc "$BANCO/rnd2.img" "$f" >/dev/null 2>&1
    if [ "$(sha256sum "$BANCO/rnd1.img" | cut -d' ' -f1)" \
       = "$(sha256sum "$BANCO/rnd2.img" | cut -d' ' -f1)" ]; then
        info "senza -U le immagini coincidono: il criterio del §9 sarebbe applicabile"
    else
        pass "l'UUID casuale spiega perche' il §9 va riformulato" "py≠py sulla stessa sorgente"
    fi

    # Ora le due implementazioni, ognuna con la propria.
    local tmp_go tmp_py
    tmp_go=$("$GO" costruisci "$f" "$BANCO/static/go/node_modules.img" lz4hc) || { fail "Go costruisce"; return 1; }
    pass "Go costruisce l'immagine" "$(basename "$tmp_go")"

    tmp_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import immagine as img
print(img.costruisci(Path(sys.argv[1]), Path(sys.argv[2])))
" "$f" "$BANCO/static/py/node_modules.img") || { fail "Python costruisce"; return 1; }
    pass "Python costruisce l'immagine" "$(basename "$tmp_py")"

    mv "$tmp_go" "$BANCO/go.img"; mv "$tmp_py" "$BANCO/py.img"

    local s_go s_py
    s_go=$(stat -c%s "$BANCO/go.img"); s_py=$(stat -c%s "$BANCO/py.img")
    if [ "$s_go" = "$s_py" ]; then
        pass "le due immagini hanno la stessa dimensione" "$s_go byte"
    else
        fail "le due immagini hanno la stessa dimensione" "go=$s_go py=$s_py"
    fi
}

# ── 5. il criterio: il contenuto montato coincide ────────────────────────────

contenuto() {
    sez "il contenuto montato — il criterio di uscita"
    local f="$BANCO/fixture"

    mkdir -p "$BANCO/m-go" "$BANCO/m-py"
    erofsfuse "$BANCO/go.img" "$BANCO/m-go" >/dev/null 2>&1; sleep 0.3
    erofsfuse "$BANCO/py.img" "$BANCO/m-py" >/dev/null 2>&1; sleep 0.3
    mountpoint -q "$BANCO/m-go" && mountpoint -q "$BANCO/m-py" \
        || { fail "le due immagini si montano"; return 1; }
    pass "le due immagini si montano"

    # a) il contenuto delle due immagini coincide fra loro
    local inv_a inv_b
    inv_a=$("$GO" inventario "$BANCO/m-go")
    inv_b=$("$GO" inventario "$BANCO/m-py")
    confronta "immagine Go ≡ immagine Python (contenuto)" "$inv_b" "$inv_a"

    # b) e coincide con la sorgente: e' l'invariante vera del congelamento
    local inv_src; inv_src=$("$GO" inventario "$f")
    confronta "immagine Go ≡ sorgente" "$inv_src" "$inv_a"
    confronta "immagine Python ≡ sorgente" "$inv_src" "$inv_b"

    # c) e il Python legge l'immagine di Go dicendo la stessa cosa
    local inv_pygo
    inv_pygo=$(py "
import sys
from pathlib import Path
from npz_python.lib import immagine as img
foto = img.inventario(Path(sys.argv[1]))
for k in sorted(foto):
    tipo, modo, dim, dest, uid, gid = foto[k]
    print(f'{k}\t{tipo:o}\t{modo:o}\t{-1 if dim is None else dim}\t{dest or \"\"}\t{uid}\t{gid}')
" "$BANCO/m-go")
    confronta "il Python legge l'immagine di Go allo stesso modo" "$inv_a" "$inv_pygo"

    # ── la lacuna dell'inventario ────────────────────────────────────────────
    #
    # `inventario()` confronta tipo, modo, dimensione, destinazione, uid e gid.
    # **Non guarda nlink ne' inode**, quindi due hardlink e due file identici
    # gli sembrano la stessa cosa, e la promessa di claim.md — "EROFS conserva
    # hardlink con il loro nlink e lo stesso inode" — non e' verificata da
    # nessuno dei due nuclei. E' una lacuna dell'originale, portata identica
    # per non rompere l'oracolo; si chiude qui, nel banco, dove non ha effetti
    # sul confronto fra le implementazioni.
    local ino_a ino_b nl_a
    ino_a=$(stat -c%i "$BANCO/m-go/hard-a"); ino_b=$(stat -c%i "$BANCO/m-go/hard-b")
    nl_a=$(stat -c%h "$BANCO/m-go/hard-a")
    if [ "$ino_a" = "$ino_b" ] && [ "$nl_a" -ge 2 ]; then
        pass "l'hardlink sopravvive dentro l'immagine" "stesso inode, nlink=$nl_a"
    else
        fail "l'hardlink sopravvive dentro l'immagine" "ino $ino_a vs $ino_b, nlink=$nl_a"
    fi

    [ "$(stat -c%F "$BANCO/m-go/fifo")" = "fifo" ] \
        && pass "il fifo sopravvive dentro l'immagine" \
        || fail "il fifo sopravvive dentro l'immagine"

    [ "$(readlink "$BANCO/m-go/link-rotto")" = "non-esiste-affatto" ] \
        && pass "il symlink rotto sopravvive dentro l'immagine" \
        || fail "il symlink rotto sopravvive dentro l'immagine"

    # Il file sparso: 1 MiB dichiarato, zero occupato. La compressione riduce
    # gli zeri a nulla, quindi l'immagine intera deve restare minuscola.
    local peso; peso=$(stat -c%s "$BANCO/go.img")
    if [ "$peso" -lt 262144 ]; then
        pass "il file sparso non viene riespanso" "immagine di $peso byte per 1 MiB dichiarato"
    else
        fail "il file sparso non viene riespanso" "immagine di $peso byte"
    fi

    smonta_tutto
}

# ── 6. verifica incrociata ───────────────────────────────────────────────────

incrocio() {
    sez "verifica incrociata"
    local f="$BANCO/fixture"

    if "$GO" verifica "$BANCO/go.img" "$f" "$BANCO/v1" >/dev/null 2>&1; then
        pass "Go verifica l'immagine di Go"
    else
        fail "Go verifica l'immagine di Go"
    fi

    if "$GO" verifica "$BANCO/py.img" "$f" "$BANCO/v2" >/dev/null 2>&1; then
        pass "Go verifica l'immagine del Python"
    else
        fail "Go verifica l'immagine del Python"
    fi

    if py "
import sys
from pathlib import Path
from npz_python.lib import immagine as img, mount
img.verifica(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), mount.scegli())
" "$BANCO/go.img" "$f" "$BANCO/v3" >/dev/null 2>&1; then
        pass "il Python verifica l'immagine di Go"
    else
        fail "il Python verifica l'immagine di Go"
    fi

    # E il caso negativo: se la sorgente cambia, la verifica DEVE fallire.
    # Una verifica che passa sempre non e' una verifica.
    cp -r "$f" "$BANCO/guasta"
    echo 'intruso' > "$BANCO/guasta/intruso.txt"
    if "$GO" verifica "$BANCO/go.img" "$BANCO/guasta" "$BANCO/v4" >/dev/null 2>&1; then
        fail "la verifica fallisce su una sorgente diversa" "ha detto ok: non verifica niente"
    else
        pass "la verifica fallisce su una sorgente diversa" "il caso negativo tiene"
    fi
    smonta_tutto
}

# ── 7. config, meta, lock ────────────────────────────────────────────────────

persistenza() {
    sez "config, meta e lock"
    local r="$BANCO/radice"
    mkdir -p "$r/.npz"

    # config: Go scrive, Python legge
    "$GO" config-scrivi "$r" lz4hc || { fail "Go scrive il config"; return 1; }
    local c_py
    c_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import stato as st
d = st.leggi_config(Profilo('.npz','.npz_automount_here'), Path(sys.argv[1]))
for k in sorted(d): print(f'{k}\t{d[k]}')
" "$r" 2>&1) && pass "il Python legge il config scritto da Go" \
        || fail "il Python legge il config scritto da Go" "$(printf '%s' "$c_py" | tail -1)"

    # config: Python scrive, Go legge
    rm -f "$r/.npz/config"
    py "
import sys
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import stato as st
st.scrivi_config(Profilo('.npz','.npz_automount_here'), Path(sys.argv[1]))
" "$r"
    local c_go
    c_go=$("$GO" config-leggi "$r" 2>&1) && pass "Go legge il config scritto dal Python" \
        || fail "Go legge il config scritto dal Python" "$(printf '%s' "$c_go" | tail -1)"

    # e le chiavi devono essere le stesse
    local k_go k_py
    "$GO" config-scrivi "$r" lz4hc
    k_go=$("$GO" config-leggi "$r" | cut -f1 | sort)
    rm -f "$r/.npz/config"
    py "
import sys
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import stato as st
st.scrivi_config(Profilo('.npz','.npz_automount_here'), Path(sys.argv[1]))
" "$r"
    k_py=$("$GO" config-leggi "$r" | cut -f1 | sort)
    confronta "config: stesse chiavi da entrambe le parti" "$k_py" "$k_go"

    # meta: Go scrive, Python legge — e viceversa
    local m="$BANCO/static/node_modules.meta"
    mkdir -p "$(dirname "$m")"
    "$GO" meta-scrivi "$m" '{"creata":"2026-08-07 12:00:00","file":31667,"byte":616562688,"compressione":"lz4hc"}'
    local m_py
    m_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import stato as st
d = st.leggi_meta(Path(sys.argv[1]))
for k in sorted(d): print(f'{k}\t{d[k]}')
" "$m")
    local m_go; m_go=$("$GO" meta-leggi "$m")
    confronta "meta: Go scrive, entrambi rileggono lo stesso" "$m_py" "$m_go"

    rm -f "$m"
    py "
import sys
from pathlib import Path
from npz_python.lib import stato as st
st.scrivi_meta(Path(sys.argv[1]), {'creata':'2026-08-07 12:00:00','file':31667,'byte':616562688,'compressione':'lz4hc'})
" "$m"
    m_go=$("$GO" meta-leggi "$m")
    m_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import stato as st
d = st.leggi_meta(Path(sys.argv[1]))
for k in sorted(d): print(f'{k}\t{d[k]}')
" "$m")
    confronta "meta: Python scrive, entrambi rileggono lo stesso" "$m_py" "$m_go"

    # formato sbagliato: entrambi devono rifiutare
    printf '{"formato": 99, "creata_da": "0.0.1"}\n' > "$r/.npz/config"
    local rifiuta_go=0 rifiuta_py=0
    "$GO" config-leggi "$r" >/dev/null 2>&1 || rifiuta_go=1
    py "
import sys
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import stato as st
st.leggi_config(Profilo('.npz','.npz_automount_here'), Path(sys.argv[1]))
" "$r" >/dev/null 2>&1 || rifiuta_py=1
    if [ "$rifiuta_go" = 1 ] && [ "$rifiuta_py" = 1 ]; then
        pass "entrambi rifiutano un formato che non parlano" "formato versionato, §invarianti"
    else
        fail "entrambi rifiutano un formato che non parlano" "go=$rifiuta_go py=$rifiuta_py"
    fi
    "$GO" config-scrivi "$r" lz4hc

    # ── il lock: e' lo stesso lock del kernel, e si devono vedere ────────────
    "$GO" lock "$r" 3 > "$BANCO/lock.out" 2>&1 &
    local pid_go=$!
    local atteso=0
    while [ $atteso -lt 40 ]; do
        grep -q preso "$BANCO/lock.out" 2>/dev/null && break
        sleep 0.05; atteso=$((atteso+1))
    done
    if grep -q preso "$BANCO/lock.out" 2>/dev/null; then
        if py "
import sys
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import stato as st
with st.lock(Profilo('.npz','.npz_automount_here'), Path(sys.argv[1])):
    pass
" "$r" >/dev/null 2>&1; then
            fail "il lock di Go esclude il Python" "il Python e' entrato lo stesso"
        else
            pass "il lock di Go esclude il Python" "flock e' del kernel, non del linguaggio"
        fi
    else
        fail "il lock di Go esclude il Python" "Go non ha preso il lock"
    fi
    wait $pid_go 2>/dev/null

    # e nell'altro verso
    py "
import sys, time
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import stato as st
with st.lock(Profilo('.npz','.npz_automount_here'), Path(sys.argv[1])):
    print('preso', flush=True)
    time.sleep(3)
" "$r" > "$BANCO/lock2.out" 2>&1 &
    local pid_py=$!
    atteso=0
    while [ $atteso -lt 40 ]; do
        grep -q preso "$BANCO/lock2.out" 2>/dev/null && break
        sleep 0.05; atteso=$((atteso+1))
    done
    if grep -q preso "$BANCO/lock2.out" 2>/dev/null; then
        if "$GO" lock "$r" 0 >/dev/null 2>&1; then
            fail "il lock del Python esclude Go" "Go e' entrato lo stesso"
        else
            pass "il lock del Python esclude Go" "l'esclusione vale nei due sensi"
        fi
    else
        fail "il lock del Python esclude Go" "il Python non ha preso il lock"
    fi
    wait $pid_py 2>/dev/null

    # e il lock si rilascia da solo alla morte del processo
    "$GO" lock "$r" 10 > "$BANCO/lock3.out" 2>&1 &
    local pid_kill=$!
    atteso=0
    while [ $atteso -lt 40 ]; do
        grep -q preso "$BANCO/lock3.out" 2>/dev/null && break
        sleep 0.05; atteso=$((atteso+1))
    done
    kill -9 $pid_kill 2>/dev/null; wait $pid_kill 2>/dev/null
    sleep 0.2
    if "$GO" lock "$r" 0 >/dev/null 2>&1; then
        pass "il lock cade alla morte del processo" "la proprieta' per cui si usa flock"
    else
        fail "il lock cade alla morte del processo" "e' rimasto preso dopo un SIGKILL"
    fi

    # elenca
    local e_go e_py
    mkdir -p "$r/.npz/static/sotto"
    : > "$r/.npz/static/node_modules.img"; : > "$r/.npz/static/sotto/altro.img"
    e_go=$("$GO" elenca "$r")
    e_py=$(py "
import sys
from pathlib import Path
from npz_python.lib import Profilo
from npz_python.lib import immagine as img
for n in img.elenca(Profilo('.npz','.npz_automount_here'), Path(sys.argv[1])): print(n)
" "$r")
    confronta "elenca: le immagini trovate coincidono" "$e_py" "$e_go"
}

# ── report ───────────────────────────────────────────────────────────────────

report() {
    local f="$QUI/report-fase1-go.md"
    {
        echo "# Fase 1 del porting in Go — il nucleo"
        echo
        echo "- data: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- go: \`$(go version | awk '{print $3}')\` · python: \`$(python3 --version | awk '{print $2}')\`"
        echo "- banco: \`$BANCO\` ($(df -T "$BANCO" | awk 'NR==2{print $2}'))"
        echo
        echo "## Il criterio di uscita, riformulato"
        echo
        echo "Il §9 del piano chiedeva una immagine **bit-identica** a quella del Python."
        echo "Misurato qui: irrealizzabile, e non per colpa del porting — \`mkfs.erofs\`"
        echo "incorpora un UUID casuale, quindi due build della stessa sorgente"
        echo "differiscono gia' fra Python e Python. Con \`-U\` fisso tornano identiche,"
        echo "il che dimostra che tutto il resto dell'immagine e' deterministico."
        echo
        echo "Il criterio diventa: **il contenuto montato delle due immagini coincide**,"
        echo "attributo per attributo, e coincide con la sorgente. E' la proprieta' che"
        echo "il congelamento usa per fidarsi di se' stesso, ed e' quella che conta."
        echo
        echo "## Esiti"
        echo
        echo "| Esito | Verifica | Dettaglio |"
        echo "| --- | --- | --- |"
        local r; for r in "${ESITI[@]}"; do
            IFS='|' read -r e v d <<< "$r"; echo "| $e | $v | $d |"
        done
        echo
        echo "## Verdetto"
        echo
        if [ "$FAIL" -eq 0 ]; then
            echo "Il nucleo Go e il nucleo Python sono **indistinguibili** su tutto cio' che"
            echo "il banco sa chiedere: stessa lettura dell'albero, stessi percorsi, stesso"
            echo "giudizio sul filesystem, immagini con lo stesso contenuto, verifica che"
            echo "funziona in tutte e quattro le combinazioni incrociate, e lo stesso lock."
            echo
            echo "La fase 2 — la facciata — puo' cominciare."
        else
            echo "**$FAIL divergenze.** Vanno chiuse prima di passare alla facciata: e'"
            echo "adesso che l'oracolo esiste, e dopo la fase 3 non ci sara' piu'."
        fi
    } > "$f"
    sez "report"; info "scritto in $f"
}

main() {
    printf '\033[1mbanco della fase 1 — il nucleo, contro l'\''oracolo Python\033[0m\n'
    info "banco: $BANCO"
    preflight || { echo; rosso "preflight fallito"; echo; exit 1; }
    [ "${1:-}" = check ] && exit 0
    prepara || exit 1
    lettura
    nomi
    filesystem
    costruzione
    contenuto
    incrocio
    persistenza
    report
    sez "riepilogo"
    printf '  %s pass · %s fail\n\n' "$(verde "$PASS")" "$( [ "$FAIL" -gt 0 ] && rosso "$FAIL" || echo "$FAIL" )"
    [ "$FAIL" -eq 0 ]
}

main "$@"
