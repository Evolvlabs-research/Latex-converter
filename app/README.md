# Nabla

Éditeur LaTeX pour Mac (macOS 14+) qui compile en local et lit les formules manuscrites.

## Construire

```sh
./app/build.sh && open app/Nabla.app
```

Le modèle de lecture est embarqué dans l'app (`Contents/Resources/Model`, Core ML) : une fois construite,
Nabla n'a besoin ni de Python ni du dépôt. Seule la compilation de LaTeX demande MacTeX
(`brew install --cask mactex-no-gui`).

Le modèle Core ML vient de `checkpoints/best.pt`. `build.sh` l'exporte dans `app/Model/` s'il manque ;
après un nouvel entraînement, l'exporter de nouveau :

```sh
uv run export_coreml.py --reference 100
```

`--reference 100` régénère aussi les fichiers du test qui compare Swift et Python (`app/Tests/Notes2LaTeXTests`).

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
