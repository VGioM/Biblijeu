# Biblijeu

Une bibliothèque de jeux pour macOS, dans l'esprit de Biblifilm : elle regarde
vos dossiers de ROM et vos applications, reconnaît les consoles, retrouve les
jaquettes, et lance chaque jeu avec le bon émulateur — en un clic.

```bash
./build.sh          # compile dist/Biblijeu.app
./install.sh        # facultatif : copie dans /Applications
open dist/Biblijeu.app
```

Aucune dépendance externe : `swift build` suffit. macOS 14 minimum.

---

## Ce qu'elle fait

**Répertorie.** Un dossier de ROM (`~/Documents/RetroArch/downloads/ROM`, par
exemple) est parcouru récursivement. Chaque fichier est rattaché à une console
et nettoyé de ses parenthèses de dump. En parallèle, `/Applications` et
`~/Applications` sont lus pour y trouver les émulateurs installés et les jeux
natifs.

**Lance.** Un double-clic sur une vignette démarre l'émulateur adapté avec la
ROM en argument. Le réglage « lancement direct » ajoute les options plein écran
et sans interface quand l'émulateur les accepte — Dolphin démarre alors
directement sur le jeu, DuckStation aussi, et ainsi de suite.

**Illustre.** Les jaquettes rétro viennent de l'archive libretro, qui ne demande
ni compte ni clé. Pour la Switch, les jeux Windows et les jeux macOS — que cette
archive ne couvre pas — une clé SteamGridDB gratuite prend le relais.

**Sauvegarde.** L'onglet « Sauvegarde » trouve où chaque émulateur range ses
sauvegardes et les copie sur le disque de votre choix — à la demande, ou tout
seul : toutes les X minutes, au lancement et à la fermeture. La restauration se
fait dans l'autre sens, à la main.

---

## Comment les consoles sont reconnues

L'extension seule ne suffit pas : `.iso` appartient à la PS2, à la PSP, à la
GameCube, à la Wii, à la Xbox et à la 3DO. Biblijeu croise donc deux signaux :

1. **l'extension**, qui donne une liste de candidates, la plus spécifique
   d'abord (une console qui n'utilise que deux extensions est un meilleur pari
   qu'une qui accepte tous les formats d'image disque) ;
2. **le dossier**, en remontant les parents jusqu'à la racine analysée, à la
   recherche d'un nom de console — `PS2`, `SNES`, `Wii : Wii U`, `3DS`…

Le dossier tranche quand l'extension hésite. Une arborescence rangée par console
est donc reconnue sans configuration.

### Ce qui est volontairement ignoré

- les fichiers de pistes (`.bin`, `.img`) quand un `.cue` ou un `.m3u` les décrit
  déjà — sinon chaque jeu PS1 apparaîtrait deux fois ;
- les dossiers `Updates`, `DLC`, `Mods`, `firmware`, `keys`, `saves`, `states`… ;
- les arborescences d'applications Windows : un dossier qui contient un `.exe`
  à sa racine est indexé comme *un* jeu, et n'est pas exploré plus loin. Sans
  cette règle, un générateur de niveaux Doom ajoute six cents `.wad` de
  prefabs à votre bibliothèque ;
- les `.zip`, sauf dans un dossier qui se déclare `arcade` ou `MAME`.

### Jeux multi-disques

`Final Fantasy VII (France) (Disc 1..3)` forme une seule vignette. Le menu
contextuel et le panneau d'informations permettent de démarrer le disque voulu.

---

## Émulateurs

Un émulateur est reconnu par son `CFBundleIdentifier` (ou, à défaut, par le nom
de son exécutable — VisualBoyAdvance-M n'a pas d'identifiant). Le catalogue
décrit, pour chacun, les consoles qu'il couvre et la façon de lui passer une
ROM :

| Émulateur | Consoles | Lancement direct |
|---|---|---|
| Dolphin | GameCube, Wii | `-b -e <rom>` |
| Cemu | Wii U | `-f -g <rom>` |
| Ryujinx | Switch | `--fullscreen <rom>` |
| DuckStation | PS1 | `-fullscreen -batch -- <rom>` |
| PCSX2 | PS2 | `-batch -fullscreen -- <rom>` |
| PPSSPP | PSP | `--fullscreen <rom>` |
| melonDS | DS | `-f <rom>` |
| Azahar | 3DS | `-f <rom>` |
| ares | ~17 consoles | `--fullscreen <rom>` |
| VBA-M | GB, GBC, GBA | `-f <rom>` |
| Snes9x, OpenEmu, RetroArch | — | la ROM est ouverte comme un document |
| UZDoom / GZDoom | Doom | `-iwad <wad>`, `-file` pour un `.pk3` |
| Xenia Edge | Xbox 360 | `--fullscreen=true <rom>` |
| xemu | Xbox | la ROM est passée en argument |
| RPCS3 | PS3 | `--no-gui <rom>` |
| KytyPS5 | PS5 | aucun : le jeu se choisit dans l'app |
| CrossOver | jeux Windows | `cxstart --bottle <bouteille> -- <exe>` |
| Whisky | jeux Windows | le `.exe` est ouvert comme un document |

### Mises à jour des émulateurs

Le catalogue dit aussi, pour 26 émulateurs, **où leur projet annonce ses
builds** : un dépôt GitHub pour la plupart, son propre site pour Dolphin. Une
fois par jour, Biblijeu leur demande leur version la plus récente.

La section **Mises à jour** de la barre latérale range les émulateurs en trois
groupes — « à mettre à jour », « à jour », « non vérifiables » — avec, pour
chacun, la version installée et celle publiée. Quand la release contient un
fichier macOS reconnaissable, un bouton **Installer** télécharge la nouvelle
build et remplace l'ancienne (voir plus bas) ; la flèche à droite ouvre toujours
la page du projet. Le nombre de mises à jour en
attente s'affiche en orange à droite de la ligne, comme un compteur de bibliothèque.
Le bouton « Vérifier maintenant » force un tour.

La même vue est aussi l'onglet **Réglages → Mises à jour** : une seule
implémentation, pour que les deux ne puissent pas diverger. Elle est bâtie sur
une `List` et non un `Form` — un `Form` groupé réserve une colonne de libellés,
ce qui laisse une large bande vide à gauche de chaque ligne en pleine largeur.

« Tous vos émulateurs sont à jour » n'est écrit que si **tout le monde a
répondu**. S'il reste des muets, le résumé le dit : un silence général ne doit
pas se lire comme une bonne nouvelle.

Les projets sont interrogés **un par un**, pas en parallèle : un tour fait une
quinzaine de questions et prend quelques secondes de toute façon, alors qu'une
rafale peut être lue comme un abus par un limiteur de débit. Personne n'attend
la réponse.

La cadence est **une fois par jour civil**, au premier lancement de la journée :
les lancements suivants du même jour ne redemandent rien, et demain repart à
minuit. Une fenêtre glissante de 24 h dériverait chaque jour un peu plus tard
jusqu'à tomber au milieu d'une soirée de jeu. Seule exception : un tour où
quelqu'un s'est tu n'est pas la réponse du jour, et il est refait dans l'heure —
qui est aussi le délai de réarmement du quota GitHub.

Aucun dépôt n'est deviné à partir d'un nom : un mauvais répondrait avec les
numéros de version de quelqu'un d'autre, ce qui est pire que se taire. Les
émulateurs dont le projet n'a pas pu être identifié (Citra, archivé ; Ryujinx,
dont les dépôts GitHub ont disparu) ou qui se mettent à jour eux-mêmes
(CrossOver) n'ont simplement pas de source.

La comparaison est volontairement timide. Deux numéros ne veulent dire quelque
chose l'un à côté de l'autre que s'ils sont comptés pareil : `2.6` est complété
en `2.6.0` pour que Cemu ne paraisse pas en retard sur sa propre release, mais
`0.289` face au tag `mame0289` donne **« non comparable »** plutôt qu'une
réponse inventée. De même pour les builds glissantes — DuckStation ne publie
qu'une release nommée `latest` — où seule la date de publication est affichée.
Être en avance sur la dernière version stable (une nightly PCSX2) n'est pas
être en retard.

Deux détails valent d'être connus :

- Le **nom** de la release est lu avant son tag, parce que les projets taguent
  comme ils veulent (`mame0289`, `astris-1.0.27`, `g4.14.2`) alors que le nom
  est presque toujours la version nue. Et c'est la suite de nombres **la plus
  longue** qui est retenue, pas la première : sinon « Snes9x 1.63 » se lirait
  version 9.
- Quand les numéros ne permettent rien — et **seulement** dans ce cas — le
  calendrier prend le relais : la date de publication du projet contre celle de
  la build installée. La ligne dit alors explicitement « comparé par date », car
  une date de fichier est un argument plus faible qu'un numéro de version. Cette
  date est la plus récente parmi le dossier du bundle, sa création, et son
  exécutable, parce que chacune ment à sa façon : une app glissée une fois garde
  sa date de création, une app qui se met à jour sur place (DuckStation) ne fait
  bouger que sa date de modification, et un bundle dont on a remplacé le contenu
  peut garder un dossier daté de deux ans avant le binaire qu'il contient — ce
  que fait `ares.app`.
- Un numéro isolé au milieu de plusieurs suites est **refusé**. Xenia Edge tague
  ses builds par hash de commit (`1d46d61`) et KytyPS5 par date
  (`KytyPS5-2026-09-14-a9ae04c`) : y lire « version 1 » et la déclarer égale au
  `1.0` installé était précisément la réponse inventée que tout ce mécanisme
  existe pour éviter. Ces projets tombent en « non comparable », avec la date de
  leur dernière build — qui est l'information utile.
- GitHub répond à soixante questions par heure et par adresse ; un tour en
  coûte une par émulateur. Un projet injoignable **garde la réponse du tour
  précédent**, repesée contre la version installée du moment, au lieu de
  disparaître — sans quoi le silence passerait pour « tout est à jour ». Les
  muets sont nommés sous la liste.

### Installation et signature automatiques

Deux réglages, en tête de la vue **Mises à jour**, tous deux activés par défaut :

- **Installer automatiquement les mises à jour.** Après le tour du jour, chaque
  émulateur « à mettre à jour » est téléchargé et remplacé, un par un. Le
  fichier est choisi parmi ceux de la release (GitHub) ou du flux Dolphin par un
  score : il doit ressembler à une build Mac (`mac`, `macos`, `osx` ou un
  `.dmg`), sans mot d'une autre plateforme, de symboles de débogage, de source ou
  de cœur libretro ; la build pour le processeur du Mac passe devant l'universelle,
  qui passe devant celle de l'autre processeur ; `unsigned`, `experimental`,
  `legacy` reculent d'un point. `.dmg` (hdiutil), `.zip` (ditto), `.tar.*` et
  `.7z` (tar / libarchive) sont ouverts, y compris une archive dans l'archive.
  Garde-fou : l'app trouvée doit porter **l'identifiant de bundle de
  l'émulateur**, sinon rien n'est installé. La nouvelle build est posée à côté
  de l'ancienne, sous son propre nom (PCSX2 met sa version dans le nom du
  bundle) ; l'ancienne part à la **Corbeille**, et revient en place si la copie
  échoue. Un émulateur **ouvert n'est jamais remplacé**. Une build n'est tentée
  automatiquement **qu'une fois** (`auto-installs.json`) : si elle ne prend pas,
  c'est le bouton qui reste, plutôt qu'un téléchargement à chaque lancement.
  Les verdicts « non comparable » ne déclenchent rien.
- **Signer automatiquement les émulateurs.** Ce que l'on faisait à la main
  après chaque mise à jour : si la signature tient (`codesign --verify --deep
  --strict`), seule la quarantaine est levée ; sinon les attributs étendus sont
  effacés (`xattr -cr`, sans quoi codesign refuse les « detritus » de Ryujinx)
  et l'app est signée ad hoc (`codesign --force --deep --sign -
  --preserve-metadata=entitlements`, pour garder le droit au JIT). Une app
  signée Developer ID garde sa signature. Le contrôle a lieu après chaque
  installation, et à chaque analyse pour tout émulateur **dont l'exécutable a
  changé** depuis la fois précédente (`signatures.json`) — ce qui couvre les
  émulateurs qui se mettent à jour eux-mêmes et ceux ajoutés à la main. La toute
  première fois, les émulateurs présents sont seulement notés, pas modifiés :
  ils fonctionnent tels quels.

Clic droit sur une ligne : « Vérifier et signer l'app » fait la même chose à la
demande, pour n'importe quel émulateur.

Limites : RPCS3 publie ses builds Mac dans un autre dépôt que ses versions, et
Ryujinx n'a pas de source — pour eux, la page reste le chemin.

### CrossOver : bouteilles et raccourcis

Biblijeu lit les bouteilles de CrossOver — `~/Library/Application
Support/CrossOver/Bottles` et son équivalent système — et le menu Démarrer de
chacune. Un jeu Windows déjà installé dans une bouteille est donc lancé par son
propre raccourci, dans la bonne bouteille, au lieu d'être passé à CrossOver
comme un document — ce qui faisait répondre à CrossOver qu'il n'avait pas de
bouteille pour l'ouvrir.

- un `.exe` trouvé par l'analyse des dossiers garde sa place dans la
  bibliothèque, avec son historique et ses favoris ; il gagne l'icône que
  CrossOver a extraite du jeu, et se lance par le raccourci de la bouteille ;
- un jeu installé *dans* une bouteille, que l'analyse des dossiers ne peut pas
  voir, apparaît comme une vignette à part entière ;
- les entrées qui ne sont pas le jeu (`Uninstall`, `Updater`, `Readme`…) sont
  laissées de côté ;
- quand rien ne désigne la bouteille — plusieurs bouteilles, et un `.exe`
  qu'aucune n'a installé — le panneau d'informations en propose le choix.

### Reprendre sur une sauvegarde d'état

Le réglage **Lancement → « Reprendre la sauvegarde d'état au lancement »**
(activé par défaut) fait démarrer le jeu là où il s'était arrêté, quand
l'émulateur sait le faire depuis la ligne de commande :

| Émulateur | Reprise | Argument |
|---|---|---|
| DuckStation | la sauvegarde que la dernière partie a écrite, quel que soit le disque | `-statefile <fichier>` |
| DuckStation | à défaut, la sauvegarde la plus récente de ce jeu | `-resume` |
| PCSX2 | la sauvegarde écrite en quittant (`.resume.p2s`) | `-state -1` |
| DuckStation, PCSX2 | un emplacement numéroté (1 à 10) | `-state <n>` |
| Dolphin | un fichier que vous désignez | `--save_state=<fichier>` |
| PPSSPP | un fichier que vous désignez | `--state=<fichier>` |
| melonDS, ares, Cemu, Ryujinx, Azahar, Snes9x, OpenEmu… | — | l'émulateur n'expose rien |

Ces lignes ne sont pas des suppositions : `-help` de chaque émulateur installé
dit ce qu'il sait faire, et seuls DuckStation et PCSX2 ont la notion d'une
sauvegarde « de reprise » écrite en quittant. Un émulateur reconnu par son
Info.plist mais absent du catalogue reçoit le lancement par document, qui ne
demande aucune connaissance de sa ligne de commande — et n'en offre donc aucune
reprise.

**Les jeux à plusieurs disques.** Un émulateur classe ses sauvegardes d'état
sous le numéro de série du disque présent dans le lecteur, pas sous le fichier
qu'on lui a donné. Metal Gear Solid terminé sur le disque 2 range donc sa
progression sous `SLES-11506`, là où « démarre le disque 1, puis reprends » ne
la trouvera jamais : le joueur revient sur un état vieux de plusieurs heures.

Biblijeu lit donc le dossier d'états de l'émulateur. Une sauvegarde DuckStation
contient en clair le chemin du disque sur lequel elle a été prise, ce qui permet
de rattacher un état à un jeu avec certitude — et de rendre la main sur le bon
disque. `-statefile` seul suffit à DuckStation, qui remonte le disque depuis
l'état : lui passer la ROM en plus est précisément ce qui ramenait au disque 1.

Le panneau d'informations nomme la sauvegarde qui sera chargée, et sa date.
Un émulateur qui ne sait rien reprendre démarre le jeu au lieu de refuser.

### L'icône

`Resources/AppIcon.icon` est un paquet Icon Composer : `icon.json` décrit le
fond et le calque de la manette, `Assets/glyph.png` porte la forme. `build.sh`
le compile avec `actool` en un `Assets.car` qui contient les rendus clair,
sombre et teinté — le seul format sur lequel macOS 26+ tient compte du thème,
un `.icns` seul en étant incapable. `Resources/AppIcon.icns`, complet de 16 à
1024, reste le repli pour les macOS antérieurs et pour une machine sans Xcode.

### Déplacer la bibliothèque

Rien n'est ancré à un chemin :

- **Les ROM** — un jeu est identifié par son nom de fichier et sa taille, pas
  par le dossier qui le contient. Déplacer la bibliothèque sur un disque
  externe conserve favoris, jaquettes, historique et sauvegardes repérées. Il
  suffit de pointer le nouveau dossier dans **Réglages → Sources**.
- **Le dossier d'états** — il appartient à l'émulateur, pas à Biblijeu, et se
  déplace dans les réglages de l'émulateur. Biblijeu lit le `[Folders]` de
  `DuckStation/settings.ini` et de `PCSX2/inis/PCSX2.ini` pour savoir où il est
  parti, chemin absolu comme relatif. Aucun réglage à tenir à jour de ce côté.
- **Le disque à démarrer** — une sauvegarde nomme le disque sur lequel elle a
  été prise, mais avec le chemin qu'il avait alors. Biblijeu ne rapproche donc
  que les noms de fichiers, et redonne à l'émulateur le disque à son
  emplacement du jour.

Le panneau d'informations propose le choix par jeu ; le bouton ⏮ à côté de
« Reprendre » démarre depuis le début, tout comme ⇧↩ et le menu contextuel.

L'ordre de préférence par console est dans `SystemCatalog`; il est modifiable
console par console dans **Réglages → Émulateurs**, et jeu par jeu dans le
panneau d'informations.

Le lancement passe par `NSWorkspace.openApplication`, pas par `Process` : c'est
la façon dont macOS démarre une application graphique, avec son Dock, ses
permissions et son cycle de vie normaux. Le panneau d'informations affiche
malgré tout la ligne de commande équivalente, copiable — utile pour comprendre
ce qui est réellement exécuté.

---

## Sauvegarde

L'onglet **Sauvegarde** — dans la barre latérale, et dans les réglages — sert à
garder ses sauvegardes ailleurs que sur le Mac.

**Il trouve les dossiers lui-même.** Chaque émulateur du catalogue déclare où il
range ses sauvegardes : cartes mémoire, fichiers de sauvegarde, sauvegardes
d'état, NAND, carte SD virtuelle. Rien n'est inventé — un chemin n'est affiché
qu'une fois trouvé sur le disque, et quand l'émulateur écrit lui-même l'endroit
dans sa configuration (`[Folders]` de PCSX2 et DuckStation, `Paths` d'ares,
`vbam.ini`), c'est cette réponse qui gagne. Un dossier déplacé est donc suivi
sans réglage supplémentaire.

Un émulateur absent du catalogue est un émulateur dont les sauvegardes vivent
dans le dossier du jeu (DOSBox, Boxer) ou qui n'expose rien de sûr : nommer un
mauvais dossier sauvegarderait la mauvaise chose, ce qui est pire que de ne rien
sauvegarder.

**Les sauvegardes posées à côté du jeu.** ares, melonDS, mGBA et VBA-M n'ont pas
de dossier à eux : par défaut, la sauvegarde d'un jeu est écrite dans le même
dossier que le jeu. Ce sont donc les plus faciles à perdre, et les seules qu'on
ne peut pas sauvegarder en copiant un dossier — le dossier, c'est la ludothèque.

Les dossiers de ROM sont donc parcourus à la recherche des *fichiers* de
sauvegarde, reconnus à leur extension : `.srm`, `.sav`, `.dsv`, `.rtc`, les
`.eep`/`.fla`/`.mpk`/`.sra` de la Nintendo 64, les cartes mémoire PlayStation
`.mcr`/`.gme`, et séparément les états (`.ss0`…`.ss9`, `.st0`…`.st9`, `.mln`,
`.sgm`, `.state`). Les ROM elles-mêmes ne sont jamais copiées : sur une
ludothèque de 94 Go, la copie a porté sur les seuls fichiers de sauvegarde, et
un parcours complet coûte trois dixièmes de seconde. L'arborescence est
conservée (`roms/<dossier>/saves/GBA/Jeu.srm`), donc une restauration remet
chaque fichier à côté de son jeu.

**Ça se tient à jour tout seul.** La liste est relue à chaque retour dans
Biblijeu, quand un dossier de ROM est ajouté ou retiré, quand un émulateur
apparaît ou disparaît, et avant chaque copie. Un émulateur essayé pour la
première fois — RPCS3 qui crée son `dev_hdd0` en démarrant — se retrouve
sauvegardé à la copie suivante sans que rien n'ait été réglé. Un émulateur
désinstallé garde ses sauvegardes dans la liste, marquées « émulateur absent ».

**Les copies vont dans un dossier à nous.** Dans le dossier choisi, et jamais à
sa racine : `<votre dossier>/Biblijeu Sauvegardes/<émulateur>/<type>/`. Le nom
vient de l'émulateur et du type, pas du chemin, donc la sauvegarde reste
utilisable même après un déménagement de dossier — ou sur un autre Mac. Un
`Biblijeu.json` posé à côté dit ce que le disque contient, quand, et d'où ça
vient : il décrit *ce disque*, ce qui reste vrai si vous en avez deux.

**Ce qui est copié se choisit par catégorie.** Une case par type de dossier,
avec ce qu'il contient et ce qu'il pèse :

| Catégorie | Contenu | Par défaut |
|---|---|---|
| Sauvegardes | le fichier de sauvegarde du jeu | ✓ |
| Sauvegardes d'état | l'instantané de la machine | ✓ |
| Cartes mémoire | GameCube, PlayStation, PS2 | ✓ |
| Mémoire système | NAND, EEPROM, NVRAM — les sauvegardes Wii, 3DS et arcade y vivent | ✓ |
| Carte SD | la carte SD virtuelle d'un émulateur Switch ou 3DS | ✗ |

La carte SD est la seule décochée, et c'est la seule raison pour laquelle elle
existe comme catégorie à part : c'est là que vont les jeux, mods et DLC
*installés* dans l'émulateur — des copies de jeux, pas des sauvegardes. Pour ne
garder littéralement que les deux premières, il suffit de décocher les deux
suivantes — au prix de vos cartes mémoire PS1/PS2/GameCube et de vos
sauvegardes Wii, qui vivent précisément là.

L'index des sauvegardes de Ryujinx (`saveMeta`) compte parmi les sauvegardes et
non parmi la mémoire système : c'est lui qui dit à quel jeu appartient chaque
dossier numéroté, et une sauvegarde restaurée sans lui n'est rattachée à rien.

**Aucune ROM n'est jamais copiée**, quelle que soit la case cochée : le dossier
d'un émulateur ne contient pas de jeu, et dans un dossier de ROM seuls les
fichiers de sauvegarde sont lus.

**Rien n'est jamais supprimé.** La copie est incrémentale — un fichier de même
taille et de même date n'est pas recopié, donc une sauvegarde toutes les dix
minutes ne coûte qu'un parcours de dossiers — mais elle n'efface rien à
l'arrivée. Une carte mémoire corrompue, un profil réinitialisé, un jeu
désinstallé : la copie reste, et c'est toute la raison d'en avoir une.

**L'automatique ne va que dans un sens.** Des émulateurs vers le disque, jamais
l'inverse : restaurer remplace une partie par une plus ancienne, et c'est
exactement l'accident que cet onglet existe pour éviter. « Restaurer » se
demande donc à la main, avec confirmation, émulateur par émulateur ou en bloc.

| Déclencheur | Réglage |
|---|---|
| Toutes les X minutes | 1 à 720, 30 par défaut |
| Au lancement de Biblijeu | activé, après l'analyse des émulateurs |
| À la fermeture de Biblijeu | activé, avec un délai de 20 s maximum |
| À la demande | « Sauvegarder maintenant », ou par émulateur |
| Au retour dans l'app | relecture de la liste (pas de copie) |

La fermeture attend la copie, mais jamais indéfiniment : passé le délai, la
copie est interrompue et l'application se ferme. Les sauvegardes sont toujours
sur le Mac, et le lancement suivant les copiera.

**Disque débranché.** L'état normal d'un disque externe, pas une erreur : les
sauvegardes automatiques sont ignorées et la barre latérale affiche un témoin
orange à côté de « Sauvegarde ». Rien n'est créé, rien n'est signalé en alerte.

---

## Jaquettes

**libretro** (`thumbnails.libretro.com`) publie ses vignettes sous les noms
No-Intro / Redump, exactement ceux que portent la plupart des dumps. L'index
d'une console est téléchargé une fois, gardé un mois sur disque, puis comparé au
nom du fichier :

- correspondance exacte du nom complet normalisé → certain ;
- sinon, correspondance du titre sans parenthèses, départagée par la région
  préférée ;
- sinon, similarité de Jaccard sur les mots, au-delà de 0,72.

Un malus écarte les variantes `(Demo)`, `(Beta)`, `(Alt)` que la ROM ne réclame
pas — c'est ce qui fait que `Tekken 3 (Europe) (Alt).cue` reçoit la jaquette de
`Tekken 3 (Europe)` et non celle de la démo.

Un nom de dump inhabituel passe quand même :
`Super-Mario-Sunshine-Europe-En-Fr-De-Es-It.rvz` se normalise en la même chaîne
que `Super Mario Sunshine (Europe) (En,Fr,De,Es,It)`.

**SteamGridDB** couvre le reste. La clé est gratuite :

1. créer un compte sur <https://www.steamgriddb.com> (connexion Steam, Google
   ou Discord, aucune inscription à remplir) ;
2. ouvrir <https://www.steamgriddb.com/profile/preferences/api> et cliquer
   **Generate API key** ;
3. coller la clé dans **Réglages → Jaquettes**, puis **Tester la clé**.

Sans elle, les titres Switch et les jeux Windows restent sur une vignette de
remplacement.

**Les applications** utilisent l'icône que macOS leur connaît déjà : instantané,
et généralement plus juste qu'une jaquette trouvée en ligne.

À tout moment : *Rechercher* relance la recherche, *Autre titre…* la relance
sous un nom que vous choisissez, *Image…* impose un fichier local.

---

## Diagnostic

L'application répond aussi en ligne de commande :

```bash
dist/Biblijeu.app/Contents/MacOS/Biblijeu --scan ~/Documents/RetroArch/downloads/ROM
```

affiche les émulateurs détectés, les jeux trouvés par console, et **la commande
exacte** qui serait lancée pour chacun. Avec `--covers`, il résout aussi les
jaquettes et imprime leurs URL. C'est le premier réflexe quand une ROM
n'apparaît pas, ou apparaît sous la mauvaise console.

```bash
dist/Biblijeu.app/Contents/MacOS/Biblijeu --updates
```

pose aux projets la même question que les réglages, et imprime le raisonnement :
version installée, version publiée, et le verdict — « à jour », « ▲ disponible »
ou « non comparable » avec la raison — et le fichier macOS qui serait installé.

```bash
dist/Biblijeu.app/Contents/MacOS/Biblijeu --install astris
dist/Biblijeu.app/Contents/MacOS/Biblijeu --install astris /tmp/essai/Astris.app
```

installe la dernière build comme le bouton. Avec un chemin, c'est cette copie
qui est remplacée : de quoi essayer sur un double avant l'app elle-même.

```bash
dist/Biblijeu.app/Contents/MacOS/Biblijeu --saves
dist/Biblijeu.app/Contents/MacOS/Biblijeu --saves --to /Volumes/Jeux
```

imprime, pour chaque émulateur, les dossiers de sauvegarde trouvés, leur taille
et leur nom dans la sauvegarde — et liste ceux pour lesquels rien n'a été
trouvé, ce qui est la façon de voir qu'un chemin du catalogue est faux. Avec
`--to`, il copie pour de bon, par le même moteur que l'onglet : de quoi essayer
un dossier avant de lui confier un disque.

---

## Architecture

```
Sources/Biblijeu/
  Models/
    GameSystem.swift      catalogue des consoles : extensions, alias de dossier,
                          dossier libretro, émulateurs préférés
    Emulator.swift        catalogue des émulateurs : identifiants et arguments
    GameItem.swift        une vignette (ROM, jeu natif, émulateur)
  Core/
    RomScanner.swift      parcours des dossiers, résolution des consoles,
                          regroupement des disques
    ApplicationScanner.swift  lecture de /Applications
    Launcher.swift        construction de la commande et démarrage
    LibraryModel.swift    état de la fenêtre : sections, tri, recherche
    PlayStore.swift       favoris, historique, choix d'émulateur, jaquettes
    NameParser.swift      nettoyage des noms de dumps
    ArtworkCache.swift    cache disque + mémoire des images
    ScanReport.swift      les modes --scan, --updates, --install et --saves
    SaveCatalog.swift     où chaque émulateur range ses sauvegardes
    BackupEngine.swift    la copie incrémentale, dans un sens ou dans l'autre
    BackupManager.swift   destination, minuterie, lancement, fermeture, manifeste
    ConfigFile.swift      lecture d'un réglage dans la configuration d'un émulateur
    UpdateChecker.swift   versions publiées, verdicts, choix du fichier macOS
    EmulatorInstaller.swift  téléchargement, décompression, remplacement, signature
  Artwork/
    LibretroThumbnails.swift  index et appariement
    SteamGridDBProvider.swift
    ArtworkService.swift      orchestration
  Views/                  SwiftUI, sombre, calqué sur Music.app
```

Les données personnelles vivent dans
`~/Library/Application Support/Biblijeu/` : `play-state.json` (favoris,
historique, jaquettes résolues), `Artwork/` (images), `ThumbnailIndex/` (index
libretro). Les réglages sont dans `com.biblijeu.app` (UserDefaults).

## Pièges déjà rencontrés

- **`.wad` appartient à Doom, pas à la Wii.** Les dumps de chaînes Wii sont
  rares, les wads Doom ne le sont pas ; la Wii a perdu cette extension.
- **Un dossier d'outil ressemble à une ludothèque.** D'où la règle « un `.exe`
  à la racine ⇒ un seul jeu, on n'explore pas ».
- **`Switch.app` n'est pas un émulateur.** C'est un convertisseur audio de NCH,
  qui se déclare `public.app-category.music`. La catégorie déclarée par l'app
  est un signal fiable ; le nom ne l'est pas.
- **Une image en `.fill` déborde de sa vignette.** Dans une `ZStack`, elle
  renvoie au parent une taille plus grande que la case, et la grille se
  chevauche. La vignette est donc dimensionnée par un `Color.clear` et la
  jaquette posée en `.overlay` — un overlay n'influence jamais la taille de ce
  qu'il recouvre.
- **`Mes documents` d'une bouteille CrossOver est un lien vers `~/Documents`.**
  Sauvegarder ce dossier-là copierait tout le dossier Documents du Mac, ROM
  comprises. Il est donc absent du catalogue, et le moteur de copie ne suit
  jamais un lien symbolique — ni ne le copie, car restauré ailleurs il
  désignerait le dossier de quelqu'un d'autre.
- **Un dossier de ROM de 94 Go ne se copie pas.** D'où le filtre par extension
  pour les sauvegardes posées à côté du jeu — et le fait que la copie filtrée ne
  recrée pas l'arborescence des dossiers vides au passage, sinon la sauvegarde
  contiendrait le plan complet de la ludothèque pour trois fichiers.
- **Le dossier de sauvegarde peut être dans le dossier de ROM.** ROM et
  sauvegardes sur le même disque externe, et la copie se met à copier ses
  propres copies, indéfiniment. Le moteur refuse donc d'entrer dans son propre
  dossier de destination.
- **La première sauvegarde ne copiait rien.** Elle part dès que les émulateurs
  sont connus, c'est-à-dire pendant que l'analyse des dossiers est encore en
  cours : la liste lue était vide, et « rien à copier » passait pour une
  réussite. Une analyse en vol s'attend, elle ne se contourne pas.
- **Les espaces dans les URL de jaquettes.** L'encodage doit produire `%20` ;
  laisser l'espace tel quel fait échouer `URL(string:)` en silence, et la
  vignette reste vide sans erreur.
