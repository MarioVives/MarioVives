# Claude Tokens (widget barre de menus macOS)

Petite app de barre de menus qui affiche ta consommation de tokens **Claude Code**.

- Barre de menus : total du jour (`✦ 1.2 M`).
- Au clic : aujourd'hui / 7 jours / 30 jours, histogramme des 7 derniers jours,
  détail entrée / sortie / cache, répartition par modèle et top 5 des projets.
- Rafraîchissement automatique toutes les 60 s (relecture uniquement des fichiers modifiés).
- Option « Lancer à l'ouverture de session ».

## Source des données

L'app lit les logs locaux de Claude Code : `~/.claude/projects/**/*.jsonl`
(et `~/.config/claude/projects` si présent). Chaque réponse du modèle y est
enregistrée avec son champ `usage`. Rien ne sort de ta machine, aucune clé API.

Limite : la consommation sur **claude.ai** (web, app desktop, mobile) n'est pas
couverte, Anthropic n'expose pas ces données. Seul Claude Code est compté.

Le total inclut les 4 types de tokens. La **lecture de cache** pèse souvent
80 à 90 % du total : elle est facturée environ 10 fois moins cher qu'une entrée normale.

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
