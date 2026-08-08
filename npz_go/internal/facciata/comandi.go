// Che cosa fa un comando npm, e quale di essi e' invece nostro.
//
// Due regole di metodo, che vengono dalla fase 0.
//
// **La lista dei mutanti si sbaglia per eccesso.** Un comando classificato
// mutante per errore costa uno Stat sul delta che non trova niente; un mutante
// non classificato lascia crescere il delta senza che nessuno se ne accorga. Da
// cui Classifica risponde Mutante anche a cio' che non conosce.
//
// **Si guarda il delta, non il comando.** N2 ha misurato che tre `npm install`
// su dieci non producono alcun delta, perche' il pacchetto c'era gia' come
// dipendenza transitiva. La classificazione dice solo *se vale la pena
// guardare*.

package facciata

import "strings"

// Classe e' la categoria di un comando. Come per Stato, un tipo dedicato invece
// di `string` nuda: vedi la nota del §6.3 in nomi.go.
type Classe string

const (
	Neutro      Classe = "neutro"
	Mutante     Classe = "mutante"
	Distruttivo Classe = "distruttivo"
	Nostro      Classe = "nostro"
)

// Propri sono i comandi di npz, che non arrivano mai a npm. Nessuno di questi
// nomi esiste in npm, e per quelli che un giorno potrebbero esistere c'e'
// `npz -- <comando>`.
var Propri = insieme("attach", "detach", "hey", "bye", "status", "compact")

// `npm ci` comincia cancellando node_modules. Sull'overlay significa un
// whiteout per ogni voce e poi l'albero intero riestratto nel delta: misurato
// in fase 0, 3,57x piu' lento e 821 MiB contro 588 del nativo. Va portato
// sull'albero nudo, non eseguito sullo stack.
var distruttivi = insieme("ci", "clean-install", "install-clean", "ic", "isntall-clean")

// Gli alias sono quelli veri di npm: chi scrive `npm i` non deve ottenere un
// comportamento diverso da chi scrive `npm install`.
var mutanti = insieme(
	"install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta",
	"isntal", "isntall", "add",
	"uninstall", "unlink", "remove", "rm", "r", "un",
	"update", "up", "upgrade", "udpate",
	"dedupe", "ddp", "find-dupes",
	"prune",
	"link", "ln",
	"rebuild", "rb",
	"install-test", "it", "install-ci-test", "cit",
)

// Tutto il resto e' neutro: legge, stampa, esegue script. Non tocca l'albero.
var neutri = insieme(
	"run", "run-script", "rum", "urn", "test", "t", "tst", "start", "stop",
	"restart", "ls", "list", "la", "ll", "explain", "why", "outdated", "audit",
	"publish", "pack", "view", "v", "info", "show", "search", "s", "se", "find",
	"help", "help-search", "config", "c", "get", "set", "whoami", "login",
	"logout", "adduser", "token", "team", "org", "owner", "author", "access",
	"dist-tag", "deprecate", "undeprecate", "star", "unstar", "stars", "ping",
	"doctor", "root", "prefix", "bin", "repo", "docs", "home", "bugs", "issues",
	"version", "exec", "x", "create", "init", "query", "sbom", "diff", "hook",
	"profile", "edit", "fund", "completion", "shrinkwrap", "pkg", "cache",
	// aggiunti confrontando con l'elenco di `npm` 11: operazioni di registro e
	// di configurazione, che l'albero non lo toccano.
	"approve-scripts", "deny-scripts", "stage", "trust", "unpublish",
)

func insieme(nomi ...string) map[string]bool {
	m := make(map[string]bool, len(nomi))
	for _, n := range nomi {
		m[n] = true
	}
	return m
}

// Separa da' il primo argomento che non e' un'opzione, e se c'era un `--`.
//
// Dopo `--` non si guarda piu': `npz -- bye` deve arrivare a npm come `bye`,
// che e' la via di fuga per il giorno in cui npm avesse un comando con uno dei
// nostri nomi.
func Separa(argv []string) (comando string, passante bool) {
	for i, a := range argv {
		if a == "--" {
			if i+1 < len(argv) {
				return argv[i+1], true
			}
			return "", true
		}
		if !strings.HasPrefix(a, "-") {
			return a, false
		}
	}
	return "", false
}

// Classifica risponde Mutante anche a cio' che non conosce: vedi il commento in
// cima al file.
func Classifica(argv []string) Classe {
	comando, passante := Separa(argv)
	if comando == "" {
		return Neutro // `npz` nudo: npm stampa l'aiuto
	}
	if !passante && Propri[comando] {
		return Nostro
	}
	switch {
	case distruttivi[comando]:
		return Distruttivo
	case neutri[comando]:
		return Neutro
	default:
		return Mutante
	}
}

// HaBandiera dice se fra gli argomenti c'e' una certa opzione.
func HaBandiera(argv []string, bandiera string) bool {
	for _, a := range argv {
		if a == bandiera {
			return true
		}
	}
	return false
}
