# Gosof sur Spartan-6 — ce qui est mesuré, et ce qui ne l'est pas

Cible : `xc6slx9-2-tqg144` (Pstore Smart FA V1.0), chaîne ISE 14.7.

Ce fichier ne dit que ce qui a été **mesuré**. La distinction entre « synthétisé »,
« placé-routé » et « entendu sur la carte » est le sujet du document, pas un détail
de présentation : une version précédente publiait une « occupation finale » avec une
marge de timing pour un circuit qui n'avait jamais vu `map`.

---

## 1. Ce qui a tourné sur du vrai silicium

Un seul sommet est allé jusqu'au bout : **`banc_sc01`**, le SC-01A seul, sans le
6502 ni la carte SD.

| | valeur | disponible | |
|---|---|---|---|
| LUT | 3 279 | 5 720 | 57 % |
| bascules | 2 314 | 11 440 | 20 % |
| blocs 18 K | 4 | 32 | 12 % |
| blocs 9 K | 1 | 64 | 2 % |
| fréquence | **56,3 MHz** | besoin 50 | marge 6,3 |

`Timing Score: 0`, « All constraints were met ». Les cinq broches relevées dans le
**rapport de pastilles**, donc ce qui a été *posé* et non ce qui a été *demandé*.
`UnusedPin | Pulldown` confirmé dans le `.bgn` — c'est la ligne qui tient les
grilles des MOSFET de bobines au niveau bas sur une porteuse.

Chargé par USB (`PSTORE SVF`, 341 733 octets en 2,2 s) sur la carte de Valère.

**Ce qui a été ENTENDU :** le battement de cœur à ~1,5 par seconde, dans le
haut-parleur. 50 MHz / 2²⁵ = 1,49 Hz, au dixième près. C'est la seule preuve
matérielle de toute la séance, et elle prouve trois choses d'un coup : le FPGA se
configure, il tourne sur ce design, et son horloge est juste.

**Ce qui n'a PAS été entendu :** la parole. Le montage RC n'était pas en place.

### L'erratum 9 K, vérifié et non supposé

`bitgen` émet `WARNING:PhysDesignRules:2410` dès qu'un `RAMB8BWER` existe. L'Answer
Record 34712 vise en réalité le mode **Simple Dual Port** — pas tout bloc de 9 K.
Le contrôle a donc été déplacé **après le placement** : `construire_banc.sh` ouvre
la netlist placée avec `xdl` et lit le mode réellement configuré.

```
instances RAMB8BWER : 1        (pas 0 : il y avait bien quelque chose a examiner)
inst "Parole/coeur_u_f2v_rom/Mram_..." "RAMB8BWER", placed BRAMSITE2_X3Y48
RAM_MODE::TDP
```

True Dual Port : l'erratum ne s'applique pas. Si un bloc passait un jour en SDP,
le build s'arrête.

⚠️ Une tentative de supprimer *tout* bloc de 9 K en poussant les ROMs en logique
distribuée a **échoué au placement** : `ERROR:Place:543`. Une ROM distribuée
n'occupe que des slices SLICEM, minoritaires sur le LX9 ; 4096 × 18 bits n'y
tiennent pas. Ce n'était pas une question de patience.

## 1 bis. Gosof COMPLET, placé-routé

Premier place-and-route du sommet, sur `gosof_banc` — `gosof80` entier, ROM Volcano
dans le bitstream, séquenceur de codes de son interne.

| | synthèse seule | **après placement** |
|---|---|---|
| LUT | 4 326 (75 %) | **2 968 / 5 720 — 51 %** |
| bascules | 2 702 | 2 460 / 11 440 — 21 % |
| slices occupées | *non mesurable* | **1 022 / 1 430 — 71 %** |
| blocs 18 K | 8 | 6 / 32 |
| blocs 9 K | *non mesurable* | 4 / 64, **aucun en SDP** |
| DSP48A1 | *non mesurable* | **16 / 16 — 100 %** |
| timing | 56,3 MHz estimé | **Timing Score 0**, « All constraints were met » |

Deux enseignements que la synthèse ne pouvait pas donner :

**Elle était pessimiste de 24 points** sur les LUT — 75 % annoncés contre 51 %
réels. Engager une décision sur un chiffre de synthèse, dans un sens comme dans
l'autre, n'a pas de sens.

**Les 16 multiplicateurs sont tous pris.** C'est la vraie contrainte du design, et
elle n'apparaît nulle part avant le placement. Toute fonction ajoutée qui
multiplie devra se replier sur des LUT.

---

## 1 ter. ENTENDU — Gosof complet, sur la carte, le 04/09/2026

**Les sons de Volcano sortent du haut-parleur, et ils sont reconnaissables.**
Le programme d'origine du jeu, execute par le T65 dans le Spartan-6, ecrit son
DAC echantillon par echantillon ; le flux delta-sigma sort sur **P67**, traverse
le filtre R4/C8 de la carte Gosof, le potentiometre R5 et l'ampli TDA7267.

C'est la premiere fois que ce portage produit du son sur du materiel.

### La broche audio : quatre reponses, trois fausses

Le sujet a coute une demi-journee. Le detail vaut d'etre garde, parce que les
trois erreurs sont de trois natures differentes.

| broche | d'ou elle venait | pourquoi c'etait faux |
|---|---|---|
| P4.3 | un battement a 1,5 Hz **entendu** | un creneau plein rail a cette frequence traverse n'importe quel couplage parasite. Ca prouvait qu'il existait UN chemin, pas que c'etait LE chemin audio. |
| P56 | `CONNECTORS_MAP.md:129`, PIN_31 → P4.15 | cette table est exacte, mais elle decrit la **devboard Cyclone 10** de bontango. La porteuse GOSOF 2.30 accueille un **EP2C5T144C8**, un Cyclone II : « PIN_31 » n'y designe pas la meme position. |
| P44 | un test **a l'oreille** a trois hauteurs | demander de distinguer 220/440/880 Hz dans un haut-parleur de flipper ET de retenir l'ordre n'est pas une mesure. Le « je ne suis pas sur » de l'operateur etait la bonne reponse : c'est l'instrument qu'il fallait changer. |
| **P67** | **tracage du cuivre du PCB + analyseur** | ✅ deux methodes independantes, concordantes |

Le tracage a suivi le cuivre depuis la pastille gauche de `R4` : trois nœuds, un
via, arrivee sur la **pastille 24** du connecteur. La mesure a confirme : le
bitstream `trouve_audio` emettait 220 Hz sur P44, 440 sur P56, 880 sur P67, chacun
son tour et les autres en haute impedance ; c'est **880 Hz** qui est apparu sur
`R4` (avec son 3e harmonique a 2 640 Hz, lu 2 600).

⚠️ **Ne jamais retraduire une broche Gosof par `CONNECTORS_MAP.md`.** Ce contrat
fige les POSITIONS de connecteur, pas les fonctions, et il est ecrit pour une
autre carte d'accueil.

### Le montage : il n'y a rien a souder

La carte Gosof porte deja toute la chaine — `R4 3,3K`, `C8 4,7nF` vers la masse,
potentiometre `R5 20K`, `C7 100nF`, ampli `TDA7267`, haut-parleur. C'est exactement
le filtre RC que `dac.vhd:9-16` reclame en commentaire. Le module MP3 (`Audio1`)
injecte sa sortie sur le meme point par `R1`/`C3` : le melange son/parole se fait
en analogique sur cette carte.

### Un piege qui a coute un essai

Le chargement precedent pilotait **quatre** broches avec le meme signal
(P40/P43/P44/P45) et rien ne s'entendait. Sur une porteuse Gosof, trois de ces
positions vont a des fonctions inconnues : une sortie de la carte qui se bat
contre la notre suffit. Une seule broche pilotee, et le reste en haute impedance.

---

## 2. Ce qui a tourné en simulation

### Le SC-01A, neuf captures (ghdl)

| ce qui est vérifié | méthode | résultat |
|---|---|---|
| hauteur ∝ octet du jeu | autocorrélation, 3 points | **0,6 %** |
| durée ∝ 1/horloge (A+AY) | 5 horloges, rapport 3,49:1 | **0,014 %** |
| durée ∝ 1/horloge (BALL) | 3 horloges, énoncé différent | **0,019 %** |
| forme d'onde inchangée | pic identique d'une horloge à l'autre | 30 245 partout |
| phonèmes émis | comptage des strobes | 2/2, 4/4, **8/8** |

### `gosof80` — la première simulation du sommet

Aucune n'avait jamais eu lieu. Elle a répondu à trois questions ouvertes.

**Le T65 exécute la ROM du jeu.** Contrôle croisé, même banc, même circuit, seule
la ROM change :

| jeu | rapport cyclique | plage de fenêtre | niveaux |
|---|---|---|---|
| Volcano | 43,6 % | −130 … 0 | 7 |
| Mars | 63,6 % | −130 … **+65** | 17 |

Deux sons sans rapport, et Mars franchit le milieu que Volcano n'atteint jamais.
Un DAC statique ne peut pas produire ça.

**Le jeu ÉCRIT la page `$3xxx`** — l'horloge du SC-01. 98 écritures en 12 ms, avec
des valeurs qui changent : `127` à 673 µs, puis `192` à 2,37 ms, soit **768 kHz
puis 1 126 kHz**. Conséquence directe : la valeur par défaut `x"A0"` ne décide pas
du timbre de la machine — le jeu le pilote en cours de partie, comme sur la carte
d'origine.

**Le mélangeur n'écrête pas** dans ce scénario : `cycles ecretes=0`. À nuancer —
seuls deux phonèmes ont été strobés, donc la voie parole était presque au repos.
La branche de saturation reste non exercée.

---

## 3. Ce qui n'est PAS établi

À lire avant d'engager quoi que ce soit sur ces chiffres.

- ~~`gosof80` n'a jamais été placé-routé.~~ **Réglé** — voir la section 1 bis.
- ~~Il n'existe aucun `.ucf` pour `gosof80`.~~ **Réglé** — `gosof_banc` réutilise
  `banc_sc01.ucf` (mêmes noms de nets), et le bitstream existe. **Reste à charger.**
- **La PAROLE n'a toujours pas été entendue.** Les sons de jeu, oui — la parole du
  SC-01A, non. Le jeu le strobe bien (7 phonèmes en 100 ms de simulation), mais
  rien ne prouve encore que la voix sorte, ni qu'elle soit juste.
- **La carte SD n'a jamais été lue.** Le chemin SPI, le format d'image et le
  secteur 660 n'ont jamais été exercés sur ce portage.
- **52 des 64 phonèmes** n'ont jamais produit un échantillon.
- **Tous les chemins de générique de `sc01_glue`** sont du code jamais instancié,
  dont le cas majoritaire `speech_en='0'` — toutes les familles sauf MA-216.

---

## 4. Les défauts trouvés, et comment

Tous ont en commun de se compiler, de se placer et de se charger sans un mot.

**Le gain de parole mis à zéro par une largeur.** `audio_mix.vhd` écrivait
`to_signed(SPCH_GAIN, 11)`. Un signé de 11 bits va de −1024 à +1023 : à 1024 le
gain s'**inversait**, à 2048 = 2¹¹ il valait **exactement zéro**. La branche parole
devenait constante et XST supprimait tout le SC-01A — **102 LUT au lieu de 3 242**,
2 525 nœuds retirés, zéro `ERROR`. L'en-tête du fichier disait pourtant « il doit
pouvoir MONTER ». Corrigé : gain sur 16 bits, largeur en générique, `assert` qui
arrête au lieu de tronquer. Et `construire_banc.sh` refuse désormais de continuer
en dessous de 2 000 LUT.

**Un index hors bornes à l'instant zéro.** `speech_ctrl` est déclaré `(31 downto 1)`
et indexé par une valeur qui vaut 0 à 31 — et **0 est l'état de repos** des entrées
son. Le garde à gauche du `and` était censé protéger, mais le `and` de VHDL n'est
pas court-circuitant : les deux opérandes sont évalués. Ça se synthétise sans
broncher et ça ne peut pas se simuler, ce qui explique sans doute que personne ne
l'ait vu — il faut avoir simulé le sommet. **Défaut pristine**, identique dans
`origin/main:GOSOF80.vhd:369`. À signaler à bontango, pas à corriger en silence.

**Deux gardes écrites à l'envers.** `sc01_glue.vhd:86` et l'index ci-dessus. Avec
une métavaleur, une comparaison IEEE rend FALSE et l'on tombe dans la branche non
sûre. Le cas sûr doit être le **défaut**, pas le `else`. Le même piège deux fois
dans la même séance.

**Un latch sans valeur initiale.** `audio_dat_latch` valait `'U'` tant que le 6502
n'avait pas écrit, ce qui propageait `'X'` jusqu'à `Audio_O` : **21 222 métavaleurs
contre 0 valeur utile**. Initialisé à `0x80`, le point de repos exact de la voie son.

**Et une leçon de méthode.** Le premier capteur comptait les `'1'` de `Audio_O`. Un
flux bloqué à `'0'` et un flux à `'X'` donnent le **même** comptage, pour deux pannes
sans rapport. Les bancs mesurent désormais la **répartition des valeurs**, et
`tb_gosof80` échoue bruyamment si le son ne varie pas — un banc qui passe quoi qu'il
arrive ne prouve rien.

---

## 5. Comment refaire ces mesures

```sh
# 1. extraire une ROM de jeu de l'image SD de bontango (HORS du depot)
python3 outils/rom_vers_vhdl.py ~/gosof-roms/volcano_rom1.bin \
        ~/gosof-roms/volcano_rom2.bin ~/gosof-roms/gosof_jeu_volcano.vhd --nom volcano

# 2. simuler le sommet (ghdl). -fsynopsys : T65 utilise std_logic_unsigned.
#    Le paquet du jeu remplace rtl/spartan6/gosof_jeu_vide.vhd dans la liste.
ghdl -a --std=08 -fsynopsys -frelaxed ... ~/gosof-roms/gosof_jeu_volcano.vhd ...
ghdl -e --std=08 -fsynopsys -frelaxed -o tbg tb_gosof80
./tbg -gCODE_1=1 -gCODE_N=31 -gDUREE_US=4000

# 3. le banc SC-01A, jusqu'au SVF (sur la machine qui porte ISE)
sh variants/spartan6_smartfa/construire_banc.sh /tmp/banc_sc01
```

⚠️ Les ROMs de jeu ne sont **pas** dans ce dépôt et ne doivent jamais y être :
code Gottlieb, dépôt GPL destiné à remonter chez bontango. `.gitignore` sert de
filet, la règle passe avant le filet.

⚠️ **Couper le 43 V** pendant chaque configuration du FPGA : `HSWAPEN` étant à la
masse, toutes les broches utilisateur sont tirées au HAUT, et les grilles des
MOSFET de bobines sont actives au niveau haut. Ne jamais alimenter l'USB et P6 en
même temps : même nœud +5 V, sans diode.
