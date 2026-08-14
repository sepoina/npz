#!/usr/bin/env bash
#
# banco.sh — le misure della fase 0 del porting in Go.
#
# Risponde al criterio di uscita del §8 del piano: se una di queste righe
# fallisce, Go non e' la risposta e si riapre il confronto a tre. Non e' codice
# di prodotto, come `fase0.sh` non lo era.
#
# Il banco vive in /var/tmp (ext4) e NON nella cartella del progetto, che sta su
# NTFS via ntfs-3g: far partire un binario da un filesystem FUSE aggiungerebbe
# il demone alla misura dell'avvio, che e' esattamente cio' che si sta misurando.
#
# Uso:
#   ./banco.sh            tutto
#   ./banco.sh check      solo il preflight
#
set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# QUI e' npz_go/test, MODULO e' npz_go, RADICE la radice del repo. I tre
# banchi stanno in test/ come quello del Python, quindi per arrivare alla
# radice si risale di due e non di uno.
MODULO="$(dirname "$QUI")"
RADICE="$(dirname "$MODULO")"
BANCO="${NPZ_BANCO:-/var/tmp/npz-banco-go}"
GIRI_V="${GIRI_V:-100}"    # N6 usava 30: troppo pochi per una misura da 2 ms
GIRI_N="${GIRI_N:-20}"     # come N6
RIP_V="${RIP_V:-5}"        # ripetizioni, di cui si prende la mediana
RIP_N="${RIP_N:-3}"

PASS=0; FAIL=0
declare -a ESITI=() MISURE=()

verde() { printf '\033[32m%s\033[0m' "$1"; }
rosso() { printf '\033[31m%s\033[0m' "$1"; }
info()  { printf '  %s\n' "$*"; }
sez()   { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

pass() { PASS=$((PASS+1)); ESITI+=("PASS|$1|${2:-}"); printf '  [%s] %s %s\n' "$(verde PASS)" "$1" "${2:+· $2}"; }
fail() { FAIL=$((FAIL+1)); ESITI+=("FAIL|$1|${2:-}"); printf '  [%s] %s %s\n' "$(rosso FAIL)" "$1" "${2:+· $2}"; }
misura() { MISURE+=("$1|$2"); printf '  %-46s %s\n' "$1" "$2"; }

# ── preflight ────────────────────────────────────────────────────────────────

preflight() {
    sez "preflight"
    local mancanti=0
    for t in go npm mkfs.erofs erofsfuse fusermount3 bc numfmt; do
        if command -v "$t" >/dev/null 2>&1; then
            pass "$t presente"
        else
            fail "$t presente" "manca"; mancanti=1
        fi
    done
    local fs; fs=$(df -T "$(dirname "$BANCO")" | awk 'NR==2{print $2}')
    case "$fs" in
        ext4|xfs|btrfs) pass "il banco vive su un filesystem POSIX" "$fs" ;;
        *) fail "il banco vive su un filesystem POSIX" "$fs — le misure non varrebbero" ; mancanti=1 ;;
    esac
    return $mancanti
}

# ── costruzione ──────────────────────────────────────────────────────────────

costruisci() {
    sez "costruzione"
    rm -rf "$BANCO"; mkdir -p "$BANCO"

    if ! ( cd "$MODULO" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
            -o "$BANCO/npz-go" ./test/spike ) 2>&1; then
        fail "il binario Go compila"; return 1
    fi
    pass "il binario Go compila"

    local peso; peso=$(stat -c%s "$BANCO/npz-go")
    misura "binario Go (CGO_ENABLED=0, -s -w)" "$(numfmt --to=iec-i --suffix=B "$peso")"
    if [ "$peso" -lt 5242880 ]; then
        pass "il binario sta sotto i 5 MB" "$(numfmt --to=iec-i --suffix=B "$peso")"
    else
        fail "il binario sta sotto i 5 MB" "$(numfmt --to=iec-i --suffix=B "$peso")"
    fi

    # Si guarda `file` e non `ldd`: il messaggio di ldd e' tradotto dal locale,
    # e cercarlo per stringa e' una prova che passa o fallisce a seconda di
    # LANG. `file` dice "statically linked" in ogni lingua.
    if file "$BANCO/npz-go" | grep -q "statically linked"; then
        pass "il binario e' statico: nessuna dipendenza da glibc"
    else
        fail "il binario e' statico: nessuna dipendenza da glibc" "$(file "$BANCO/npz-go" | cut -d: -f2- | cut -c1-60)"
    fi

}

# ── la fixture: un progetto davvero montato ──────────────────────────────────
#
# Serve un mount vero, perche' lo stato *montato* si riconosce con ismount e non
# si puo' simulare. erofsfuse non richiede privilegi, quindi si costruisce una
# immagine minuscola e la si monta da utente: e' anche una verifica gratuita che
# lo stack FUSE regga su questa macchina.

MONTATA=""

fixture() {
    sez "fixture"
    local p="$BANCO/progetto"
    mkdir -p "$p"
    printf '{"name":"m","version":"1.0.0","scripts":{"noop":"true"}}' > "$p/package.json"

    mkdir -p "$BANCO/contenuto/pacchetto"
    echo "module.exports = 1" > "$BANCO/contenuto/pacchetto/index.js"

    mkdir -p "$p/.npz/static"
    if ! mkfs.erofs -zlz4hc "$p/.npz/static/node_modules.img" "$BANCO/contenuto" >/dev/null 2>&1; then
        fail "immagine EROFS costruita"; return 1
    fi
    pass "immagine EROFS costruita" "lz4hc"

    mkdir -p "$p/node_modules"
    if ! erofsfuse "$p/.npz/static/node_modules.img" "$p/node_modules" >/dev/null 2>&1; then
        fail "immagine montata con erofsfuse (senza privilegi)"; return 1
    fi
    sleep 0.3
    if mountpoint -q "$p/node_modules"; then
        MONTATA="$p/node_modules"
        pass "immagine montata con erofsfuse (senza privilegi)"
    else
        fail "immagine montata con erofsfuse (senza privilegi)" "il mount non risulta"
        return 1
    fi

    # npm finto: /bin/true. E' cio' che faceva N6 con `execvp("true")` — si
    # misura il costo del wrapper, non quello di npm.
    mkdir -p "$BANCO/finto"
    ln -sf /bin/true "$BANCO/finto/npm"
    pass "npm finto in posizione" "misura il wrapper, non npm"
}

# Si smonta **tutto** cio' che sta sotto il banco, dal piu' profondo al piu'
# superficiale, e non solo cio' che questo script ha montato di suo.
#
# La ragione l'ha insegnata il banco stesso: smontando solo la fixture, resta al
# suo posto `node_modules` come cartella vuota — cioe' la fixture finisce nello
# stato *rotto*, e la prima invocazione successiva di npz li' dentro prende il
# percorso lento e monta per conto proprio dentro `.npz/run/`. Un residuo che
# non si vede e che falsa la misura del giro dopo.
smonta() {
    local m
    while read -r m; do
        [ -n "$m" ] || continue
        fusermount3 -u "$m" 2>/dev/null || fusermount -u "$m" 2>/dev/null || umount "$m" 2>/dev/null
    done < <(findmnt -rno TARGET 2>/dev/null | grep -F "$BANCO" | sort -r)
    MONTATA=""
    # E la cartella non deve restare vuota: assente e' l'unico stato che non
    # somiglia a una perdita di dati (§6 del piano).
    rmdir "$BANCO/progetto/node_modules" 2>/dev/null || true
}
trap smonta EXIT

# ── la macchina a stati ──────────────────────────────────────────────────────

stati() {
    sez "la macchina a stati"
    local p="$BANCO/progetto"

    stato_in() { ( cd "$1" && NPZ_SPIKE_STATO=1 "$BANCO/npz-go" ) 2>/dev/null; }

    # montato: la fixture cosi' com'e'
    local s; s=$(stato_in "$p")
    [ "$s" = mounted ] && pass "stato: mounted" || fail "stato: mounted" "ha detto '$s'"

    # estraneo: nessun package.json risalendo (dentro il banco, che non ne ha)
    mkdir -p "$BANCO/fuori"
    s=$(stato_in "$BANCO/fuori")
    [ "$s" = outside ] && pass "stato: outside" || fail "stato: outside" "ha detto '$s'"

    # vergine / candidato / rifiutato / congelato, su progetti fabbricati
    local q="$BANCO/prova-stati"
    rm -rf "$q"; mkdir -p "$q"; printf '{"name":"q"}' > "$q/package.json"
    s=$(stato_in "$q"); [ "$s" = fresh ] && pass "stato: fresh" || fail "stato: fresh" "ha detto '$s'"

    mkdir -p "$q/node_modules"
    s=$(stato_in "$q"); [ "$s" = candidate ] && pass "stato: candidate" || fail "stato: candidate" "ha detto '$s'"

    mkdir -p "$q/.npz"; touch "$q/.npz/no"
    s=$(stato_in "$q"); [ "$s" = declined ] && pass "stato: declined" || fail "stato: declined" "ha detto '$s'"

    rm -rf "$q/.npz" "$q/node_modules"
    mkdir -p "$q/.npz/static"; cp "$p/.npz/static/node_modules.img" "$q/.npz/static/"
    s=$(stato_in "$q"); [ "$s" = attached ] && pass "stato: attached" || fail "stato: attached" "ha detto '$s'"

    # rotto: la cartella c'e', non e' montata, dentro c'e' solo la sentinella
    mkdir -p "$q/node_modules"; touch "$q/node_modules/.npz_automount_here"
    s=$(stato_in "$q"); [ "$s" = broken ] && pass "stato: broken" || fail "stato: broken" "ha detto '$s'"

    # scavalcato: un albero vero al posto del mount
    touch "$q/node_modules/qualcosa.js"
    s=$(stato_in "$q"); [ "$s" = bypassed ] && pass "stato: bypassed" || fail "stato: bypassed" "ha detto '$s'"
}

# ── la trasparenza di Exec ───────────────────────────────────────────────────

trasparenza() {
    sez "la trasparenza di syscall.Exec"
    local p="$BANCO/progetto"

    # Il finto npm delle misure e' un *symlink* a /bin/true, cosi' che exec non
    # si trascini dietro l'avvio di una shell. Qui invece serve uno script vero,
    # e va rimosso prima: scrivere con `>` su un symlink segue il link, cioe'
    # tenterebbe di scrivere su /bin/true.
    finge_npm() {
        rm -f "$BANCO/finto/npm"
        printf '%s\n' "$1" > "$BANCO/finto/npm"
        chmod +x "$BANCO/finto/npm"
    }

    # codice di uscita: npm finto che esce con 42
    finge_npm '#!/bin/sh
exit 42'
    ( cd "$p" && PATH="$BANCO/finto:$PATH" "$BANCO/npz-go" ls >/dev/null 2>&1 )
    local esito=$?
    [ "$esito" -eq 42 ] && pass "il codice di uscita passa" "42" \
        || fail "il codice di uscita passa" "atteso 42, ottenuto $esito"

    # morte per segnale: npm finto che si uccide con SIGTERM → 128+15
    finge_npm '#!/bin/sh
kill -TERM $$'
    ( cd "$p" && PATH="$BANCO/finto:$PATH" "$BANCO/npz-go" ls >/dev/null 2>&1 )
    esito=$?
    [ "$esito" -eq 143 ] && pass "la morte per segnale passa" "143 = 128+SIGTERM" \
        || fail "la morte per segnale passa" "atteso 143, ottenuto $esito"

    # TTY: npm finto che dichiara se stdin e' un terminale, dentro uno pty
    finge_npm '#!/bin/sh
test -t 0 && echo TTY || echo NOTTY'
    if command -v script >/dev/null 2>&1; then
        local vista; vista=$( cd "$p" && PATH="$BANCO/finto:$PATH" \
            script -qec "$BANCO/npz-go ls" /dev/null 2>/dev/null | tr -d '\r' | grep -o 'TTY\|NOTTY' | head -1 )
        [ "$vista" = TTY ] && pass "il TTY passa a npm" \
            || fail "il TTY passa a npm" "npm ha visto '$vista'"
    else
        info "script(1) assente: prova del TTY saltata"
    fi

    # §6.1 — la coda della voce esce PRIMA dell'output di npm
    finge_npm '#!/bin/sh
echo OUTPUT_DI_NPM'
    local flusso; flusso=$( cd "$p" && PATH="$BANCO/finto:$PATH" NPZ_SPIKE_PARLA=1 \
        "$BANCO/npz-go" ls 2>&1 )
    local riga_coda riga_npm
    riga_coda=$(printf '%s\n' "$flusso" | grep -n '╨' | head -1 | cut -d: -f1)
    riga_npm=$(printf '%s\n' "$flusso" | grep -n 'OUTPUT_DI_NPM' | head -1 | cut -d: -f1)
    if [ -n "$riga_coda" ] && [ -n "$riga_npm" ] && [ "$riga_coda" -lt "$riga_npm" ]; then
        pass "la coda della voce esce prima di Exec" "§6.1"
    else
        fail "la coda della voce esce prima di Exec" "coda=${riga_coda:-mai} npm=${riga_npm:-mai}"
    fi

    ln -sf /bin/true "$BANCO/finto/npm"
}

# ── le misure ────────────────────────────────────────────────────────────────

cronometra() {                # cronometra <n> <comando…>
    local n="$1"; shift
    local t0 t1 i
    t0=$(date +%s%N)
    for i in $(seq "$n"); do "$@" >/dev/null 2>&1; done
    t1=$(date +%s%N)
    echo "scale=2; ($t1 - $t0) / $n / 1000000" | bc -l
}

mediana() {                   # mediana <valore…>
    printf '%s\n' "$@" | sort -g | \
        awk '{a[NR]=$1} END{print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}'
}

# I 30 giri di N6 bastavano per una misura da 13 ms; per una da 2 non bastano —
# il primo giro di questo banco ha prodotto 4,0 ms a riposo e 3,2 sotto carico,
# cioe' una contraddizione, che e' il modo in cui il rumore si annuncia. Si
# ripete e si prende la mediana, che alle code non si lascia spostare.
cronometra_m() {              # cronometra_m <ripetizioni> <giri> <comando…>
    local rip="$1" n="$2"; shift 2
    local v=() r
    for r in $(seq "$rip"); do v+=("$(cronometra "$n" "$@")"); done
    mediana "${v[@]}"
}

misure() {
    sez "il percorso veloce"
    local p="$BANCO/progetto"
    ln -sf /bin/true "$BANCO/finto/npm"

    # Il denominatore con npm VERO: e' il costo che il wrapper deve sfiorare.
    local npm_vero; npm_vero=$( cd "$p" && cronometra_m "$RIP_N" "$GIRI_N" npm run noop )
    misura "npm run <vuoto>, a riposo" "${npm_vero} ms"

    # Il pavimento: generare un processo qualunque e aspettarlo, dal ciclo di
    # bash. Nessun wrapper puo' scendere sotto, e sottraendolo si vede quanto
    # costa davvero npz invece di quanto costa esistere.
    local suolo; suolo=$( cd "$p" && cronometra_m "$RIP_V" "$GIRI_V" /bin/true )
    misura "pavimento (/bin/true nudo)" "${suolo} ms"

    # Il numeratore, con npm finto: si misura il wrapper, non npm.
    local go
    go=$( cd "$p" && PATH="$BANCO/finto:$PATH" cronometra_m "$RIP_V" "$GIRI_V" "$BANCO/npz-go" ls )

    misura "spike Go" "${go} ms"
    misura "costo proprio di npz: Go" "$(echo "scale=2; $go-$suolo" | bc -l) ms"
    misura "sovraccarico Go su npm" "$(echo "scale=1; 100*$go/$npm_vero" | bc -l)%"

    if (( $(echo "$go < 3" | bc -l) )); then
        pass "il percorso veloce sta sotto i 3 ms" "${go} ms"
    else
        fail "il percorso veloce sta sotto i 3 ms" "${go} ms — Go non compra quel che promette"
    fi

    # Sotto carico, come N6: la domanda vera e' se regge a macchina occupata.
    info "ripeto sotto carico (quattro scansioni parallele) …"
    local pid=() i
    for i in 1 2 3 4; do ( while :; do find "$BANCO" -type f >/dev/null 2>&1; done ) & pid+=($!); done
    sleep 1
    local go_c npm_c
    go_c=$( cd "$p" && PATH="$BANCO/finto:$PATH" cronometra_m "$RIP_V" "$GIRI_V" "$BANCO/npz-go" ls )
    npm_c=$( cd "$p" && cronometra_m "$RIP_N" "$GIRI_N" npm run noop )
    for i in "${pid[@]}"; do kill "$i" 2>/dev/null; done; wait 2>/dev/null
    misura "spike Go, sotto carico" "${go_c} ms"
    misura "npm run <vuoto>, sotto carico" "${npm_c} ms"
    misura "sovraccarico Go, sotto carico" "$(echo "scale=1; 100*$go_c/$npm_c" | bc -l)%"
}

# ── il report ────────────────────────────────────────────────────────────────

report() {
    local f="$QUI/report-fase0-go.md"
    {
        echo "# Fase 0 del porting in Go — esiti"
        echo
        echo "- data: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- kernel: \`$(uname -r)\`"
        echo "- go: \`$(go version | awk '{print $3}')\` · npm: \`$(npm --version)\`"
        echo "- banco: \`$BANCO\` ($(df -T "$BANCO" | awk 'NR==2{print $2}'))"
        echo
        echo "## Esiti"
        echo
        echo "| Esito | Verifica | Dettaglio |"
        echo "| --- | --- | --- |"
        local r; for r in "${ESITI[@]}"; do
            IFS='|' read -r e v d <<< "$r"; echo "| $e | $v | $d |"
        done
        echo
        echo "## Misure"
        echo
        echo "| Metrica | Valore |"
        echo "| --- | --- |"
        for r in "${MISURE[@]}"; do
            IFS='|' read -r m v <<< "$r"; echo "| $m | $v |"
        done
        echo
        echo "Riferimento storico, da \`report-fase0.md\`: percorso veloce 12,4 ms,"
        echo "\`npm run\` a vuoto 121,4 ms, sovraccarico 10,2%."
        echo
        echo "## Quel che resta da verificare"
        echo
        if command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
            echo "- nessuna voce."
        else
            echo "- **il binario gira su una glibc vecchia.** Non verificato: su questa"
            echo "  macchina non c'è né podman né docker. Il meccanismo che lo rende vero"
            echo "  è provato — \`file\` dice \`statically linked\` e il binario non ha"
            echo "  interprete dinamico — ma la prova diretta su Debian 12 (glibc 2.36)"
            echo "  manca, e va rifatta prima di pubblicare qualsiasi pacchetto."
        fi
        echo
        echo "## Verdetto"
        echo
        if [ "$FAIL" -eq 0 ]; then
            echo "Criterio di uscita **superato**. Le tre domande del §8 hanno risposta:"
            echo "il percorso veloce sta sotto la soglia, \`syscall.Exec\` è trasparente su"
            echo "codice di uscita, segnali e TTY, e la coda della voce esce prima di"
            echo "\`Exec\` senza affidarsi a un \`defer\` che non verrebbe eseguito."
            echo
            echo "La fase 1 — il nucleo — può cominciare."
        else
            echo "Criterio di uscita **non superato**: $FAIL verifiche fallite."
            echo "Il §8 prescrive di riaprire il confronto a tre prima di procedere."
        fi
    } > "$f"
    sez "report"
    info "scritto in $f"
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    printf '\033[1mbanco della fase 0 — porting in Go\033[0m\n'
    info "banco: $BANCO"

    preflight || { echo; rosso "preflight fallito: mi fermo."; echo; exit 1; }
    [ "${1:-}" = check ] && exit 0

    costruisci || exit 1
    fixture    || exit 1
    stati
    trasparenza
    misure
    report

    sez "riepilogo"
    printf '  %s pass · %s fail\n\n' "$(verde "$PASS")" "$( [ "$FAIL" -gt 0 ] && rosso "$FAIL" || echo "$FAIL" )"
    [ "$FAIL" -eq 0 ]
}

main "$@"
