# Nabla

Éditeur LaTeX pour Mac (macOS 14+, puce Apple ou Intel) et Windows (10 et 11, 64 bits) qui compile en local,
sans compte ni connexion.

## Ce qu'il fait

- **Projets** : un projet est un dossier ; modèles Article, Rapport, Présentation (Beamer), Exercices et Formule seule.
- **Compilation locale** avec latexmk : références, citations et bibliographie résolues ; XeLaTeX ou LuaLaTeX
  avec `% !TEX program = xelatex` en tête du fichier principal.
- **Erreurs** avec le fichier et la ligne, journal des avertissements.
- **SyncTeX** : ⌘J (Ctrl+J sous Windows) montre dans le PDF la ligne du curseur ; un double-clic dans le PDF ouvre la source.
- **Éditeur** : coloration, numéros de ligne, recherche et remplacement (⌘F), complétion des commandes,
  des `\ref`, des `\cite` et des environnements, taille du texte (⌘+ ⌘−).
- **Plan du document**, **historique des versions** de chaque fichier, enregistrement à chaque frappe.
- **PDF en sombre** (couleurs inversées, à l'écran et à l'export), mode clair ou sombre.

## Installer

### Mac

1. Télécharger `Nabla-X.Y.Z.dmg` de la dernière version sur la page [Releases](../../releases), l'ouvrir, et glisser **Nabla** sur le raccourci **Applications**.
2. Au premier lancement, macOS refuse d'ouvrir l'app : elle n'est pas notarisée par Apple (le projet n'a pas de
   compte Apple Developer payant). Pour l'autoriser, une seule fois :
   ouvrir **Réglages Système › Confidentialité et sécurité**, descendre jusqu'au message sur Nabla,
   cliquer **Ouvrir quand même**, puis confirmer.

   Ou, dans le Terminal :

   ```sh
   xattr -dr com.apple.quarantine /Applications/Nabla.app
   ```

3. Installer LaTeX (voir ci-dessous) : au premier lancement, Nabla indique ce qui manque.

### Windows

1. Télécharger `Nabla-X.Y.Z-installeur.exe` de la dernière version sur la page [Releases](../../releases) et le lancer.
   L'installation se fait pour votre compte seul, sans droits d'administrateur ; Nabla apparaît dans le menu Démarrer.
   Sans installeur : `Nabla-X.Y.Z-windows.zip` se décompresse n'importe où, puis lancer `Nabla.exe`
   (garder `pdfium.dll` à côté).
2. Au premier lancement, Windows SmartScreen peut afficher « Windows a protégé votre ordinateur » : l'app n'est pas
   signée par un certificat payant. Cliquer **Informations complémentaires**, puis **Exécuter quand même**.
3. Installer LaTeX (voir ci-dessous) : au premier lancement, Nabla indique ce qui manque.

## Prérequis

- **Mac** : installer [MacTeX](https://www.tug.org/mactex/) (ou `brew install --cask mactex-no-gui`).
- **Windows** : installer [MiKTeX](https://miktex.org/download) (le plus simple : les paquets manquants s'installent
  tout seuls à la première compilation) ou [TeX Live](https://tug.org/texlive/windows.html).
  Avec MiKTeX, latexmk a besoin de Perl : installer [Strawberry Perl](https://strawberryperl.com).

Au premier lancement, Nabla signale ce qui manque.

## Construire

Mac :

```sh
./app/build.sh && open app/Nabla.app
```

`build.sh` produit une app universelle (puce Apple et Intel), version 1.0 ; le numéro de build est le nombre de commits.

Windows : le code est dans [`windows/`](windows) (Rust, interface egui, PDF affiché par PDFium). Chaque push qui
le touche construit `Nabla.exe` sur GitHub Actions ([workflow Windows](.github/workflows/windows.yml)) : le `.zip` et
l'installeur sont dans les artefacts du run. En local, avec [Rust](https://rustup.rs) :

```sh
cd windows && cargo run --release
```

`pdfium.dll` (ou `libpdfium.dylib` pour essayer sur Mac) se télécharge sur
[pdfium-binaries](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/8125) et se range dans `windows/pdfium/`.

## Tests

```sh
cd app && swift test
cd windows && cargo test
```

## Deux apps, mêmes fonctions

L'app Mac (`app/`, Swift) et l'app Windows (`windows/`, Rust) font la même chose : toute nouveauté, amélioration ou
correction faite dans l'une est faite dans l'autre, dans le même commit, et le CHANGELOG les décrit ensemble.
Ce qui ne diffère que par le système (raccourcis Ctrl au lieu de ⌘, Explorateur au lieu du Finder, MiKTeX au lieu de
MacTeX) reste propre à chaque app.

- Les listes partagées ne s'écrivent qu'une fois, côté Mac : les commandes et environnements de la complétion
  (`Completion.swift`), les modèles de projet (`TeX.swift`) et le numéro de version (`CHANGELOG.md`) sont lus par
  `windows/build.rs` à chaque construction.
- Les tests de `windows/src/tests.rs` reprennent ceux de `app/Tests/NablaTests` : un cas ajouté d'un côté s'ajoute de l'autre.

| Mac (`app/Sources/Nabla/`) | Windows (`windows/src/`) |
|---|---|
| `App.swift`, `ProjectView.swift` | `main.rs` (interface), `pdf.rs` (PDF, mode sombre, export) |
| `Project.swift` | `project.rs` |
| `Editor.swift`, `Completion.swift` | `editor.rs`, `completion.rs` |
| `TeX.swift` | `tex.rs` |
| `History.swift` | `history.rs` |

## Versions

Toutes les versions se téléchargent sur la page [Releases](../../releases). Ce qui change d'une version à l'autre
(nouveautés, améliorations, bugs corrigés) est dans [CHANGELOG.md](CHANGELOG.md).

Numérotation `vMAJEUR.MINEUR.CORRECTIF` : un correctif (v1.0.1) ne fait que corriger des bugs,
une version mineure (v1.1.0) ajoute ou améliore sans rien casser, une version majeure (v2.0.0) demande une action.

## Publier une version

1. Ajouter en haut de `CHANGELOG.md` une section `## vX.Y.Z (date)` avec ses rubriques
   **Nouveautés**, **Améliorations** et **Bugs corrigés**, puis commiter sur `main`.
2. Lancer :

   ```sh
   ./app/release.sh
   ```

   Le script vérifie que tout est commité et à jour, construit l'app (le numéro de version vient du CHANGELOG),
   crée le tag `vX.Y.Z`, le pousse et publie la Release avec `Nabla-X.Y.Z.dmg` et les notes de la version.
   Le tag lance aussi le workflow Windows, qui ajoute à la même Release `Nabla-X.Y.Z-installeur.exe`
   et `Nabla-X.Y.Z-windows.zip` quelques minutes plus tard.

Sans compte Apple Developer, l'app est signée « ad hoc » (sans certificat) : macOS l'accepte après l'autorisation
décrite dans « Installer ». Sans cette signature, un Mac à puce Apple déclarerait l'app « endommagée ».

### Avec un compte Apple Developer (facultatif, 99 $/an)

L'app est alors notarisée et s'ouvre sans avertissement :

1. Dans Xcode › Réglages › Comptes, ajouter le compte, puis Gérer les certificats › + › **Developer ID Application**.
2. Créer un mot de passe pour app sur [account.apple.com](https://account.apple.com), puis une fois pour toutes :

   ```sh
   xcrun notarytool store-credentials nabla --apple-id ADRESSE --team-id EQUIPE --password MOT_DE_PASSE_POUR_APP
   ```

3. Construire, signer et notariser :

   ```sh
   NABLA_SIGN_IDENTITY="Developer ID Application: Prénom Nom (EQUIPE)" NABLA_NOTARY_PROFILE=nabla ./app/build.sh
   ```

## Licence

MIT : voir [LICENSE](LICENSE).
