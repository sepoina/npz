"""Che cosa fa un comando npm, e quale di essi e' invece nostro.

Due regole di metodo, che vengono dalla fase 0.

**La lista dei mutanti si sbaglia per eccesso.** Un comando classificato mutante
per errore costa un `os.stat` sul delta che non trova niente; un mutante non
classificato lascia crescere il delta senza che nessuno se ne accorga. Da cui
`classifica()` risponde MUTANTE anche a cio' che non conosce.

**Si guarda il delta, non il comando.** N2 ha misurato che tre `npm install` su
dieci non producono alcun delta, perche' il pacchetto c'era gia' come dipendenza
transitiva. La classificazione dice solo *se vale la pena guardare*.

Questo modulo non importa niente: sta sul percorso veloce.
"""

# I comandi di npz, che non arrivano mai a npm. Nessuno di questi nomi esiste in
# npm, e per quelli che un giorno potrebbero esistere c'e' `npz -- <comando>`.
PROPRI = ("attach", "detach", "hey", "bye", "status", "compact")

NEUTRO, MUTANTE, DISTRUTTIVO, NOSTRO = "neutro", "mutante", "distruttivo", "nostro"

# `npm ci` comincia cancellando node_modules. Sull'overlay significa un whiteout
# per ogni voce e poi l'albero intero riestratto nel delta: misurato in fase 0,
# 3,0–3,5x piu' lento e 821 MiB contro 588 del nativo. Va portato sull'albero
# nudo, non eseguito sullo stack.
_DISTRUTTIVI = frozenset({
    "ci", "clean-install", "install-clean", "ic", "isntall-clean",
})

# Gli alias sono quelli veri di npm: chi scrive `npm i` non deve ottenere un
# comportamento diverso da chi scrive `npm install`.
_MUTANTI = frozenset({
    "install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta",
    "isntal", "isntall", "add",
    "uninstall", "unlink", "remove", "rm", "r", "un",
    "update", "up", "upgrade", "udpate",
    "dedupe", "ddp", "find-dupes",
    "prune",
    "link", "ln",
    "rebuild", "rb",
    "install-test", "it", "install-ci-test", "cit",
})

# Tutto il resto e' neutro: legge, stampa, esegue script. Non tocca l'albero.
_NEUTRI = frozenset({
    "run", "run-script", "rum", "urn", "test", "t", "tst", "start", "stop",
    "restart", "ls", "list", "la", "ll", "explain", "why", "outdated", "audit",
    "publish", "pack", "view", "v", "info", "show", "search", "s", "se", "find",
    "help", "help-search", "config", "c", "get", "set", "whoami", "login",
    "logout", "adduser", "token", "team", "org", "owner", "author", "access",
    "dist-tag", "deprecate", "undeprecate", "star", "unstar", "stars", "ping",
    "doctor", "root", "prefix", "bin", "repo", "docs", "home", "bugs", "issues",
    "version", "exec", "x", "create", "init", "query", "sbom", "diff", "hook",
    "profile", "edit", "fund", "completion", "shrinkwrap", "pkg", "cache",
    # aggiunti confrontando con l'elenco di `npm` 11: operazioni di registro e
    # di configurazione, che l'albero non lo toccano.
    "approve-scripts", "deny-scripts", "stage", "trust", "unpublish",
})


def separa(argv: list[str]) -> tuple[str | None, bool]:
    """Il primo argomento che non e' un'opzione, e se c'era un `--`.

    Dopo `--` non si guarda piu': `npz -- bye` deve arrivare a npm come `bye`,
    che e' la via di fuga per il giorno in cui npm avesse un comando con uno dei
    nostri nomi.
    """
    for i, a in enumerate(argv):
        if a == "--":
            return (argv[i + 1] if i + 1 < len(argv) else None), True
        if not a.startswith("-"):
            return a, False
    return None, False


def classifica(argv: list[str]) -> str:
    comando, passante = separa(argv)
    if comando is None:
        return NEUTRO                      # `npz` nudo: npm stampa l'aiuto
    if not passante and comando in PROPRI:
        return NOSTRO
    if comando in _DISTRUTTIVI:
        return DISTRUTTIVO
    if comando in _NEUTRI:
        return NEUTRO
    return MUTANTE                         # per eccesso: vedi il docstring
