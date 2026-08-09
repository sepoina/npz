#!/usr/bin/env bash
#
# fase0.sh — banco di prova per gli scenari N1..N8 di npz.
#
# Non e' codice di prodotto: e' uno script da buttare via, il cui unico scopo e'
# produrre risposte si'/no e una tabella di numeri prima che si scriva una riga
# di npz. Ogni test registra un esito (PASS / FAIL / SKIP) e, dove ha senso,
# delle misure. Il report finale e' un file markdown.
#
# NON opera mai sul disco di lavoro: quello e' NTFS via ntfs-3g, non conserva i
# permessi POSIX e non puo' reggere un upperdir di overlayfs. Il banco vive in
# /var/tmp (ext4) — che sopravvive al riavvio, cosa che serve a N8.
#
# Non serve root: tutto lo stack e' erofsfuse + fuse-overlayfs in user space.
#
# Uso:
#   ./fase0.sh check                 # solo preflight
#   ./fase0.sh fixture               # costruisce il node_modules di prova
#   ./fase0.sh all
#   ./fase0.sh n1 n2 n4
#   ./fase0.sh n5 --su ~/prog/node_modules --for 3600 --intervallo 60
#                                    # campionatore: NON serve il mount, punta
#                                    # a un progetto vero che stai usando
#   ./fase0.sh n8 --arm              # poi si riavvia, poi:  ./fase0.sh n8
#
# Scenari:
#   check  preflight
#   n1     npm ci e npm install: sullo stack contro il nativo      [il numero che decide]
#   n2     crescita del delta a ogni install incrementale
#   n3     carico di lettura (resolve storm, tsc, vite build)
#   n4     consolidamento su un node_modules vero
#   n5     chi tiene la cartella, campionato nel tempo             [l'altro numero che decide]
#   n6     costo del percorso veloce, a riposo e sotto carico
#   n7     inotify e watcher attraverso fuse-overlayfs
#   n8     spegnimento sporco: cosa resta         (--arm, riavvio, poi n8)
#
# Opzioni:
#   --banco DIR      dove vive il banco        (default /var/tmp/npz-banco)
#   --fixture DIR    usa questo node_modules invece di costruirlo
#   --giri N         ripetizioni delle misure di tempo   (default 3)
#   --for SECONDI    durata del campionatore di N5       (default 900)
#   --intervallo S   intervallo fra i campioni di N5     (default 20)
#   --tieni          non cancellare il banco a fine corsa
#   --report FILE    percorso del report markdown
#

set -uo pipefail   # niente -e: i test devono poter fallire senza uccidere lo script

# Sotto locale italiano printf rifiuta i decimali col punto. E' gia' costato un
# giro intero di misure nella fase 1 di freeze: cfr. taccuino, voce 9.
export LC_NUMERIC=C

QUI="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BANCO="/var/tmp/npz-banco"
FIXTURE=""
GIRI=3
DURATA=900
INTERVALLO=20
TIENI=0
REPORT=""
SCENARI=()
OSSERVA=()

# ── uscita a video ───────────────────────────────────────────────────────────

C_OK=$'\033[42;30m'; C_NO=$'\033[41;37m'; C_SKIP=$'\033[43;30m'
C_HDR=$'\033[1m';    C_DIM=$'\033[2m';    C_RST=$'\033[0m'
[ -t 1 ] || { C_OK=; C_NO=; C_SKIP=; C_HDR=; C_DIM=; C_RST=; }

CUR=""
RESULTS=()
MEASURES=()

section() { CUR="$1"; printf '\n%s══ %s ══%s\n' "$C_HDR" "$2" "$C_RST"; }
info()    { printf '   %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
pass()    { printf '   %s PASS %s %s\n' "$C_OK" "$C_RST" "$1"; RESULTS+=("PASS|$CUR|$1|${2:-}"); }
fail()    { printf '   %s FAIL %s %s%s\n' "$C_NO" "$C_RST" "$1" "${2:+ — $2}"; RESULTS+=("FAIL|$CUR|$1|${2:-}"); }
skip()    { printf '   %s SKIP %s %s%s\n' "$C_SKIP" "$C_RST" "$1" "${2:+ — $2}"; RESULTS+=("SKIP|$CUR|$1|${2:-}"); }
measure() { printf '   %s·%s %-46s %s\n' "$C_DIM" "$C_RST" "$1" "$2"; MEASURES+=("$CUR|$1|$2"); }
die()     { printf '%s errore: %s%s\n' "$C_NO" "$*" "$C_RST" >&2; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }

# ── misura ───────────────────────────────────────────────────────────────────

adesso_ns() { date +%s%N; }
secondi()   { echo "scale=2; ($2 - $1) / 1000000000" | bc -l; }
umano()     { numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}"; }
byte_di()   { local v; v=$(du -s --block-size=1 "$1" 2>/dev/null | cut -f1); echo "${v:-0}"; }
voci_di()   { find "$1" 2>/dev/null | wc -l; }

# La mediana di N giri, non la media: un singolo giro sfortunato (il compattatore
# di ext4, un altro processo) sposta la media e non la mediana.
mediana() {
    printf '%s\n' "$@" | sort -g | awk '{a[NR]=$1} END{ if(NR%2) print a[(NR+1)/2]; else printf "%.2f\n",(a[NR/2]+a[NR/2+1])/2 }'
}

# ── i mount, e la loro pulizia ───────────────────────────────────────────────

MONTATI=()
traccia() { MONTATI+=("$1"); }

smonta_tutto() {
    # In ordine inverso: la vista prima del lower che le sta sotto.
    local i
    for (( i=${#MONTATI[@]}-1; i>=0; i-- )); do
        mountpoint -q "${MONTATI[$i]}" 2>/dev/null || continue
        fusermount3 -u "${MONTATI[$i]}" 2>/dev/null || umount "${MONTATI[$i]}" 2>/dev/null
    done
    MONTATI=()
}

pulizia() {
    local esito=$?
    # Con N8 armato non si smonta NIENTE: il mount lasciato in piedi e' l'oggetto
    # dell'esperimento. Senza questa guardia la pulizia disfa l'--arm, e la prova
    # dice "armato" mentre non lo e'.
    if [ "${N8_ARMATO:-0}" = 1 ]; then
        exit $esito
    fi
    smonta_tutto
    # Qualunque cosa sia rimasta appesa dentro il banco, va staccata comunque.
    findmnt -rn -o TARGET 2>/dev/null | grep -F "$BANCO" | sort -r | while read -r p; do
        fusermount3 -u "$p" 2>/dev/null || umount -l "$p" 2>/dev/null
    done
    [ "$TIENI" = 0 ] && rm -rf "$BANCO/prova" "$BANCO/nativo" 2>/dev/null
    exit $esito
}
trap pulizia EXIT INT TERM

# ── lo stack, come lo monterebbe npz ─────────────────────────────────────────
#
# Riproduce la struttura di .npz/ del piano, sezione 5. I percorsi passati a
# fuse-overlayfs sono RELATIVI dopo un chdir: misurato che con i due punti nel
# percorso assoluto fallisce, e i progetti degli utenti hanno percorsi che non
# controlliamo.

congela() {                       # congela <progetto>
    local p="$1"
    mkdir -p "$p/.npz/static" "$p/.npz/dynamic" "$p/.npz/work" "$p/.npz/run"
    mkfs.erofs -zlz4hc "$p/.npz/static/node_modules.img" "$p/node_modules" >/dev/null 2>&1 \
        || { fail "mkfs.erofs sulla fixture"; return 1; }
    rm -rf "$p/node_modules"
}

monta() {                         # monta <progetto>
    local p="$1"
    mkdir -p "$p/node_modules" "$p/.npz/run/lower" \
             "$p/.npz/dynamic/node_modules" "$p/.npz/work/node_modules"
    erofsfuse "$p/.npz/static/node_modules.img" "$p/.npz/run/lower" >/dev/null 2>&1 \
        || { fail "erofsfuse"; return 1; }
    traccia "$p/.npz/run/lower"
    ( cd "$p/.npz" && fuse-overlayfs -o \
        "lowerdir=run/lower,upperdir=dynamic/node_modules,workdir=work/node_modules" \
        "../node_modules" ) >/dev/null 2>&1 \
        || { fail "fuse-overlayfs"; fusermount3 -u "$p/.npz/run/lower"; return 1; }
    traccia "$p/node_modules"
}

smonta() {                        # smonta <progetto>
    local p="$1"
    mountpoint -q "$p/node_modules" 2>/dev/null && fusermount3 -u "$p/node_modules" 2>/dev/null
    mountpoint -q "$p/.npz/run/lower" 2>/dev/null && fusermount3 -u "$p/.npz/run/lower" 2>/dev/null
    return 0
}

svuota_delta() {
    rm -rf "$1/.npz/dynamic/node_modules" "$1/.npz/work/node_modules"
    mkdir -p "$1/.npz/dynamic/node_modules" "$1/.npz/work/node_modules"
}

delta_byte()  { byte_di "$1/.npz/dynamic/node_modules"; }
delta_voci()  { echo $(( $(voci_di "$1/.npz/dynamic/node_modules") - 1 )); }

# Rimette il progetto di prova in uno stato noto: node_modules congelato in
# immagine, delta vuoto, non montato.
prepara_prova() {
    smonta "$BANCO/prova"
    rm -rf "$BANCO/prova"
    mkdir -p "$BANCO/prova"
    cp "$BANCO/fixture/package.json" "$BANCO/fixture/package-lock.json" "$BANCO/prova/" 2>/dev/null
    cp -a "$BANCO/fixture/node_modules" "$BANCO/prova/node_modules"
    congela "$BANCO/prova" || return 1
}

prepara_nativo() {
    rm -rf "$BANCO/nativo"
    mkdir -p "$BANCO/nativo"
    cp "$BANCO/fixture/package.json" "$BANCO/fixture/package-lock.json" "$BANCO/nativo/" 2>/dev/null
    cp -a "$BANCO/fixture/node_modules" "$BANCO/nativo/node_modules"
}

NPM_Q=(--no-audit --no-fund --prefer-offline --loglevel=error)

# ── check ────────────────────────────────────────────────────────────────────

scenario_check() {
    section CHECK "preflight"
    local mancanti=0
    for t in mkfs.erofs erofsfuse fuse-overlayfs fusermount3 npm node bc numfmt findmnt mountpoint; do
        if have "$t"; then pass "$t presente"; else fail "$t presente"; mancanti=1; fi
    done
    [ "$mancanti" = 1 ] && die "mancano strumenti indispensabili"

    mkdir -p "$BANCO"
    local tipo; tipo=$(findmnt -n -o FSTYPE -T "$BANCO" 2>/dev/null)
    if [ "$tipo" = ext4 ] || [ "$tipo" = xfs ] || [ "$tipo" = btrfs ]; then
        pass "il banco vive su un filesystem POSIX" "$tipo"
    else
        fail "il banco vive su un filesystem POSIX" "$tipo — un upperdir di overlayfs non ci sta"
        die "sposta il banco con --banco"
    fi

    # Il controllo che freeze fa in idoneita(): i permessi devono sopravvivere.
    local pr="$BANCO/.prova-permessi"; mkdir -p "$pr"; echo x > "$pr/f"; chmod 700 "$pr/f"
    if [ "$(stat -c %a "$pr/f")" = 700 ]; then pass "i permessi POSIX si conservano"
    else fail "i permessi POSIX si conservano" "chmod 700 riletto come $(stat -c %a "$pr/f")"; fi
    rm -rf "$pr"

    local liberi; liberi=$(df -kP "$BANCO" | awk 'NR==2{print $4}')
    if [ "$liberi" -gt 4000000 ]; then pass "spazio sufficiente" "$(( liberi / 1024 / 1024 )) GiB liberi"
    else fail "spazio sufficiente" "solo $(( liberi / 1024 ))MiB"; fi

    if timeout 15 npm ping >/dev/null 2>&1; then pass "registry npm raggiungibile"
    else skip "registry npm raggiungibile" "si andra' di sola cache"; fi

    measure "npm" "$(npm --version 2>/dev/null)"
    measure "node" "$(node --version 2>/dev/null)"
    measure "kernel" "$(uname -r)"
    measure "banco" "$BANCO ($tipo)"
}

# ── fixture ──────────────────────────────────────────────────────────────────

scenario_fixture() {
    section FIXTURE "il node_modules di prova"

    if [ -n "$FIXTURE" ]; then
        [ -d "$FIXTURE" ] || die "la fixture indicata non esiste: $FIXTURE"
        rm -rf "$BANCO/fixture"; mkdir -p "$BANCO/fixture"
        cp -a "$FIXTURE" "$BANCO/fixture/node_modules"
        [ -f "$FIXTURE/../package.json" ] && cp "$FIXTURE/../package.json" "$BANCO/fixture/"
        [ -f "$FIXTURE/../package-lock.json" ] && cp "$FIXTURE/../package-lock.json" "$BANCO/fixture/"
        info "fixture presa da $FIXTURE"
    elif [ -d "$BANCO/fixture/node_modules" ]; then
        info "fixture gia' presente, la riuso (cancella $BANCO/fixture per rifarla)"
    else
        mkdir -p "$BANCO/fixture"
        # Un progetto realistico e riproducibile: e' il carico che npz deve reggere.
        cat > "$BANCO/fixture/package.json" <<'JSON'
{
  "name": "npz-fixture",
  "private": true,
  "version": "1.0.0",
  "scripts": { "build": "vite build", "typecheck": "tsc --noEmit" },
  "dependencies": {
    "next": "^15.1.3",
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@babel/core": "^7.26.0",
    "@babel/preset-env": "^7.26.0",
    "@babel/preset-react": "^7.26.3",
    "@testing-library/jest-dom": "^6.6.3",
    "@testing-library/react": "^16.1.0",
    "@types/node": "^22.10.2",
    "@types/react": "^18.3.12",
    "@types/react-dom": "^18.3.1",
    "@typescript-eslint/eslint-plugin": "^8.18.2",
    "@typescript-eslint/parser": "^8.18.2",
    "@vitejs/plugin-react": "^4.3.4",
    "autoprefixer": "^10.4.20",
    "babel-loader": "^9.2.1",
    "eslint": "^8.57.1",
    "eslint-plugin-react": "^7.37.3",
    "jest": "^29.7.0",
    "jest-environment-jsdom": "^29.7.0",
    "postcss": "^8.4.49",
    "prettier": "^3.4.2",
    "sass": "^1.83.0",
    "storybook": "^8.4.7",
    "tailwindcss": "^3.4.17",
    "typescript": "^5.7.2",
    "vite": "^6.0.5",
    "vitest": "^2.1.8",
    "webpack": "^5.97.1",
    "webpack-cli": "^6.0.1"
  }
}
JSON
        info "npm install della fixture (puo' volerci un minuto) …"
        ( cd "$BANCO/fixture" && npm install "${NPM_Q[@]}" ) 2>&1 | tail -3 | sed 's/^/   /'
    fi

    if [ ! -d "$BANCO/fixture/node_modules" ]; then
        fail "fixture costruita"; die "senza fixture non si misura niente"
    fi
    local n b; n=$(voci_di "$BANCO/fixture/node_modules"); b=$(byte_di "$BANCO/fixture/node_modules")
    pass "fixture costruita"
    measure "fixture: voci (file + directory)" "$n"
    measure "fixture: occupazione su disco" "$(umano "$b")"

    # Un po' di sorgente, che serve a n3.
    mkdir -p "$BANCO/fixture/src"
    cat > "$BANCO/fixture/src/main.tsx" <<'TSX'
import React from "react";
import { createRoot } from "react-dom/client";
const App = () => <div>ciao</div>;
createRoot(document.getElementById("root")!).render(<App />);
TSX
    cat > "$BANCO/fixture/index.html" <<'HTML'
<!doctype html><html><body><div id="root"></div>
<script type="module" src="/src/main.tsx"></script></body></html>
HTML
    cat > "$BANCO/fixture/tsconfig.json" <<'JSON'
{ "compilerOptions": { "target": "ES2020", "module": "ESNext", "jsx": "react-jsx",
  "moduleResolution": "bundler", "strict": true, "noEmit": true, "skipLibCheck": true },
  "include": ["src"] }
JSON

    if [ "$n" -lt 20000 ]; then
        info "nota: $n voci. Il piano parla di alberi da 45.000; le conclusioni"
        info "      su questa scala vanno rilette prima di generalizzarle."
    fi
}

richiedi_fixture() {
    [ -d "$BANCO/fixture/node_modules" ] || { skip "$1" "manca la fixture: lancia  $0 fixture"; return 1; }
    return 0
}

# ── N1 — il numero che decide ────────────────────────────────────────────────

scenario_n1() {
    section N1 "npm sullo stack contro il nativo"
    richiedi_fixture "N1" || return

    # ---- npm install idempotente (l'albero c'e' gia' e non cambia nulla) ----
    local tn=() ts=() i t0 t1
    prepara_nativo
    for i in $(seq "$GIRI"); do
        t0=$(adesso_ns); ( cd "$BANCO/nativo" && npm install "${NPM_Q[@]}" ) >/dev/null 2>&1; t1=$(adesso_ns)
        tn+=("$(secondi "$t0" "$t1")")
    done
    local mn; mn=$(mediana "${tn[@]}")

    prepara_prova || return
    monta "$BANCO/prova" || return
    for i in $(seq "$GIRI"); do
        t0=$(adesso_ns); ( cd "$BANCO/prova" && npm install "${NPM_Q[@]}" ) >/dev/null 2>&1; t1=$(adesso_ns)
        ts+=("$(secondi "$t0" "$t1")")
    done
    local ms; ms=$(mediana "${ts[@]}")
    local db dv; db=$(delta_byte "$BANCO/prova"); dv=$(delta_voci "$BANCO/prova")

    measure "install idempotente: nativo" "${mn} s"
    measure "install idempotente: sullo stack" "${ms} s"
    local rap; rap=$(echo "scale=2; $ms / ($mn + 0.001)" | bc -l)
    measure "install idempotente: rapporto" "${rap}×"
    measure "install idempotente: delta prodotto" "$(umano "$db") in $dv voci"
    if (( $(echo "$rap <= 2.0" | bc -l) )); then
        pass "install idempotente entro 2×" "${rap}×"
    else
        fail "install idempotente entro 2×" "${rap}× — oltre il criterio di uscita"
    fi
    smonta "$BANCO/prova"

    # ---- npm ci: il caso che il piano dichiara patologico ----
    tn=(); ts=()
    prepara_nativo
    for i in $(seq "$GIRI"); do
        t0=$(adesso_ns); ( cd "$BANCO/nativo" && npm ci "${NPM_Q[@]}" ) >/dev/null 2>&1; t1=$(adesso_ns)
        tn+=("$(secondi "$t0" "$t1")")
    done
    mn=$(mediana "${tn[@]}")

    prepara_prova || return
    monta "$BANCO/prova" || return
    t0=$(adesso_ns); ( cd "$BANCO/prova" && npm ci "${NPM_Q[@]}" ) >/dev/null 2>&1; t1=$(adesso_ns)
    local uno; uno=$(secondi "$t0" "$t1")
    db=$(delta_byte "$BANCO/prova"); dv=$(delta_voci "$BANCO/prova")
    local ib; ib=$(byte_di "$BANCO/prova/.npz/static/node_modules.img")
    local fb; fb=$(byte_di "$BANCO/fixture/node_modules")

    measure "npm ci: nativo" "${mn} s"
    measure "npm ci: sullo stack" "${uno} s"
    rap=$(echo "scale=2; $uno / ($mn + 0.001)" | bc -l)
    measure "npm ci: rapporto" "${rap}×"
    measure "npm ci: delta prodotto" "$(umano "$db") in $dv voci"
    measure "npm ci: immagine + delta contro albero nativo" \
            "$(umano $(( ib + db ))) contro $(umano "$fb")"

    # La tesi del piano (sezione 8): dopo un npm ci il delta e' una copia piena,
    # l'immagine e' peso morto, e il totale sta peggio del punto di partenza.
    if [ "$(( ib + db ))" -gt "$fb" ]; then
        pass "npm ci peggiora il bilancio: va intercettato" \
             "$(umano $(( ib + db ))) contro $(umano "$fb") del nativo"
    else
        fail "npm ci peggiora il bilancio: va intercettato" \
             "non e' peggiorato — la tesi della sezione 8 va rivista"
    fi
    smonta "$BANCO/prova"
}

# ── N2 — crescita del delta ──────────────────────────────────────────────────

scenario_n2() {
    section N2 "quanto cresce il delta a ogni install"
    richiedi_fixture "N2" || return

    prepara_prova || return
    monta "$BANCO/prova" || return

    local pacchetti=(lodash dayjs nanoid clsx zod uuid ms picocolors debug chalk)
    local prima_b=0 prima_v=0 p b v
    info "delta dopo ogni  npm install <pacchetto>:"
    for p in "${pacchetti[@]}"; do
        ( cd "$BANCO/prova" && npm install "${NPM_Q[@]}" "$p" ) >/dev/null 2>&1
        b=$(delta_byte "$BANCO/prova"); v=$(delta_voci "$BANCO/prova")
        printf '     %-12s  %10s   %6s voci   (+%s, +%s voci)\n' \
            "$p" "$(umano "$b")" "$v" "$(umano $(( b - prima_b )))" "$(( v - prima_v ))"
        prima_b=$b; prima_v=$v
    done

    local ib; ib=$(byte_di "$BANCO/prova/.npz/static/node_modules.img")
    measure "delta dopo 10 install" "$(umano "$prima_b") in $prima_v voci"
    measure "immagine" "$(umano "$ib")"
    local pct; pct=$(echo "scale=1; 100 * $prima_b / ($ib + 1)" | bc -l)
    measure "delta / immagine" "${pct}%"
    measure "crescita media per install" "$(umano $(( prima_b / 10 )))"

    # La soglia proposta dal piano (sezione 9) e' 30% dei byte dell'immagine.
    if (( $(echo "$pct >= 30" | bc -l) )); then
        pass "dieci install superano la soglia del 30%" "${pct}% — la soglia e' raggiungibile"
    else
        pass "dieci install restano sotto il 30%" "${pct}% — la soglia va abbassata o affiancata"
    fi
    smonta "$BANCO/prova"
}

# ── N3 — carico di lettura ───────────────────────────────────────────────────

scenario_n3() {
    section N3 "carico di lettura: stack contro nativo"
    richiedi_fixture "N3" || return

    # Una "resolve storm": lo stesso campione di file, letto in ordine sparso.
    # E' il carico di un bundler, ed e' il caso peggiore per un formato compresso.
    local campione="$BANCO/campione.txt"
    ( cd "$BANCO/fixture/node_modules" && find . -type f -name '*.js' | sort -R --random-source=<(yes) | head -3000 ) > "$campione"
    local quanti; quanti=$(wc -l < "$campione")
    measure "campione della resolve storm" "$quanti file"

    tempesta() {                  # tempesta <dir_node_modules>
        local d="$1" t0 t1
        sync; t0=$(adesso_ns)
        ( cd "$d" && while read -r f; do cat "$f" >/dev/null 2>&1; done < "$campione" )
        t1=$(adesso_ns); secondi "$t0" "$t1"
    }

    prepara_nativo
    local tn=() ts=() i
    for i in $(seq "$GIRI"); do tn+=("$(tempesta "$BANCO/nativo/node_modules")"); done
    local mn; mn=$(mediana "${tn[@]}")

    prepara_prova || return
    monta "$BANCO/prova" || return
    for i in $(seq "$GIRI"); do ts+=("$(tempesta "$BANCO/prova/node_modules")"); done
    local ms; ms=$(mediana "${ts[@]}")

    measure "resolve storm: nativo" "${mn} s"
    measure "resolve storm: sullo stack" "${ms} s"
    local rap; rap=$(echo "scale=2; $ms / ($mn + 0.001)" | bc -l)
    measure "resolve storm: rapporto" "${rap}×"
    if (( $(echo "$rap <= 2.0" | bc -l) )); then
        pass "resolve storm entro 2×" "${rap}×"
    else
        fail "resolve storm entro 2×" "${rap}×"
    fi

    # tsc e vite: i carichi veri, se la fixture li ha.
    local t0 t1
    if [ -x "$BANCO/prova/node_modules/.bin/tsc" ]; then
        cp -a "$BANCO/fixture/src" "$BANCO/fixture/tsconfig.json" "$BANCO/prova/" 2>/dev/null
        cp -a "$BANCO/fixture/src" "$BANCO/fixture/tsconfig.json" "$BANCO/nativo/" 2>/dev/null
        t0=$(adesso_ns); ( cd "$BANCO/nativo" && ./node_modules/.bin/tsc --noEmit ) >/dev/null 2>&1; t1=$(adesso_ns)
        local tsn; tsn=$(secondi "$t0" "$t1")
        t0=$(adesso_ns); ( cd "$BANCO/prova" && ./node_modules/.bin/tsc --noEmit ) >/dev/null 2>&1; t1=$(adesso_ns)
        local tss; tss=$(secondi "$t0" "$t1")
        measure "tsc --noEmit: nativo / stack" "${tsn} s / ${tss} s"
        rap=$(echo "scale=2; $tss / ($tsn + 0.001)" | bc -l)
        measure "tsc --noEmit: rapporto" "${rap}×"
        if (( $(echo "$rap <= 2.0" | bc -l) )); then pass "tsc entro 2×" "${rap}×"
        else fail "tsc entro 2×" "${rap}×"; fi
    else
        skip "tsc" "non presente nella fixture"
    fi

    if [ -x "$BANCO/prova/node_modules/.bin/vite" ]; then
        cp -a "$BANCO/fixture/index.html" "$BANCO/prova/" 2>/dev/null
        cp -a "$BANCO/fixture/index.html" "$BANCO/nativo/" 2>/dev/null
        t0=$(adesso_ns); ( cd "$BANCO/nativo" && ./node_modules/.bin/vite build ) >/dev/null 2>&1; t1=$(adesso_ns)
        local vn; vn=$(secondi "$t0" "$t1")
        t0=$(adesso_ns); ( cd "$BANCO/prova" && ./node_modules/.bin/vite build ) >/dev/null 2>&1; t1=$(adesso_ns)
        local vs; vs=$(secondi "$t0" "$t1")
        measure "vite build: nativo / stack" "${vn} s / ${vs} s"
        rap=$(echo "scale=2; $vs / ($vn + 0.001)" | bc -l)
        measure "vite build: rapporto" "${rap}×"
        if (( $(echo "$rap <= 2.0" | bc -l) )); then pass "vite build entro 2×" "${rap}×"
        else fail "vite build entro 2×" "${rap}×"; fi
        measure "vite build: delta lasciato" "$(umano "$(delta_byte "$BANCO/prova")") in $(delta_voci "$BANCO/prova") voci"
    else
        skip "vite build" "non presente nella fixture"
    fi
    smonta "$BANCO/prova"
}

# ── N4 — consolidamento ──────────────────────────────────────────────────────

scenario_n4() {
    section N4 "consolidamento su un node_modules vero"
    richiedi_fixture "N4" || return

    prepara_prova || return
    monta "$BANCO/prova" || return
    # Un delta realistico: un install incrementale, come dopo un giorno di lavoro.
    ( cd "$BANCO/prova" && npm install "${NPM_Q[@]}" lodash dayjs zod ) >/dev/null 2>&1
    local db dv; db=$(delta_byte "$BANCO/prova"); dv=$(delta_voci "$BANCO/prova")
    measure "delta da assorbire" "$(umano "$db") in $dv voci"

    local p="$BANCO/prova" t0 t1
    local prima; prima=$( cd "$p/node_modules" && find . | sort | md5sum | cut -d' ' -f1 )

    # I passi 3..10 della sezione 9 del piano: senza rotazione, perche' npz
    # possiede l'intera finestra.
    t0=$(adesso_ns)
    smonta "$p"
    mkdir -p "$p/.npz/run/lower" "$p/.npz/run/fusione"
    erofsfuse "$p/.npz/static/node_modules.img" "$p/.npz/run/lower" >/dev/null 2>&1 || { fail "erofsfuse in consolidamento"; return; }
    ( cd "$p/.npz" && fuse-overlayfs -o "lowerdir=dynamic/node_modules:run/lower" "run/fusione" ) >/dev/null 2>&1 \
        || { fail "vista fusa"; fusermount3 -u "$p/.npz/run/lower"; return; }
    mkfs.erofs -zlz4hc "$p/.npz/static/node_modules.nuova" "$p/.npz/run/fusione" >/dev/null 2>&1
    local esito=$?
    local dopo; dopo=$( cd "$p/.npz/run/fusione" && find . | sort | md5sum | cut -d' ' -f1 )
    fusermount3 -u "$p/.npz/run/fusione" 2>/dev/null
    fusermount3 -u "$p/.npz/run/lower" 2>/dev/null
    if [ $esito -eq 0 ]; then
        mv "$p/.npz/static/node_modules.nuova" "$p/.npz/static/node_modules.img"
        svuota_delta "$p"
    fi
    monta "$p" || return
    t1=$(adesso_ns)
    local tc; tc=$(secondi "$t0" "$t1")

    local finale; finale=$( cd "$p/node_modules" && find . | sort | md5sum | cut -d' ' -f1 )
    measure "consolidamento completo (smonta→ricostruisci→rimonta)" "${tc} s"
    measure "immagine dopo il consolidamento" "$(umano "$(byte_di "$p/.npz/static/node_modules.img")")"
    measure "delta dopo il consolidamento" "$(umano "$(delta_byte "$p")")"

    if [ "$prima" = "$dopo" ]; then pass "la vista fusa coincide con quella pre-consolidamento"
    else fail "la vista fusa coincide con quella pre-consolidamento"; fi
    if [ "$prima" = "$finale" ]; then pass "l'albero e' identico dopo il consolidamento"
    else fail "l'albero e' identico dopo il consolidamento" "l'utente vedrebbe cambiare le cose sotto i piedi"; fi
    if [ "$(delta_voci "$p")" -le 1 ]; then pass "il delta e' stato assorbito"
    else fail "il delta e' stato assorbito" "$(delta_voci "$p") voci rimaste"; fi
    smonta "$p"

    # ---- l'alternativa che sembrava ovvia ----
    # Il consolidamento costa molto piu' di un primo freeze, e il sospetto e' che
    # la differenza stia tutta nel leggere l'albero attraverso due strati FUSE.
    # Se fosse cosi', copiarlo prima su ext4 e costruire da li' converrebbe.
    # Il delta va creato SOTTO IL MOUNT. Farlo da smontati scriverebbe l'albero
    # vero dentro il mountpoint, che il mount successivo nasconderebbe: lo stato
    # sarebbe sporco e i due tempi non confrontabili. E' gia' successo.
    monta "$p" || return
    ( cd "$BANCO/prova" && npm install "${NPM_Q[@]}" lodash zod dayjs ) >/dev/null 2>&1
    smonta "$p"
    measure "delta del confronto" "$(umano "$(delta_byte "$p")") in $(delta_voci "$p") voci"
    mkdir -p "$p/.npz/run/lower" "$p/.npz/run/fusione"
    erofsfuse "$p/.npz/static/node_modules.img" "$p/.npz/run/lower" >/dev/null 2>&1 || return
    ( cd "$p/.npz" && fuse-overlayfs -o "lowerdir=dynamic/node_modules:run/lower" "run/fusione" ) >/dev/null 2>&1 || {
        fusermount3 -u "$p/.npz/run/lower"; return; }

    # Chi gira per secondo eredita l'albero gia' caldo in page cache da chi ha
    # girato per primo, e su 588 MiB il vantaggio vale piu' della differenza che
    # si vuole misurare. Si misura quindi nei DUE ordini: se il vincitore cambia,
    # la differenza e' cache e non metodo, e non si conclude niente.
    via_diretta() {
        local t0 t1; t0=$(adesso_ns)
        mkfs.erofs -zlz4hc "$BANCO/a.img" "$p/.npz/run/fusione" >/dev/null 2>&1
        t1=$(adesso_ns); rm -f "$BANCO/a.img"; secondi "$t0" "$t1"
    }
    via_staging() {
        local t0 t1; t0=$(adesso_ns)
        rm -rf "$BANCO/staging"; cp -a "$p/.npz/run/fusione" "$BANCO/staging"
        mkfs.erofs -zlz4hc "$BANCO/b.img" "$BANCO/staging" >/dev/null 2>&1
        t1=$(adesso_ns); rm -rf "$BANCO/staging" "$BANCO/b.img"; secondi "$t0" "$t1"
    }

    local d1 s1 s2 d2
    d1=$(via_diretta); s1=$(via_staging)      # ordine: diretta per prima
    s2=$(via_staging); d2=$(via_diretta)      # ordine: staging per prima
    fusermount3 -u "$p/.npz/run/fusione" 2>/dev/null
    fusermount3 -u "$p/.npz/run/lower" 2>/dev/null

    measure "vista fusa: prima / seconda a girare" "${d1} s / ${d2} s"
    measure "staging su ext4: seconda / prima a girare" "${s1} s / ${s2} s"

    # Vince davvero solo chi vince in entrambi gli ordini.
    local diretta_vince_1 diretta_vince_2
    diretta_vince_1=$(echo "$d1 <= $s1" | bc -l)
    diretta_vince_2=$(echo "$d2 <= $s2" | bc -l)
    if [ "$diretta_vince_1" = "$diretta_vince_2" ]; then
        if [ "$diretta_vince_1" = 1 ]; then
            pass "leggere dalla vista fusa conviene, in entrambi gli ordini" \
                 "lo staging paga la copia e non la recupera"
        else
            fail "leggere dalla vista fusa conviene, in entrambi gli ordini" \
                 "lo staging vince in entrambi gli ordini: il consolidamento va riscritto"
        fi
    else
        skip "quale delle due vie convenga" \
             "il vincitore cambia con l'ordine: e' page cache, non metodo. Serve drop_caches (root)"
    fi
}

# ── N5 — chi tiene la cartella ───────────────────────────────────────────────

scenario_n5() {
    section N5 "chi tiene la cartella, campionato nel tempo"

    # Il mount NON serve: processi_attivi() legge /proc/*/cwd|root|fd e confronta
    # percorsi, quindi la domanda si misura identica su una cartella normale. E'
    # cio' che permette di campionare un progetto VERO invece del banco, che e'
    # l'unico modo di ottenere un numero che voglia dire qualcosa.
    local obiettivo
    if [ ${#OSSERVA[@]} -gt 0 ]; then
        obiettivo="${OSSERVA[0]}"
        [ -d "$obiettivo" ] || { skip "N5" "non esiste: $obiettivo"; return; }
    else
        richiedi_fixture "N5" || return
        prepara_prova || return
        monta "$BANCO/prova" || return
        obiettivo="$BANCO/prova/node_modules"
        info "ATTENZIONE: stai campionando il progetto del banco, che nessuno apre."
        info "Per un numero vero:  $0 n5 --su /percorso/di/un/progetto/node_modules"
    fi
    local log="$BANCO/n5-campioni.log"
    : > "$log"

    info "campiono ogni ${INTERVALLO}s per ${DURATA}s su $obiettivo"
    info "tieni aperto l'editor sul progetto, altrimenti misuri il vuoto."

    local fine=$(( $(date +%s) + DURATA )) n=0 occupati=0
    while [ "$(date +%s)" -lt "$fine" ]; do
        local trovati
        trovati=$(python3 - "$obiettivo" <<'PY'
import os, sys
from pathlib import Path
obiettivo = os.path.realpath(sys.argv[1]); prefisso = obiettivo + "/"
fuori = ("erofsfuse", "fuse-overlayfs")
trovati = []
for voce in Path("/proc").iterdir():
    if not voce.name.isdigit():
        continue
    try:
        comm = (voce / "comm").read_text().strip()
    except OSError:
        continue
    if comm in fuori:            # i demoni del mount non contano
        continue
    tocca = False
    for dove in ("cwd", "root"):
        try:
            d = os.readlink(voce / dove)
            if d == obiettivo or d.startswith(prefisso):
                tocca = True
        except OSError:
            pass
    if not tocca:
        try:
            for fd in (voce / "fd").iterdir():
                try:
                    d = os.readlink(fd)
                except OSError:
                    continue
                if d == obiettivo or d.startswith(prefisso):
                    tocca = True
                    break
        except OSError:
            pass
    if tocca:
        trovati.append(comm)
print(",".join(sorted(set(trovati))))
PY
)
        n=$(( n + 1 ))
        [ -n "$trovati" ] && occupati=$(( occupati + 1 ))
        printf '%s\t%s\n' "$(date +%H:%M:%S)" "${trovati:-—}" >> "$log"
        printf '\r   %s campione %d: %s%s%s   ' "$C_DIM" "$n" "${trovati:-libera}" "$C_RST" "        "
        sleep "$INTERVALLO"
    done
    printf '\n'

    local pct; pct=$(echo "scale=1; 100 * $occupati / ($n + 0.001)" | bc -l)
    measure "campioni" "$n in ${DURATA}s"
    measure "campioni con la cartella occupata" "$occupati (${pct}%)"
    measure "chi la teneva" "$(cut -f2 "$log" | tr ',' '\n' | grep -v '^—$' | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s×%s ", $1, $2}')"
    measure "log dei campioni" "$log"

    # Il criterio della sezione 10: se e' quasi sempre occupata, il rifiuto
    # educato non e' una politica, e' un muro.
    if (( $(echo "$pct < 50" | bc -l) )); then
        pass "il rifiuto educato e' praticabile" "occupata nel ${pct}% dei campioni"
    else
        fail "il rifiuto educato e' praticabile" "occupata nel ${pct}% dei campioni — serve lo smontaggio pigro"
    fi
    [ ${#OSSERVA[@]} -eq 0 ] && smonta "$BANCO/prova"
    return 0
}

# ── N6 — percorso veloce ─────────────────────────────────────────────────────

scenario_n6() {
    section N6 "costo del percorso veloce"

    local sim="$BANCO/veloce.py"
    cat > "$sim" <<'PY'
import os, sys
for f in (".npz/static/node_modules.img", "node_modules", "package.json"):
    try: os.stat(f)
    except OSError: pass
os.execvp("true", ["true"] + sys.argv[1:])
PY
    mkdir -p "$BANCO/misura"; printf '{"name":"m","version":"1.0.0","scripts":{"noop":"true"}}' > "$BANCO/misura/package.json"

    cronometra() {                # cronometra <n> <comando…>
        local n="$1"; shift
        local t0 t1; t0=$(adesso_ns)
        local i; for i in $(seq "$n"); do "$@" >/dev/null 2>&1; done
        t1=$(adesso_ns)
        echo "scale=1; ($t1 - $t0) / $n / 1000000" | bc -l
    }

    local a riposo_v riposo_n
    riposo_v=$( cd "$BANCO/misura" && cronometra 30 python3 -SE "$sim" )
    riposo_n=$( cd "$BANCO/misura" && cronometra 20 npm run noop )
    measure "percorso veloce, a riposo" "${riposo_v} ms"
    measure "npm run <vuoto>, a riposo" "${riposo_n} ms"
    measure "sovraccarico, a riposo" "$(echo "scale=1; 100 * $riposo_v / $riposo_n" | bc -l)%"

    # Sotto carico: la domanda vera e' se i 13 ms reggono con la macchina occupata.
    info "ripeto sotto carico (quattro scansioni parallele) …"
    local pid=()
    local i; for i in 1 2 3 4; do ( while :; do find "$BANCO" -type f >/dev/null 2>&1; done ) & pid+=($!); done
    sleep 1
    local carico_v carico_n
    carico_v=$( cd "$BANCO/misura" && cronometra 30 python3 -SE "$sim" )
    carico_n=$( cd "$BANCO/misura" && cronometra 20 npm run noop )
    for i in "${pid[@]}"; do kill "$i" 2>/dev/null; done; wait 2>/dev/null
    measure "percorso veloce, sotto carico" "${carico_v} ms"
    measure "npm run <vuoto>, sotto carico" "${carico_n} ms"
    measure "sovraccarico, sotto carico" "$(echo "scale=1; 100 * $carico_v / $carico_n" | bc -l)%"

    local pct; pct=$(echo "scale=1; 100 * $carico_v / $carico_n" | bc -l)
    if (( $(echo "$pct <= 25" | bc -l) )); then
        pass "il wrapper resta sotto il 25% di npm anche sotto carico" "${pct}%"
    else
        fail "il wrapper resta sotto il 25% di npm anche sotto carico" "${pct}% — il binario diventa urgente"
    fi
}

# ── N7 — watcher ─────────────────────────────────────────────────────────────

scenario_n7() {
    section N7 "inotify e watcher attraverso fuse-overlayfs"
    richiedi_fixture "N7" || return

    prepara_prova || return
    monta "$BANCO/prova" || return

    # fs.watch di node e' cio' che usano chokidar, vite e jest sotto il cofano.
    guarda() {                    # guarda <dir> <file_da_toccare>
        node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1], file = process.argv[2];
let visto = false;
const w = fs.watch(dir, { recursive: false }, (ev, nome) => { if (nome === path.basename(file)) visto = true; });
setTimeout(() => { fs.writeFileSync(file, "x" + Date.now()); }, 300);
setTimeout(() => { w.close(); console.log(visto ? "SI" : "NO"); process.exit(0); }, 2000);
' "$1" "$2" 2>/dev/null
    }

    local d="$BANCO/prova/node_modules"
    mkdir -p "$d/.osservato"
    local esito_stack; esito_stack=$(guarda "$d/.osservato" "$d/.osservato/f.txt")
    prepara_nativo
    mkdir -p "$BANCO/nativo/node_modules/.osservato"
    local esito_nativo; esito_nativo=$(guarda "$BANCO/nativo/node_modules/.osservato" "$BANCO/nativo/node_modules/.osservato/f.txt")

    measure "fs.watch: nativo" "${esito_nativo:-errore}"
    measure "fs.watch: sullo stack" "${esito_stack:-errore}"
    if [ "$esito_stack" = SI ]; then
        pass "gli eventi di fs.watch attraversano l'overlay"
    elif [ "$esito_nativo" != SI ]; then
        skip "gli eventi di fs.watch attraversano l'overlay" "non arrivano nemmeno sul nativo: prova inattendibile"
    else
        fail "gli eventi di fs.watch attraversano l'overlay" \
             "HMR e jest --watch non funzionerebbero: e' un criterio di uscita"
    fi

    if have inotifywait; then
        local out; out=$( (inotifywait -q -t 3 -e create,modify "$d/.osservato" & sleep 0.5; echo y > "$d/.osservato/g.txt"; wait) 2>&1 )
        if echo "$out" | grep -q "g.txt"; then pass "inotifywait vede la scrittura sull'overlay"
        else fail "inotifywait vede la scrittura sull'overlay" "$out"; fi
    else
        skip "inotifywait" "inotify-tools non installato"
    fi
    smonta "$BANCO/prova"
}

# ── N8 — spegnimento sporco ──────────────────────────────────────────────────

N8_ARMATO=0
scenario_n8() {
    section N8 "spegnimento sporco: cosa resta"
    local stato="$BANCO/n8-armato"

    if [ "${N8_ARM:-0}" = 1 ]; then
        richiedi_fixture "N8" || return
        prepara_prova || return
        monta "$BANCO/prova" || return
        ( cd "$BANCO/prova/node_modules" && find . | sort | md5sum | cut -d' ' -f1 ) > "$stato"
        # La sentinella del piano: sul filesystem sotto il mount, invisibile finche'
        # il mount c'e', unica cosa presente quando e' caduto.
        touch "$BANCO/prova/.npz/sentinella-attesa"
        N8_ARMATO=1
        MONTATI=()      # NON smontare all'uscita: e' esattamente il punto
        pass "armato" "riavvia la macchina, poi rilancia:  $0 n8"
        info "il mount su $BANCO/prova/node_modules e' stato lasciato attivo di proposito"
        return
    fi

    if [ ! -f "$stato" ]; then
        skip "spegnimento sporco" "non armato: lancia prima  $0 n8 --arm  e riavvia"
        return
    fi

    local p="$BANCO/prova"
    if mountpoint -q "$p/node_modules" 2>/dev/null; then
        skip "spegnimento sporco" "il mount c'e' ancora: la macchina non e' stata riavviata"
        return
    fi

    pass "il mount non e' sopravvissuto al riavvio"
    if [ -d "$p/node_modules" ]; then
        local n; n=$(voci_di "$p/node_modules")
        fail "la cartella e' rimasta sul disco" "$n voci — e' lo stato *rotto* della sezione 6"
        measure "cosa resta in node_modules dopo il riavvio" "$n voci"
    else
        pass "la cartella non e' rimasta" "stato *congelato*, quello leggibile"
    fi
    if [ -f "$p/.npz/static/node_modules.img" ]; then
        pass "l'immagine e' intatta"
        monta "$p" || return
        local ora; ora=$( cd "$p/node_modules" && find . | sort | md5sum | cut -d' ' -f1 )
        if [ "$ora" = "$(cat "$stato")" ]; then pass "l'autoriparazione ricostruisce l'albero identico"
        else fail "l'autoriparazione ricostruisce l'albero identico"; fi
        smonta "$p"
    else
        fail "l'immagine e' intatta" "persa nel riavvio"
    fi
    rm -f "$stato"
}

# ── report ───────────────────────────────────────────────────────────────────

scrivi_report() {
    local f="${REPORT:-$QUI/report-fase0.md}"
    mkdir -p "$(dirname "$f")"
    {
        echo "# Fase 0 di npz — esiti"
        echo
        echo "- data: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "- kernel: \`$(uname -r)\`"
        echo "- npm: \`$(npm --version 2>/dev/null)\` · node: \`$(node --version 2>/dev/null)\`"
        echo "- banco: \`$BANCO\` ($(findmnt -n -o FSTYPE -T "$BANCO" 2>/dev/null))"
        echo "- scenari: ${SCENARI[*]}"
        echo
        echo "## Esiti"
        echo
        echo "| Esito | Scenario | Verifica | Dettaglio |"
        echo "| --- | --- | --- | --- |"
        local r
        for r in "${RESULTS[@]}"; do
            IFS='|' read -r e s v d <<<"$r"
            echo "| $e | $s | $v | $d |"
        done
        echo
        echo "## Misure"
        echo
        echo "| Scenario | Metrica | Valore |"
        echo "| --- | --- | --- |"
        for r in "${MEASURES[@]}"; do
            IFS='|' read -r s m v <<<"$r"
            echo "| $s | $m | $v |"
        done
    } > "$f"
    printf '\n%sreport:%s %s\n' "$C_HDR" "$C_RST" "$f"
}

# ── ingresso ─────────────────────────────────────────────────────────────────

uso() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

N8_ARM=0
while [ $# -gt 0 ]; do
    case "$1" in
        --banco)      BANCO="$2"; shift 2 ;;
        --fixture)    FIXTURE="$2"; shift 2 ;;
        --giri)       GIRI="$2"; shift 2 ;;
        --for)        DURATA="$2"; shift 2 ;;
        --intervallo) INTERVALLO="$2"; shift 2 ;;
        --su)         OSSERVA+=("$2"); shift 2 ;;
        --report)     REPORT="$2"; shift 2 ;;
        --tieni)      TIENI=1; shift ;;
        --arm)        N8_ARM=1; shift ;;
        -h|--help)    uso ;;
        -*)           die "opzione sconosciuta: $1" ;;
        *)            SCENARI+=("$1"); shift ;;
    esac
done
[ ${#SCENARI[@]} -eq 0 ] && SCENARI=(check)
if [ "${SCENARI[0]}" = all ]; then SCENARI=(check fixture n1 n2 n3 n4 n6 n7); fi

mkdir -p "$BANCO"
for s in "${SCENARI[@]}"; do
    case "$s" in
        check)   scenario_check ;;
        fixture) scenario_fixture ;;
        n1)      scenario_n1 ;;
        n2)      scenario_n2 ;;
        n3)      scenario_n3 ;;
        n4)      scenario_n4 ;;
        n5)      scenario_n5 ;;
        n6)      scenario_n6 ;;
        n7)      scenario_n7 ;;
        n8)      scenario_n8 ;;
        *)       die "scenario sconosciuto: $s" ;;
    esac
done

[ ${#RESULTS[@]} -gt 0 ] && scrivi_report

fallimenti=$(printf '%s\n' "${RESULTS[@]:-}" | grep -c '^FAIL' || true)
printf '%s%d PASS, %d FAIL, %d SKIP%s\n' "$C_HDR" \
    "$(printf '%s\n' "${RESULTS[@]:-}" | grep -c '^PASS' || true)" \
    "$fallimenti" \
    "$(printf '%s\n' "${RESULTS[@]:-}" | grep -c '^SKIP' || true)" "$C_RST"
exit $(( fallimenti > 0 ? 1 : 0 ))
