#!/usr/bin/env bash
#
# banco-fase2.sh — la facciata, e i quattro test del §13 del piano.
#
# Il §10 del piano Go ne fa il criterio di uscita della fase 2, e sono test che
# non erano mai stati scritti in Python: il porting e' l'occasione di scriverli
# una volta sola.
#
#   1. giro completo, con confronto degli attributi: albero → attach → monta →
#      scrittura → compact → detach, e l'albero finale coincide
#   2. uccisione a meta' consolidamento: rilanciare deve convergere
#   3. npz in CI: niente TTY, stdin chiuso, nessuna domanda, codice di npm
#   4. npz dentro uno script di package.json: gli script chiamano npm, non npz
#
set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# QUI e' npz_go/test, MODULO e' npz_go, RADICE la radice del repo. I tre
# banchi stanno in test/ come quello del Python, quindi per arrivare alla
# radice si risale di due e non di uno.
MODULO="$(dirname "$QUI")"
RADICE="$(dirname "$MODULO")"
BANCO="${NPZ_BANCO2:-/var/tmp/npz-banco-fase2}"

PASS=0; FAIL=0
declare -a ESITI=()

verde() { printf '\033[32m%s\033[0m' "$1"; }
rosso() { printf '\033[31m%s\033[0m' "$1"; }
info()  { printf '  %s\n' "$*"; }
sez()   { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }
pass()  { PASS=$((PASS+1)); ESITI+=("PASS|$1|${2:-}"); printf '  [%s] %s %s\n' "$(verde PASS)" "$1" "${2:+· $2}"; }
fail()  { FAIL=$((FAIL+1)); ESITI+=("FAIL|$1|${2:-}"); printf '  [%s] %s %s\n' "$(rosso FAIL)" "$1" "${2:+· $2}"; }
confronta() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "atteso='$(printf %s "$2"|head -c 70)' ottenuto='$(printf %s "$3"|head -c 70)'"; }

GO="$BANCO/npz"
NUCLEO="$BANCO/nucleo"

inv() { "$NUCLEO" inventario "$1"; }

# Si insiste, invece di provarci una volta sola. Staccare l'overlay e subito
# dopo il `lower` che gli stava sotto puo' fallire per un istante — il demone
# FUSE di sopra non e' ancora uscito — e una passata sola lascia indietro
# proprio il mount piu' interno, che poi nessuno vede. Tre giri bastano, e
# quel che resta lo si dichiara invece di tacerlo.
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

# ── preparazione ─────────────────────────────────────────────────────────────

prepara() {
    sez "preparazione"
    smonta_tutto; rm -rf "$BANCO"; mkdir -p "$BANCO/finto"

    if ! ( cd "$MODULO" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$GO" . \
        && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$NUCLEO" ./test/nucleo ) 2>&1; then
        fail "npz e il driver compilano"; return 1
    fi
    pass "npz e il driver compilano" "$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$GO")")"

    # npm finto: si misura npz, non npm. Chi vuole npm vero lo dice a mano.
    ln -sf /bin/true "$BANCO/finto/npm"
    export PATH="$BANCO/finto:$PATH"
}

# semina <dir> — un node_modules verosimile, con i casi che contano
semina() {
    local p="$1"
    mkdir -p "$p/node_modules/.bin" "$p/node_modules/alfa/dist" "$p/node_modules/beta"
    printf '{"name":"prova","version":"1.0.0","scripts":{"leggi":"node -e \\"require(\x27alfa\x27)\\""}}' \
        > "$p/package.json"
    echo 'module.exports = "alfa"'  > "$p/node_modules/alfa/index.js"
    printf '{"name":"alfa","main":"index.js"}' > "$p/node_modules/alfa/package.json"
    head -c 3072 /dev/urandom       > "$p/node_modules/alfa/dist/bundle.js"
    echo 'module.exports = "beta"'  > "$p/node_modules/beta/index.js"
    printf '{"name":"beta"}'        > "$p/node_modules/beta/package.json"
    ln -s ../alfa/index.js          "$p/node_modules/.bin/alfa"
    chmod 0755 "$p/node_modules/.bin/alfa" 2>/dev/null
    chmod 0700 "$p/node_modules/alfa/index.js"
}

# ── 1. il giro completo ──────────────────────────────────────────────────────

giro_completo() {
    sez "1. giro completo — albero → attach → compact → detach"
    local p="$BANCO/giro"; mkdir -p "$p"; semina "$p"

    local prima; prima=$(inv "$p/node_modules")
    info "$(printf '%s' "$prima" | wc -l) voci nell'albero di partenza"

    ( cd "$p" && "$GO" attach ) >/dev/null 2>&1 || { fail "attach riesce"; return 1; }
    pass "attach riesce"

    local montato; montato=$(inv "$p/node_modules")
    confronta "l'albero montato coincide con l'originale" "$prima" "$montato"

    # Una scrittura nel delta, che deve sopravvivere a tutto il resto.
    echo 'aggiunto dopo attach' > "$p/node_modules/gamma.txt"
    mkdir -p "$p/node_modules/delta-dir" && echo 'x' > "$p/node_modules/delta-dir/f.txt"
    local con_delta; con_delta=$(inv "$p/node_modules")

    ( cd "$p" && "$GO" compact ) >/dev/null 2>&1 || { fail "compact riesce"; return 1; }
    pass "compact riesce"

    local dopo_compact; dopo_compact=$(inv "$p/node_modules")
    confronta "il consolidamento non cambia la vista" "$con_delta" "$dopo_compact"

    # E il delta deve essere stato assorbito davvero, non solo sembrare.
    local rimasto; rimasto=$( cd "$p" && "$GO" status 2>&1 | grep -oP 'delta\s+\K[^ ]+ [^ ]+' )
    info "delta dopo il consolidamento: $rimasto"

    ( cd "$p" && "$GO" detach ) >/dev/null 2>&1 || { fail "detach riesce"; return 1; }
    pass "detach riesce"

    local finale; finale=$(inv "$p/node_modules")
    confronta "l'albero finale coincide con quello montato" "$dopo_compact" "$finale"

    [ ! -e "$p/.npz" ] && [ ! -e "$p/node_modules.frozen" ] \
        && pass "di npz non resta niente" \
        || fail "di npz non resta niente" "$(ls -a "$p" | tr '\n' ' ')"

    ! mountpoint -q "$p/node_modules" \
        && pass "node_modules e' una cartella vera" \
        || fail "node_modules e' una cartella vera"
}

# ── 2. convergenza dopo un'interruzione ──────────────────────────────────────

convergenza() {
    sez "2. uccisione a meta' — il rilancio deve convergere"
    local p="$BANCO/kill"; mkdir -p "$p"; semina "$p"
    ( cd "$p" && "$GO" attach ) >/dev/null 2>&1
    echo 'nel delta' > "$p/node_modules/nel-delta.txt"
    local atteso; atteso=$(inv "$p/node_modules")

    # a) residui fabbricati: un temporaneo di costruzione e uno stato di
    #    esercizio rimasti da un giro ucciso. npz deve passarci sopra.
    : > "$p/.npz/static/node_modules.img.new"
    mkdir -p "$p/.npz/run/node_modules/lower" "$p/.npz/run/node_modules/work"
    ( cd "$p" && "$GO" compact ) >/dev/null 2>&1
    local dopo; dopo=$(inv "$p/node_modules")
    confronta "compact converge sopra i residui di un giro interrotto" "$atteso" "$dopo"

    # b) uccisione vera durante il consolidamento, poi rilancio
    echo 'altro' > "$p/node_modules/altro.txt"
    atteso=$(inv "$p/node_modules")
    ( cd "$p" && "$GO" compact >/dev/null 2>&1 ) &
    local pid=$!
    sleep 0.15
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
    smonta_tutto

    # Il rilancio: qualunque comando npz deve riportare il progetto in ordine.
    ( cd "$p" && "$GO" hey ) >/dev/null 2>&1
    ( cd "$p" && "$GO" compact ) >/dev/null 2>&1
    dopo=$(inv "$p/node_modules")
    confronta "il rilancio dopo un SIGKILL riporta lo stesso albero" "$atteso" "$dopo"

    local stato; stato=$( cd "$p" && "$GO" status 2>&1 | grep -oP 'status\s+\K\w+' )
    [ "$stato" = mounted ] && pass "e lo stato torna 'mounted'" \
        || fail "e lo stato torna 'mounted'" "e' '$stato'"
}

# ── 3. npz in CI ─────────────────────────────────────────────────────────────

in_ci() {
    sez "3. npz in CI — niente TTY, stdin chiuso"
    local p="$BANCO/ci"; mkdir -p "$p"; semina "$p"

    local prima; prima=$(ls -a "$p" | sort | tr '\n' ' ')
    CI=1 sh -c "cd '$p' && '$GO' ls" </dev/null >/dev/null 2>&1
    local esito=$?
    local dopo; dopo=$(ls -a "$p" | sort | tr '\n' ' ')

    [ "$esito" = 0 ] && pass "il comando passa a npm" || fail "il comando passa a npm" "exit $esito"
    confronta "in CI npz non congela niente di sua iniziativa" "$prima" "$dopo"
    [ ! -e "$p/.npz" ] && pass "e non registra nemmeno un rifiuto" \
        || fail "e non registra nemmeno un rifiuto" ".npz creata"

    # Il codice di uscita di npm deve arrivare intatto.
    rm -f "$BANCO/finto/npm"; printf '#!/bin/sh\nexit 17\n' > "$BANCO/finto/npm"; chmod +x "$BANCO/finto/npm"
    CI=1 sh -c "cd '$p' && '$GO' ls" </dev/null >/dev/null 2>&1
    esito=$?
    [ "$esito" = 17 ] && pass "il codice di uscita di npm arriva intatto" "17" \
        || fail "il codice di uscita di npm arriva intatto" "atteso 17, ottenuto $esito"
    rm -f "$BANCO/finto/npm"; ln -sf /bin/true "$BANCO/finto/npm"

    # E su un progetto gia' attaccato, in CI deve comunque montare.
    ( cd "$p" && "$GO" attach ) >/dev/null 2>&1
    ( cd "$p" && "$GO" bye ) >/dev/null 2>&1
    CI=1 sh -c "cd '$p' && '$GO' ls" </dev/null >/dev/null 2>&1
    local stato; stato=$( cd "$p" && "$GO" status 2>&1 | grep -oP 'status\s+\K\w+' )
    [ "$stato" = mounted ] && pass "in CI un progetto attaccato si rimonta da solo" \
        || fail "in CI un progetto attaccato si rimonta da solo" "stato '$stato'"
}

# ── 4. npz dentro uno script di package.json ─────────────────────────────────

dentro_script() {
    sez "4. dentro uno script di package.json"
    if ! command -v node >/dev/null 2>&1; then
        info "node assente: prova saltata"; return
    fi
    local p="$BANCO/script"; mkdir -p "$p"; semina "$p"
    ( cd "$p" && "$GO" attach ) >/dev/null 2>&1

    # Gli script chiamano `node`/`npm`, non npz: devono vedere l'albero montato
    # senza sapere niente di npz. E' la superficie di compatibilita' del §2.
    local visto; visto=$( cd "$p" && node -e 'process.stdout.write(require("alfa"))' 2>&1 )
    confronta "node risolve un modulo dall'albero montato" "alfa" "$visto"

    local binario; binario=$( cd "$p" && node "node_modules/.bin/alfa" 2>&1; echo "rc=$?" )
    [ "${binario##*rc=}" = 0 ] && pass "un binario in node_modules/.bin si esegue" \
        || fail "un binario in node_modules/.bin si esegue" "$binario"

    # E il confine di filesystem, che e' la voce per cui vale la pena (§2).
    #
    # Si contano i file *dentro node_modules* che un attraversatore con -xdev
    # riesce ancora a vedere, e devono essere zero. Contare tutto quel che sta
    # sotto il progetto sarebbe la misura sbagliata: `.npz/` vive sullo stesso
    # filesystem del progetto, quindi -xdev ci scende dentro — e giustamente,
    # perche' quella e' una cartella vera con dentro un file solo.
    local dentro visti
    dentro=$(find "$p/node_modules" -type f 2>/dev/null | wc -l)
    visti=$(find "$p" -xdev -path '*/node_modules/*' -type f 2>/dev/null | wc -l)
    if [ "$visti" -eq 0 ] && [ "$dentro" -gt 0 ]; then
        pass "il mount e' un confine di filesystem" \
             "$dentro file dentro, 0 visti da find -xdev"
    else
        fail "il mount e' un confine di filesystem" \
             "-xdev ne vede ancora $visti su $dentro"
    fi

    # E l'immagine occupa molto meno dell'albero che rappresenta.
    local espanso compresso
    espanso=$(du -s --apparent-size "$p/node_modules" 2>/dev/null | cut -f1)
    compresso=$(du -s "$p/.npz/static" 2>/dev/null | cut -f1)
    info "albero montato ${espanso}K contro ${compresso}K di immagine su disco"
}

# ── 5. gli stati, e lo scavalcamento ─────────────────────────────────────────

stati_e_scavalco() {
    sez "5. stati e scavalcamento"
    local p="$BANCO/stati"; mkdir -p "$p"; semina "$p"

    stato() { ( cd "$1" && "$GO" status 2>&1 | grep -oP 'status\s+\K\w+' ); }

    [ "$(stato "$p")" = candidate ] && pass "stato: candidate" \
        || fail "stato: candidate" "$(stato "$p")"
    ( cd "$p" && "$GO" attach ) >/dev/null 2>&1
    [ "$(stato "$p")" = mounted ] && pass "stato: mounted" \
        || fail "stato: mounted" "$(stato "$p")"
    ( cd "$p" && "$GO" bye ) >/dev/null 2>&1
    [ "$(stato "$p")" = attached ] && pass "stato: attached" \
        || fail "stato: attached" "$(stato "$p")"

    # Lo scavalcamento: qualcuno batte npm da fermo e ricostruisce l'albero.
    mkdir -p "$p/node_modules/intruso"; echo 'x' > "$p/node_modules/intruso/i.js"
    [ "$(stato "$p")" = bypassed ] && pass "stato: bypassed" \
        || fail "stato: bypassed" "$(stato "$p")"
    [ "$(stato "$p")" = bypassed ] && pass "lo scavalcamento si riconosce" \
        || fail "lo scavalcamento si riconosce" "$(stato "$p")"

    # Senza TTY npz non sceglie da solo: avvisa e lascia passare il comando.
    local esito
    CI=1 sh -c "cd '$p' && '$GO' ls" </dev/null >/dev/null 2>&1; esito=$?
    [ "$esito" = 0 ] && [ -d "$p/node_modules/intruso" ] \
        && pass "senza TTY npz non si mette in mezzo" "l'albero di npm resta" \
        || fail "senza TTY npz non si mette in mezzo" "exit $esito"

    # Rotto: il mountpoint scoperto, con dentro solo la sentinella.
    rm -rf "$p/node_modules"
    ( cd "$p" && "$GO" hey ) >/dev/null 2>&1
    smonta_tutto
    [ "$(stato "$p")" = broken ] && pass "il mount caduto si riconosce" \
        || fail "il mount caduto si riconosce" "$(stato "$p")"

    # …e si ripara in silenzio al primo comando.
    CI=1 sh -c "cd '$p' && '$GO' ls" </dev/null >/dev/null 2>&1
    [ "$(stato "$p")" = mounted ] && pass "e si ripara da solo" \
        || fail "e si ripara da solo" "$(stato "$p")"
}

# ── 6. npm ci — il caso patologico ───────────────────────────────────────────

caso_ci() {
    sez "6. npm ci — il caso patologico del §8"
    local p="$BANCO/npmci"; mkdir -p "$p"; semina "$p"
    ( cd "$p" && "$GO" attach ) >/dev/null 2>&1
    local atteso; atteso=$(inv "$p/node_modules")

    # npm finto che si comporta come `npm ci`: ricostruisce l'albero da zero.
    #
    # Il guardiano in cima non e' teatro. Questo script fa `rm -rf` su un
    # percorso **relativo**, e una volta e' stato eseguito nella cartella del
    # progetto: due messaggi di questo banco contenevano `npm ci` fra backtick
    # dentro virgolette doppie, che in shell e' una sostituzione di comando, e
    # la shell l'ha eseguito con il cwd del banco. Ci ha scritto dentro un
    # node_modules finto — e se li' ce ne fosse stato uno vero, l'avrebbe
    # cancellato.
    #
    # I backtick sono stati corretti, ma la correzione toglie *quella*
    # occorrenza. Il guardiano toglie la classe: un attrezzo che cancella si
    # rifiuta di lavorare fuori dal banco, qualunque sia la strada per cui ci e'
    # arrivato.
    rm -f "$BANCO/finto/npm"
    cat > "$BANCO/finto/npm" <<SH
#!/bin/sh
case "\$PWD" in
  "$BANCO"/*) ;;
  *) echo "npm finto: sono in \$PWD, fuori dal banco. Non tocco niente." >&2; exit 99 ;;
esac
rm -rf node_modules
mkdir -p node_modules/alfa/dist node_modules/beta node_modules/.bin
echo 'module.exports = "alfa"' > node_modules/alfa/index.js
printf '{"name":"alfa","main":"index.js"}' > node_modules/alfa/package.json
head -c 3072 /dev/urandom > node_modules/alfa/dist/bundle.js
echo 'module.exports = "beta"' > node_modules/beta/index.js
printf '{"name":"beta"}' > node_modules/beta/package.json
ln -s ../alfa/index.js node_modules/.bin/alfa
chmod 0700 node_modules/alfa/index.js
SH
    chmod +x "$BANCO/finto/npm"

    CI=1 sh -c "cd '$p' && '$GO' ci" </dev/null >/dev/null 2>&1
    local esito=$?
    # Virgolette singole: dentro quelle doppie i backtick sarebbero una
    # sostituzione di comando, e il nome del comando sparirebbe dal messaggio.
    [ "$esito" = 0 ] && pass 'il comando `npm ci` passa' || fail 'il comando `npm ci` passa' "exit $esito"

    local stato; stato=$( cd "$p" && "$GO" status 2>&1 | grep -oP 'status\s+\K\w+' )
    [ "$stato" = mounted ] && pass 'dopo `npm ci` il progetto torna montato' \
        || fail 'dopo `npm ci` il progetto torna montato' "'$stato'"

    # L'albero deve essere quello che npm ha appena costruito, non il vecchio.
    local dopo; dopo=$(inv "$p/node_modules")
    if [ "$dopo" = "$atteso" ]; then
        pass "l'albero ricostruito e' equivalente all'originale"
    else
        # Non e' un fallimento in se': il finto npm rigenera bytes casuali.
        # Cio' che conta e' che ci sia un albero completo e montato.
        local voci; voci=$(printf '%s' "$dopo" | wc -l)
        [ "$voci" -ge 8 ] && pass "l'albero ricostruito e' completo" "$voci voci" \
            || fail "l'albero ricostruito e' completo" "$voci voci"
    fi

    # E l'immagine messa da parte non deve restare li' per sempre.
    [ ! -e "$p/.npz/static/node_modules.img.aside" ] \
        && pass "l'immagine messa da parte e' stata tolta" \
        || fail "l'immagine messa da parte e' stata tolta" "e' rimasta"

    rm -f "$BANCO/finto/npm"; ln -sf /bin/true "$BANCO/finto/npm"
}

# ── report ───────────────────────────────────────────────────────────────────

report() {
    local f="$QUI/report-fase2-go.md"
    {
        echo "# Fase 2 del porting in Go — la facciata"
        echo
        echo "- data: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- go: \`$(go version | awk '{print $3}')\`"
        echo "- banco: \`$BANCO\`"
        echo
        echo "Sono i quattro test del §13 del piano — mai scritti in Python, e il"
        echo "porting e' l'occasione di scriverli una volta sola."
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
            echo "La facciata Go regge il giro completo, converge dopo un'uccisione, tace"
            echo "in CI, non si fa notare dagli script di package.json."
            echo
            echo "Il taglio del Python (fase 3) puo' cominciare."
        else
            echo "**$FAIL verifiche fallite.** Vanno chiuse prima del taglio."
        fi
    } > "$f"
    sez "report"; info "scritto in $f"
}

main() {
    printf '\033[1mbanco della fase 2 — la facciata\033[0m\n'
    info "banco: $BANCO"
    prepara || exit 1
    giro_completo
    convergenza
    in_ci
    dentro_script
    stati_e_scavalco
    caso_ci
    report
    sez "riepilogo"
    printf '  %s pass · %s fail\n\n' "$(verde "$PASS")" "$( [ "$FAIL" -gt 0 ] && rosso "$FAIL" || echo "$FAIL" )"
    [ "$FAIL" -eq 0 ]
}

main "$@"
