# Nabla

Éditeur LaTeX pour Mac (macOS 14+, puce Apple ou Intel) qui compile en local, sans compte ni connexion.

## Ce qu'il fait

- **Projets** : un projet est un dossier ; modèles Article, Rapport, Présentation (Beamer), Exercices et Formule seule.
- **Compilation locale** avec latexmk : références, citations et bibliographie résolues ; XeLaTeX ou LuaLaTeX
  avec `% !TEX program = xelatex` en tête du fichier principal.
- **Erreurs** avec le fichier et la ligne, journal des avertissements.
- **SyncTeX** : ⌘J montre dans le PDF la ligne du curseur ; un double-clic dans le PDF ouvre la source.
- **Éditeur** : coloration, numéros de ligne, recherche et remplacement (⌘F), complétion des commandes,
  des `\ref`, des `\cite` et des environnements, taille du texte (⌘+ ⌘−).
- **Plan du document**, **historique des versions** de chaque fichier, enregistrement à chaque frappe.
- **PDF en sombre** (couleurs inversées, à l'écran et à l'export), mode clair ou sombre.

## Installer

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

## Prérequis

Nabla compile avec la distribution LaTeX du Mac : installer [MacTeX](https://www.tug.org/mactex/)
(ou `brew install --cask mactex-no-gui`). Au premier lancement, Nabla signale ce qui manque.

## Construire

```sh
./app/build.sh && open app/Nabla.app
```

`build.sh` produit une app universelle (puce Apple et Intel), version 1.0 ; le numéro de build est le nombre de commits.

## Tests

```sh
cd app && swift test
```

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
