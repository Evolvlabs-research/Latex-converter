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

1. Télécharger `Nabla.zip` depuis la page des versions (Releases), l'ouvrir, et glisser **Nabla** dans **Applications**.
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

## Publier une version

`./app/build.sh` laisse `app/Nabla.zip`, à joindre à une version (Release) sur GitHub. Sans compte Apple Developer,
l'app est signée « ad hoc » (sans certificat) : macOS l'accepte après l'autorisation décrite dans « Installer ».
Sans cette signature, un Mac à puce Apple déclarerait l'app « endommagée ».

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
