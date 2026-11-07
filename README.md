<img src="Resources/AppIcon-1024.png" width="128" alt="Icône de Tézeu : des lèvres closes">

# Tézeu

Petite app de dictée pour Mac, 100 % locale. Tu maintiens une touche, tu parles,
tu relâches : le texte s'écrit dans l'app ouverte. Ta voix et ton texte restent sur ton Mac.

Le nom vient de « taiseux » : quelqu'un qui parle peu et garde tout pour lui.

App originale. Aucun code, nom, logo ou texte d'une autre app de dictée n'a été repris.

> **English** — Tézeu is a 100% offline push-to-talk dictation app for macOS (Apple Silicon).
> Hold a key, speak, release: the text is pasted into the active app. Speech recognition runs
> locally with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) on Metal. No account,
> no telemetry, no network access except the explicit, checksum-verified model download.
> Swift / SwiftUI menu bar app, builds without Xcode. MIT licensed.

État : version 0.1, en développement. Pas encore de version compilée à télécharger :
il faut compiler l'app soi-même (5 minutes, voir ci-dessous).

## Installation

Il faut un Mac à puce Apple (macOS 14 ou plus récent) et les outils en ligne de commande d'Apple
(`xcode-select --install`). Xcode n'est pas nécessaire.

Dans Terminal.app :

```
git clone https://github.com/Sinepel/T-zeu.git tezeu
cd tezeu
./scripts/make-cert.sh   # une seule fois : crée le certificat local « Tezeu Dev »
./build.sh               # télécharge whisper.cpp (66 Mo, empreinte vérifiée), compile, fabrique build/Tezeu.app
open build/Tezeu.app
```

Pour recompiler : `pkill -x Tezeu`, puis `./build.sh`, puis `open build/Tezeu.app`.

### Pourquoi un certificat local

macOS retient l'autorisation Accessibilité pour une app **signée** d'une certaine façon.
Si la signature change à chaque compilation, macOS croit voir une nouvelle app et l'autorisation saute.
`make-cert.sh` crée un certificat « Tezeu Dev » dans ton trousseau, valable 10 ans,
fiable pour ton compte seulement. `build.sh` signe toujours avec lui : la signature reste la même.
Ce certificat ne sert qu'à ce Mac et ne quitte pas le Mac.

Il faut lancer les scripts dans Terminal.app : macOS demande ton mot de passe dans une fenêtre.

## Utilisation

1. Clique sur l'icône de micro dans la barre de menus.
2. Donne les autorisations Micro et Accessibilité (boutons « Autoriser »).
3. Clique sur « Télécharger le modèle » (voir plus bas ce qui est téléchargé).
4. Maintiens **Option droite**, parle, relâche. Le texte est collé dans l'app ouverte.

Dans le panneau, tu peux choisir :
- la touche : Option, Commande ou Contrôle, côté droit ;
- la langue : Français, ou Détection automatique ;
- le modèle : Équilibré (574 Mo), Léger (190 Mo) ou Très léger (60 Mo), si ton Mac est lent.

L'icône montre l'état : micro (prêt), onde (écoute), « … » (transcription), triangle (erreur).

Cas particuliers :
- appui de moins de 0,5 s, ou silence : ignoré, rien n'est collé ;
- autre touche pressée pendant l'appui (un raccourci) : dictée annulée ;
- champ de mot de passe, ou aucun champ de texte actif : l'app ne colle pas, garde le texte
  dans le presse-papiers et passe l'icône en erreur « Collage impossible ». Colle-le toi-même avec ⌘V.

## Autorisations

- **Micro** : pour entendre ta voix, seulement pendant que la touche est maintenue.
- **Accessibilité** : pour détecter la touche dans toutes les apps et envoyer ⌘V.

Réglages Système > Confidentialité et sécurité > Micro / Accessibilité.

## Ce que l'app envoie sur internet

**Rien**, sauf le téléchargement du modèle vocal, et seulement quand tu cliques sur le bouton.

- Source : `huggingface.co/ggerganov/whisper.cpp`, figée sur un commit précis
  (le serveur redirige vers son réseau de diffusion `cdn.hf.co`).
- Session éphémère : ni cookies, ni cache.
- L'empreinte SHA-256 du fichier est vérifiée. Si elle ne correspond pas, le fichier est supprimé.
- Le modèle est rangé dans `~/Library/Application Support/Tezeu/Models`.

Ensuite, l'app ne se connecte plus à rien : pas de mise à jour automatique, pas de statistiques,
pas de rapport d'erreurs. L'audio reste en mémoire et est effacé après la transcription.
Rien n'est écrit dans les journaux sur ce que tu dictes.

Tout le code réseau est dans un seul fichier : `Sources/Tezeu/ModelDownloader.swift`.

## Vérifications

```
# Tests du presse-papiers (sauvegarde et remise), sur un presse-papiers privé
swift run -c release SelfCheck

# Transcription d'un fichier audio, sans micro
say -v 'Eddy (Français (France))' -o /tmp/phrase.aiff "Bonjour, ceci est un test."
swift run -c release SelfCheck transcribe /tmp/phrase.aiff

# Seul endroit du code qui utilise le réseau
grep -rnE 'URLSession|URLRequest|NWConnection|import Network|CFSocket|socket\(|https?://' Sources/

# Connexions de l'app, chaque seconde (rien ne doit s'afficher). Arrêt : Ctrl+C
while true; do lsof -nP -i -a -p "$(pgrep -x Tezeu)"; sleep 1; done
```

## Licences

- **Tézeu** : licence MIT (voir `LICENSE`).
- **whisper.cpp** b5454 (v1.9.5), licence MIT. Version compilée officielle, téléchargée dans `Vendor/`
  par `scripts/fetch-whisper.sh` (non incluse dans le dépôt) :
  https://github.com/ggml-org/whisper.cpp/releases/tag/b5454
  (empreinte SHA-256 de l'archive : `e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b`).
- **Modèles Whisper** (format ggml), licence MIT : https://huggingface.co/ggerganov/whisper.cpp
- Le reste n'utilise que les frameworks d'Apple (SwiftUI, AppKit, AVFoundation, CryptoKit).

## Limites connues

- Sans Xcode, `swift test` ne marche pas : les tests passent par `swift run SelfCheck`.
- Sans Xcode, SwiftUI refuse `@State` : l'état de l'app est gardé dans un simple `let`.
- Le délai avant de remettre l'ancien presse-papiers est fixe (0,4 s). Une app très lente
  pourrait coller l'ancien contenu : il faudrait alors allonger `Paster.restoreDelay`.
- Le seuil de silence est fixe : un micro très faible pourrait être pris pour du silence
  (`AppState.silenceRMS`).
