#!/usr/bin/env bash
#
# coerenza.sh — impedisce a `.goreleaser.yaml` di divergere da `progetto.conf`.
#
# ── perché esiste ────────────────────────────────────────────────────────────
#
# Quasi tutto quel che GoReleaser dice su npz lo prende dall'ambiente —
# manutentore, descrizioni, url, licenza, versione — e per quei campi una copia
# non esiste: `.goreleaser.yaml` scrive `{{ .Env.MANUTENTORE }}` e la fonte
# resta una. Le **dipendenze** no: nfpm le vuole come elenco YAML, una voce per
# riga, e un `{{ .Env.DIP_DEBIAN }}` produrrebbe una voce sola contenente tre
# nomi separati da virgole. Per il .deb funzionerebbe pure — `Depends:` è una
# riga di testo — ma il .rpm scriverebbe un `Requires` solo, chiamato
# "erofs-utils fuse-overlayfs fuse3", cioè un pacchetto che non esiste. Sarebbe
# un rilascio installabile in nessun posto, e nessuno se ne accorgerebbe qui.
#
# Quelle tre liste sono quindi l'unica copia rimasta, e questo script è il
# prezzo che si paga per tenerla: la copia non si vieta, si rende **incapace di
# sopravvivere alla divergenza**. GoReleaser lo chiama fra i `before.hooks`, e
# un `before` che fallisce ferma il rilascio prima che esista un artefatto.
#
# È la stessa forma dell'`oracolo` di pacchetto.sh: non si spera che due cose
# coincidano, si fa fallire il giro quando non coincidono.
#
# ── come si aggancia una lista ───────────────────────────────────────────────
#
# Nel YAML, sopra ogni elenco, un commento nomina la variabile che lo governa:
#
#     dependencies: # coerenza: DIP_DEBIAN
#       - erofs-utils
#
# Il marcatore è il legame: chi aggiunge un elenco senza marcarlo non viene
# controllato, quindi lo script **conta anche i marcatori** e si lamenta se ne
# manca uno di quelli attesi.
#
# Uso:  coerenza.sh [versione-che-goreleaser-sta-per-usare]
#
set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # npz_go/build/bin
RADICE="$(dirname "$(dirname "$(dirname "$QUI")")")"  # la radice del progetto
YAML="$RADICE/.goreleaser.yaml"

# shellcheck source=../../../progetto.conf
. "$RADICE/progetto.conf" || { echo "manca $RADICE/progetto.conf" >&2; exit 1; }
[ -f "$YAML" ] || { echo "manca $YAML" >&2; exit 1; }

rosso() { printf '\033[31m%s\033[0m' "$1"; }
verde() { printf '\033[32m%s\033[0m' "$1"; }

GUASTI=0

printf '\033[1mcoerenza fra progetto.conf e .goreleaser.yaml\033[0m\n'

# La versione. GoReleaser la ricava dal tag, non da qui, ed è l'unico campo in
# cui la fonte di verità è per forza doppia — un tag non è un file. Il tag lo
# crea il workflow leggendo `progetto.conf`, quindi divergere non dovrebbe
# potersi; questo controllo copre il caso in cui qualcuno taggi a mano.
#
# Il taglio al primo trattino toglie il suffisso che `--snapshot` aggiunge da
# sé, così una prova locale non fallisce per un motivo che non è il suo.
if [ $# -ge 1 ] && [ -n "$1" ]; then
    if [ "${1%%-*}" != "$VERSIONE" ]; then
        printf '  [%s] versione: il tag dice %s, progetto.conf dice %s\n' \
            "$(rosso FAIL)" "${1%%-*}" "$VERSIONE"
        GUASTI=$((GUASTI+1))
    fi
fi

# elenco_yaml <VARIABILE> — le voci marcate con quel nome, una per riga.
elenco_yaml() {
    awk -v marca="# coerenza: $1" '
        index($0, marca) { dentro = 1; next }
        dentro && $1 == "-" { print $2; next }
        dentro { dentro = 0 }
    ' "$YAML"
}

# normale <stringa> — i nomi, uno per riga e ordinati. La lista Debian separa
# con virgole e le altre con spazi: qui la differenza non conta più.
normale() { printf '%s' "$1" | tr ',' ' ' | tr -s ' ' '\n' | sed '/^$/d' | sort; }

confronta() {
    local nome="$1" atteso="$2" trovato
    trovato=$(elenco_yaml "$nome" | sort)

    if [ -z "$trovato" ]; then
        printf '  [%s] %s: nessuna voce marcata `# coerenza: %s` nel YAML\n' \
            "$(rosso FAIL)" "$nome" "$nome"
        GUASTI=$((GUASTI+1))
        return
    fi
    if [ "$trovato" != "$(normale "$atteso")" ]; then
        printf '  [%s] %s: il YAML e progetto.conf non dicono la stessa cosa\n' \
            "$(rosso FAIL)" "$nome"
        diff <(normale "$atteso") <(printf '%s\n' "$trovato") \
            --label progetto.conf --label .goreleaser.yaml -u | sed 's/^/      /'
        GUASTI=$((GUASTI+1))
        return
    fi
    printf '  [%s] %-12s %s\n' "$(verde ok)" "$nome" "$(printf '%s' "$trovato" | tr '\n' ' ')"
}

confronta DIP_DEBIAN "$DIP_DEBIAN"
confronta DIP_RPM    "$DIP_RPM"
confronta DIP_ARCH   "$DIP_ARCH"

# ── i valori singoli ─────────────────────────────────────────────────────────
#
# Stesso marcatore, ma in coda alla riga invece che sopra un elenco. Si estrae
# quel che sta fra il primo `=` o `:` e il commento, quindi regge tanto una riga
# di shell quanto una riga YAML.
#
# Ne resta uno solo: `install.sh` viene scaricato **da solo**, senza il repo
# intorno, quindi l'indirizzo del progetto deve portarselo scritto. Tutto il
# resto lo ricava a run time dal `SHA256SUMS` del rilascio.
scalare() {
    local file="$1" nome="$2" atteso="$3" trovato
    trovato=$(awk -v marca="# coerenza: $2" '
        index($0, marca) {
            sub(/#.*/, "")                      # via il commento
            sub(/^[^=:]*[=:][[:space:]]*/, "")  # via il nome e il separatore
            gsub(/^["'"'"']|["'"'"'][[:space:]]*$|[[:space:]]+$/, "")
            print; exit
        }' "$file")

    if [ -z "$trovato" ]; then
        printf '  [%s] %s: nessuna riga marcata `# coerenza: %s` in %s\n' \
            "$(rosso FAIL)" "$nome" "$nome" "$(basename "$file")"
        GUASTI=$((GUASTI+1))
        return
    fi
    if [ "$trovato" != "$atteso" ]; then
        printf '  [%s] %s in %s dice «%s», progetto.conf dice «%s»\n' \
            "$(rosso FAIL)" "$nome" "$(basename "$file")" "$trovato" "$atteso"
        GUASTI=$((GUASTI+1))
        return
    fi
    printf '  [%s] %-12s %s\n' "$(verde ok)" "$nome" "$trovato"
}

# `install.sh` nomina il repo, `progetto.conf` nomina il proprietario: il pezzo
# in mezzo è il nome del progetto, che è già in `NOME`.
scalare "$RADICE/install.sh" URL "$URL/$NOME"

if [ "$GUASTI" -ne 0 ]; then
    printf '\n  %s: il rilascio si ferma qui.\n' "$(rosso "$GUASTI problemi")"
    printf '  La fonte è progetto.conf: si allinea il YAML, mai il contrario.\n\n'
    exit 1
fi
echo
