# Nabla

Éditeur LaTeX pour Mac et Windows qui compile en local, sans compte ni connexion.

https://evolvlabs-research.github.io/Latex-converter/

## Fonctionnalités

- Un projet est un dossier ; modèles Article, Rapport, Présentation (Beamer), Exercices et Formule seule.
- Compilation locale avec latexmk : pdfLaTeX, XeLaTeX ou LuaLaTeX (`% !TEX program = xelatex`).
- Erreurs et avertissements avec le fichier et la ligne.
- SyncTeX entre la source et le PDF.
- Complétion des commandes, des environnements, des `\ref` et des `\cite`.
- Plan du document, historique de chaque fichier, PDF en mode sombre.

## Installer

Télécharger la dernière version sur la page [Releases](../../releases).

**Mac** (macOS 14 ou plus récent) : ouvrir `Nabla-X.Y.Z.dmg` et glisser Nabla dans Applications.
L'app n'est pas notarisée : au premier lancement, l'autoriser dans
Réglages Système › Confidentialité et sécurité › Ouvrir quand même.

**Windows** (10 et 11, 64 bits) : lancer `Nabla-X.Y.Z-installeur.exe`, ou décompresser `Nabla-X.Y.Z-windows.zip`.
Si SmartScreen bloque le premier lancement : Informations complémentaires › Exécuter quand même.

Nabla a besoin d'une distribution LaTeX :

- Mac : [MacTeX](https://www.tug.org/mactex/) ;
- Windows : [MiKTeX](https://miktex.org/download) avec [Strawberry Perl](https://strawberryperl.com),
  ou [TeX Live](https://tug.org/texlive/windows.html).

## Développement

| | Mac | Windows |
|---|---|---|
| Code | [`app/`](app) (Swift) | [`windows/`](windows) (Rust, egui, PDFium) |
| Lancer | `./app/build.sh && open app/Nabla.app` | `cd windows && cargo run --release` |
| Tests | `cd app && swift test` | `cd windows && cargo test` |

La version Windows a besoin de `pdfium.dll` dans `windows/pdfium/`
([pdfium-binaries](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/8125)).

Les changements de chaque version sont dans [CHANGELOG.md](CHANGELOG.md).

## Licence

MIT, voir [LICENSE](LICENSE).
