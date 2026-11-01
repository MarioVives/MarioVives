# Claude Tokens (widget barre de menus macOS)

Petite app de barre de menus qui affiche une estimation de ta consommation
par rapport aux limites de ton plan **Claude Code**, ainsi que le détail de
tes tokens.

- Barre de menus : % estimé de la limite des 5 dernières heures (`✦ 6 %`).
- Au clic :
  - **Limites du plan (estimation)** : % des 5 dernières heures (fenêtre
    glissante) et % de la semaine en cours, avec l'heure de réinitialisation
    hebdomadaire.
  - **Tokens** : total aujourd'hui / 7 jours / 30 jours, histogramme des
    7 derniers jours, détail entrée / sortie / cache, répartition par
    modèle et top 5 des projets.
  - Option « Lancer à l'ouverture de session ».
- Rafraîchissement automatique toutes les 60 s (relecture uniquement des
  fichiers modifiés).

## Le % de limite de plan est une estimation, pas une donnée officielle

Anthropic n'expose le vrai `%` d'utilisation de plan (celui que montre
l'app Claude Code officielle) que via un appel réseau authentifié — rien
dans les logs locaux ne le contient directement, et il n'existe aucune API
locale ou documentée pour le lire autrement.

Pour l'estimer **sans réseau et sans clé API**, l'app :
1. pondère chaque token local selon un poids approximatif de coût
   (sortie ≈ 5x entrée, écriture cache ≈ 1,25x, lecture cache ≈ 0,1x,
   d'après la grille tarifaire Anthropic) ;
2. compare cette somme pondérée, sur une fenêtre de temps connue, à la
   vraie valeur lue une fois dans l'app officielle, pour calibrer un
   « budget » de référence (voir les constantes `PlanBudget` dans
   `ClaudeTokens.swift`) ;
3. recalcule ensuite ce `%` en continu, en local, en comparant l'usage
   courant à ce budget calibré.

Conséquences à garder en tête :
- C'est une **approximation**, qui peut dériver avec le temps (changement
  de plan, évolution des limites côté Anthropic, etc.) — à recalibrer de
  temps en temps.
- La fenêtre « 5 dernières heures » est une fenêtre glissante recalculée
  en continu, pas le vrai compteur Anthropic (dont l'instant de départ
  exact n'est pas connaissable sans réseau) : elle donne un ordre de
  grandeur, pas une valeur exacte.
- La fenêtre hebdomadaire, elle, est calée sur l'heure de reset réelle
  (repérée empiriquement, vendredi 05:00 UTC pour ce compte) et est donc
  plus fiable sur le *quand*, mais le budget de référence associé reste
  une calibration approximative.

## Source des données

L'app lit les logs locaux de Claude Code : `~/.claude/projects/**/*.jsonl`
(et `~/.config/claude/projects` si présent). Chaque réponse du modèle y est
enregistrée avec son champ `usage`. Rien ne sort de ta machine, aucune clé
API, aucun appel réseau à l'exécution.

Limite : la consommation sur **claude.ai** (web, app desktop, mobile) n'est
pas couverte, Anthropic n'expose pas ces données. Seul Claude Code est
compté. Le % de plan n'est aussi calculé qu'à partir de l'usage visible
dans les logs **de cette machine** : si tu utilises Claude Code sur
plusieurs appareils, le % de plan sera sous-estimé.

Le total de tokens inclut les 4 types de tokens. La **lecture de cache**
pèse souvent 80 à 90 % du total brut : elle est facturée environ 10 fois
moins cher qu'une entrée normale (d'où la pondération utilisée pour le %
de plan, bien plus faible sur ce type de token).

## Installation

Prérequis : macOS 13 (Ventura) ou plus, et les outils de développement Apple :

```bash
xcode-select --install   # une seule fois, si swiftc n'est pas déjà là
```

Puis :

```bash
cd claude-tokens-widget
./build.sh --install
```

L'app est compilée, copiée dans `~/Applications` et lancée. Elle n'a pas
d'icône dans le Dock, seulement dans la barre de menus. Pour la quitter :
clic sur l'icône, puis « Quitter » (ou ⌘Q).

Si macOS bloque l'ouverture (« développeur non identifié ») : clic droit sur
l'app dans le Finder, puis « Ouvrir ».
