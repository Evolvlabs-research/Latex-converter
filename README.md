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

## Signer et notariser pour partager l'app

Sans signature, l'app s'ouvre sur le Mac qui l'a construite ; ailleurs, macOS la bloque (clic droit > Ouvrir pour passer outre).
Pour la partager proprement, il faut un compte Apple Developer (99 $/an) :

1. Dans Xcode > Réglages > Comptes, ajouter le compte, puis Gérer les certificats > + > **Developer ID Application**.
   Vérifier qu'il est là : `security find-identity -v -p codesigning`.
2. Créer un mot de passe pour app sur [account.apple.com](https://account.apple.com) (Connexion et sécurité),
   puis enregistrer un profil de notarisation une fois pour toutes :

   ```sh
   xcrun notarytool store-credentials nabla --apple-id ADRESSE --team-id EQUIPE --password MOT_DE_PASSE_POUR_APP
   ```

3. Construire, signer et notariser :

   ```sh
   NABLA_SIGN_IDENTITY="Developer ID Application: Prénom Nom (EQUIPE)" NABLA_NOTARY_PROFILE=nabla ./app/build.sh
   ```

   `build.sh` signe avec le runtime renforcé, envoie l'app à Apple, attend la réponse (quelques minutes),
   agrafe le ticket et laisse `app/Nabla.zip`, à partager. Sans `NABLA_NOTARY_PROFILE`, l'app est seulement signée ;
   sans `NABLA_SIGN_IDENTITY`, rien n'est signé.

## Licence

MIT : voir [LICENSE](LICENSE).
