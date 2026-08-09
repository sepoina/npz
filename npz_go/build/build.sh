#!/usr/bin/env bash
#
# build.sh — la compilazione di npz.
#
# Esiste per non lasciare le opzioni che contano alla memoria di chi compila.
# Tre di esse non sono preferenze:
#
#   CGO_ENABLED=0   il binario non linka libc, quindi gira su qualunque Linux
#                   indipendentemente dalla versione di glibc. E' l'intera
#                   ragione per cui il §2 del piano Go ha scelto Go: questa
#                   macchina ha glibc 2.44, Debian 12 la 2.36, e un binario
#                   dinamico non partirebbe la'. Non e' una ottimizzazione.
#   -trimpath       toglie dal binario i percorsi assoluti della macchina che
#                   l'ha compilato. Senza, dentro npz finirebbe il percorso di
#                   casa di chi l'ha costruito.
#   -s -w           via la tabella dei simboli e il DWARF: ~25% in meno, e non
#                   servono a chi lo usa.
#
# Uso:
#   ./build.sh                 npz per questa macchina, in build/lavoro/npz
#   ./build.sh tutti           anche linux/amd64 e linux/arm64
#   ./build.sh attrezzi        anche gli attrezzi del banco (spike, nucleo)
#   ./build.sh pulisci         svuota build/lavoro/ e dist/
#
# I metadati — versione compresa — stanno in `progetto.conf` nella radice del
# **progetto**, un livello sopra il modulo Go, perche' quel file e' condiviso
# con l'implementazione Python: la versione di npz e' una sola, e le
# implementazioni che la dichiarano sono due. Questo script lo legge da li'.
# Per marchiare un binario senza toccare il repo, l'ambiente vince sul file:
# VERSIONE=1.2.3 ./build.sh
#
# ── e il rilascio? ───────────────────────────────────────────────────────────
#
# Se la versione in `progetto.conf` e' cambiata da quella dell'ultimo rilascio,
# questo script chiama `bin/pacchetto.sh` da solo. La ragione e' che il momento
# in cui si bumpa la versione e il momento in cui ci si ricorda di impacchettare
# sono due, e fra i due si perde un rilascio: si finisce con un binario nuovo e
# dei pacchetti che dichiarano il numero di ieri.
#
# Per costruire senza impacchettare:  SALTA_PACCHETTO=1 ./build.sh
#
# I banchi in test/ NON usano questo script: ricompilano da soli dentro il
# proprio banco, perche' una prova che dipende da un binario costruito prima
# proverebbe quel binario e non il codice di adesso.
#
set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULO="$(dirname "$QUI")"                # npz_go
RADICE="$(dirname "$MODULO")"             # la radice del progetto, dove sta il conf

# La fonte di verita'. L'ambiente vince sul file, cosi' un rilascio si puo'
# marchiare al volo senza modificare nulla di versionato.
_ver_ambiente="${VERSIONE:-}"
# shellcheck source=../../progetto.conf
. "$RADICE/progetto.conf" || { echo "manca $RADICE/progetto.conf" >&2; exit 1; }
[ -n "$_ver_ambiente" ] && VERSIONE="$_ver_ambiente"

# I binari di lavoro stanno dentro build/, accanto allo script che li produce, e
# **non** in dist/. Sono due cartelle e non una perche' sono due cose: qui c'e' il
# binario con cui si prova quel che si e' appena scritto, la' c'e' quel che si
# spedisce. Confonderle e' il modo piu' rapido per pubblicare il binario di ieri.
LAVORO="$QUI/lavoro"
DIST="$MODULO/dist"
# L'attrezzo che impacchetta e' un'utilita', e sta con le utilita'.
PACCHETTO="$QUI/bin/pacchetto.sh"

verde() { printf '\033[32m%s\033[0m' "$1"; }
rosso() { printf '\033[31m%s\033[0m' "$1"; }
sez()   { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

GUASTI=0

# compila <nome> <pacchetto> [GOOS] [GOARCH]
compila() {
    local nome="$1" pacchetto="$2" sistema="${3:-}" arco="${4:-}"
    local bersaglio="$LAVORO/$nome"
    # I due simboli si marchiano insieme, sempre, dalla stessa fonte: e' cio'
    # che rende impossibile che la versione stampata da `npz` e quella scritta
    # nel `creata_da` di uno store si contraddicano.
    local marchio="-X npz/internal/facciata.Versione=$VERSIONE"
    marchio="$marchio -X npz/internal/nucleo.Versione=$VERSIONE"

    # `env` e non un prefisso di assegnazione: bash riconosce `VAR=x comando`
    # solo se l'assegnazione e' scritta alla lettera. Una variabile che si
    # *espande* in `GOOS=linux` viene presa per il nome del comando, e si
    # ottiene un "comando non trovato" che sembra un problema di PATH.
    if ! ( cd "$MODULO" && env CGO_ENABLED=0 \
            ${sistema:+GOOS=$sistema} ${arco:+GOARCH=$arco} \
            go build -trimpath -ldflags="-s -w $marchio" \
                     -o "$bersaglio" "$pacchetto" ) 2>&1; then
        printf '  [%s] %s\n' "$(rosso FAIL)" "$nome"
        GUASTI=$((GUASTI+1))
        return 1
    fi

    local peso descrizione stato
    peso=$(numfmt --to=iec-i --suffix=B "$(stat -c%s "$bersaglio")")
    descrizione=$(file -b "$bersaglio")

    # La verifica che conta: se non e' statico, non gira sulle distro vecchie e
    # tutto il ragionamento del §2 cade. Meglio scoprirlo qui che dopo il
    # rilascio, e `file` lo dice in inglese in ogni locale — a differenza di
    # `ldd`, il cui messaggio e' tradotto.
    if printf '%s' "$descrizione" | grep -q "statically linked"; then
        stato=$(verde ok)
    else
        stato=$(rosso "DINAMICO")
        GUASTI=$((GUASTI+1))
    fi

    printf '  [%s] %-22s %-9s %s\n' "$stato" "$nome" "$peso" \
        "$(printf '%s' "$descrizione" | cut -d, -f2 | sed 's/^ //')"
}

pulisci() {
    sez "pulizia"
    # Si cancella il contenuto, non la cartella: entrambe fanno parte della
    # struttura e il loro `.gitignore` deve sopravvivere.
    local d
    for d in "$LAVORO" "$DIST"; do
        [ -d "$d" ] || continue
        find "$d" -mindepth 1 ! -name '.gitignore' -delete 2>/dev/null
    done
    printf '  build/lavoro/ e dist/ svuotate\n\n'
}

# ── il rilascio, quando la versione cambia ───────────────────────────────────
#
# `dist/SHA256SUMS` e' il sentinella, e non un file di stato scritto per
# l'occasione. Vale come sentinella per due proprieta' che ha di per se':
# `pacchetto.sh` lo scrive **per ultimo e solo a zero guasti**, quindi c'e' se e
# solo se un rilascio e' andato a buon fine; e nomina i file, quindi porta scritta
# dentro la versione che copre. Un giro interrotto a meta' non lo lascia, e il
# prossimo `build.sh` riprova — che e' il comportamento che si vuole.
#
# Uno `.ultima-versione` nascosto avrebbe detto la stessa cosa potendo mentire:
# esisterebbe anche dopo un giro fallito.
gia_rilasciata() {
    local somme="$DIST/SHA256SUMS"
    [ -f "$somme" ] || return 1
    # Il nome per esteso e non la sola versione: `grep 0.2.1` risponderebbe si'
    # anche a un dist/ di 0.2.10.
    grep -qF "${NOME}_${VERSIONE}_amd64.deb" "$somme"
}

impacchetta_se_serve() {
    if [ -n "${SALTA_PACCHETTO:-}" ]; then
        sez "il rilascio"
        printf '  SALTA_PACCHETTO e\x27 impostato: non si impacchetta.\n\n'
        return 0
    fi
    if gia_rilasciata; then
        sez "il rilascio"
        printf '  %s e\x27 gia\x27 in dist/, con le somme: niente da rifare.\n' "$VERSIONE"
        printf '  per rifarlo comunque:  bin/pacchetto.sh\n\n'
        return 0
    fi
    if [ ! -x "$PACCHETTO" ]; then
        printf '  [%s] manca %s\n' "$(rosso FAIL)" "$PACCHETTO"
        return 1
    fi

    sez "il rilascio"
    printf '  la versione %s non e\x27 in dist/: si impacchetta.\n' "$VERSIONE"
    # Si passa la versione all'ambiente invece di lasciargliela rileggere: se
    # `progetto.conf` cambiasse fra i due (o se qui la versione venisse
    # dall'ambiente), i binari appena costruiti e i pacchetti direbbero due numeri.
    VERSIONE="$VERSIONE" "$PACCHETTO"
}

main() {
    mkdir -p "$LAVORO"
    local cosa="${1:-questa}"

    if [ "$cosa" = pulisci ]; then pulisci; exit 0; fi

    printf '\033[1mbuild di %s %s\033[0m\n' "$NOME" "$VERSIONE"
    printf '  go %s · metadati da progetto.conf\n' "$(go version | awk '{print $3}')"

    sez "npz, per questa macchina"
    compila npz .

    if [ "$cosa" = tutti ]; then
        sez "npz, per le piattaforme di rilascio"
        # Due architetture da una macchina sola, senza toolchain aggiuntive:
        # e' la proprieta' che il §2 ha misurato in MB e qui si vede in secondi.
        compila npz-linux-amd64 . linux amd64
        compila npz-linux-arm64 . linux arm64
    fi

    if [ "$cosa" = attrezzi ]; then
        sez "gli attrezzi del banco"
        # Non sono prodotto: lo spike e' il codice da buttare via della fase 0,
        # il guscio serve al banco per confrontarsi col Python. Si compilano a
        # richiesta perche' averli accanto a npz confonderebbe.
        compila npz-spike ./test/spike
        compila npz-nucleo ./test/nucleo
    fi

    sez "riepilogo"
    if [ "$GUASTI" -eq 0 ]; then
        printf '  tutto in %s\n' "build/lavoro/"
    else
        printf '  %s guasti\n\n' "$(rosso "$GUASTI")"
        return 1
    fi

    # Solo dopo una compilazione riuscita, e solo per il prodotto: `attrezzi`
    # costruisce i banchi, che non si rilasciano.
    case "$cosa" in
        questa|tutti) impacchetta_se_serve || GUASTI=$((GUASTI+1)) ;;
        *)            echo ;;
    esac

    [ "$GUASTI" -eq 0 ]
}

main "$@"
