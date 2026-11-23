# Versions de Nabla

Chaque version se télécharge sur la page [Releases](../../releases) : toutes les versions restent disponibles.

Numérotation `vMAJEUR.MINEUR.CORRECTIF` :

- **CORRECTIF** (v1.0.1) : uniquement des bugs corrigés ;
- **MINEUR** (v1.1.0) : nouveautés et améliorations, sans rien casser ;
- **MAJEUR** (v2.0.0) : changement qui demande une action (prérequis, format des projets…).

Chaque version liste ses **nouveautés**, ses **améliorations** et ses **bugs corrigés**.
La plus récente est en haut ; son numéro est celui que `app/build.sh` donne à l'app.

## v1.1.0 (2026-11-23)

Nabla arrive sur Windows.

### Nouveautés

- Nabla pour Windows 10 et 11 (64 bits), avec les mêmes fonctions que sur Mac : projets et modèles,
  compilation latexmk, journal, SyncTeX, complétion, plan, historique, PDF en sombre et export.
  Raccourcis avec Ctrl à la place de ⌘ (Ctrl+J, Ctrl+R, Ctrl+F, Ctrl+H pour remplacer, F3 pour l'occurrence suivante).
- Installeur `Nabla-1.1.0-installeur.exe`, pour votre compte seul et sans droits d'administrateur,
  ou `Nabla-1.1.0-windows.zip` à décompresser.
- Compilation avec MiKTeX ou TeX Live : au premier lancement, l'accueil indique ce qui manque
  (LaTeX, latexmk, ou Perl pour le latexmk de MiKTeX).
- Sous Windows, un dossier ou un `.tex` glissé sur Nabla.exe, ou ouvert avec Nabla, s'ouvre directement.

### Améliorations

- Windows : le PDF est dessiné à part, l'éditeur ne gèle jamais pendant le rendu ; sur 5 900 lignes,
  environ 12 ms par frappe, et rien n'est recalculé quand on ne tape pas.

### Bugs corrigés

- Aucun dans cette version.

## v1.0.0 (2026-11-22)

Première version publique.

### Nouveautés

- Projets : un projet est un dossier. Accueil avec nouveau projet, ouverture et projets récents ;
  modèles Article, Rapport, Présentation (Beamer), Exercices et Formule seule.
- Compilation locale avec latexmk : références, citations et bibliographie résolues ;
  XeLaTeX ou LuaLaTeX avec `% !TEX program = xelatex`.
- Erreurs et avertissements avec le fichier et la ligne, dans le panneau Journal.
- SyncTeX : ⌘J montre dans le PDF la ligne du curseur ; un double-clic dans le PDF ouvre la source.
- Éditeur : coloration, numéros de ligne, recherche et remplacement (⌘F), complétion des commandes
  (environ 230), des `\ref`, des `\cite` et des environnements.
- Plan du document, historique des versions de chaque fichier, enregistrement à chaque frappe.
- Export PDF (⌘E) ; PDF en sombre avec « Inverser les couleurs » (⌥⌘I), à l'écran et à l'export.
- Taille du texte réglable (⌘+ ⌘− ⌘0) ; apparence claire, sombre ou système.
- Premier lancement sans LaTeX : l'accueil indique quoi installer.
- App universelle (puce Apple et Intel), livrée en image disque.

### Améliorations

- Éditeur rapide sur les gros documents : sur 5 900 lignes, coloration de 83 ms à 0,04 ms par frappe,
  numéros de ligne quasi instantanés au défilement.
- Moins d'énergie en arrière-plan : surveillance du disque seulement au premier plan.
- Mémoire : vérification automatique du texte par macOS coupée (185 Mo à 168 Mo avec un projet ouvert).
- Journal : un arrêt de compilation affiche sa vraie cause (paquet ou fichier introuvable).
- Accessibilité : libellés VoiceOver sur l'accueil, contraste renforcé, animations coupées
  avec « Réduire les animations ».

### Bugs corrigés

- SyncTeX ne trouvait pas les fichiers au nom accentué.
- Le plan affichait de faux titres venant de `verbatim` et de `\verb|…|`.
- `\\%` n'était pas reconnu comme un commentaire (coloration et plan).
- Le bouton « + » de la barre latérale disparaissait quand la fenêtre était étroite.
- Les lignes « Fatal error occurred » s'affichaient en double dans le journal.
