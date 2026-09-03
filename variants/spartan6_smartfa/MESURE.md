# Gosof sur Spartan-6 — mesure de place

Synthèse XST 14.7, `xc6slx9-2-tqg144`, sommet `gosof80`, **0 erreur**.

| | utilisé | disponible | |
|---|---|---|---|
| bascules | 592 | 11 440 | 5 % |
| LUT | 1 524 | 5 720 | **26 %** |
| blocs mémoire | 3 | 32 | 9 % |
| broches | 33 | 102 | 32 % |

Fréquence maximale **69,4 MHz** pour une horloge à 50 — la marge est confortable.

## Ce que cette mesure vaut

Elle mesure la **logique**, et elle est juste : les entités, les ports et les
latences sont ceux de l'original, et les mémoires sont réellement instanciées.

Elle ne produit **pas un circuit jouable** : les ROMs de jeu ne sont pas dans le
dépôt amont (BH, Volcano, Mars, Rocky, Striker, DD) et portent ici un motif dérivé
de l'adresse. Le contenu ne change ni la logique ni le nombre de blocs — mais rien
ne sortirait du haut-parleur.

Trois blocs mémoire seulement, et non les 4,5 attendus des 81 Kbit déclarés : XST
place certaines mémoires en LUT (lecture asynchrone, `Mram_time_map`).

## Ce qui reste à mesurer

**Gosof tient. La question ouverte est s'il tient À CÔTÉ de GottFA80** sur le même
FPGA — c'est l'intérêt réel, puisque sur le Smart FA le processeur et le son
partagent une seule puce. WillFA7 seul occupait 75 % des slices ; GottFA80 sur
Spartan n'a pas été mesuré ici.

Tant que ces deux chiffres ne sont pas posés côte à côte, « ça tient » ne veut rien
dire pour l'usage visé.

---

## Remplacer le SC01 factice par un vrai — mesuré

Le `SC01` de Gosof ne synthétise **aucune voix**. Son en-tête le dit :

> *« This is only a simulation of signaling to fool the program that SC01 is there »*

Il imite la poignée de main (strobe / A/R) pour que la ROM du jeu ne se bloque
pas ; la parole vient d'un module **DFPlayer Mini** qui rejoue des enregistrements.

`shufps/votrax-sc01a-vhdl` est un vrai synthétiseur à formants (d'après la
simulation MAME d'Olivier Galibert, BSD-3-Clause — compatible GPL). Synthétisé
seul, sur le même composant :

| | Gosof | SC-01A | somme |
|---|---|---|---|
| bascules | 592 (5 %) | 2 061 (18 %) | 2 653 — **23 %** |
| LUT | 1 524 (26 %) | 2 883 (50 %) | 4 407 — **77 %** |
| blocs mémoire | 3 (9 %) | 6 (18 %) | 9 — **28 %** |
| fréquence max | 69,4 MHz | **56,3 MHz** | — |

**Ça tient**, avec 23 % de LUT de marge. L'interface tombe juste : le cœur expose
`p(5:0)`, `stb` et `ar`, exactement les trois signaux que Gosof câble déjà sur son
SC01 factice.

Le risque n'est pas la place, c'est **l'horloge** : 56,3 MHz pour un besoin de 50,
soit 12 % de marge, et c'est une estimation de synthèse — le placement-routage
fait généralement moins bien. C'est le premier chiffre à surveiller.

Restent deux travaux d'intégration : la sortie audio est un signé 18 bits, là où
Gosof finit sur un DAC 8 bits — il faut mélanger et mettre à l'échelle ; et
`ENABLE_F2N` est à `false` par défaut, ce qui écarte l'une des deux grosses tables
de coefficients (mesure faite dans cette configuration).

⚠️ Et la question qui domine reste entière : **ces chiffres sont Gosof seul, pas
Gosof à côté de GottFA80** sur la même puce.

---

## Sons personnalisés — faisabilité mesurée

Trois voies, très inégales.

### 1. Parole personnalisée par le SC-01A — quasi gratuite, et la plus distinctive

Le SC-01A prend des **codes de phonèmes**. Lui en donner une suite quelconque
produit une phrase quelconque, **sans aucun enregistrement**. Il suffit d'une
table de phrases et d'un séquenceur : quelques dizaines de LUT.

C'est précisément ce que le SC01 factice ne peut pas faire, et ce qu'aucun module
MP3 ne fait — celui-ci rejoue des fichiers, il ne parle pas.

### 2. Échantillons en mémoire interne — court mais immédiat

| | blocs libres | capacité | à 11 kHz 8 bits |
|---|---|---|---|
| Gosof seul | 29 | 65,2 Ko | **6,1 s** |
| Gosof + SC-01A | 23 | 51,8 Ko | **4,8 s** |

Assez pour quelques effets courts. Pas pour de la musique.

### 3. Échantillons depuis la carte SD — le débit suffit, le lecteur non

Le lecteur tourne à **400 kHz**, soit 50 000 o/s en théorie. Sur le papier ça
couvre même du 22 kHz 16 bits (44,1 ko/s). Mais le code lit **octet par octet**
(son propre commentaire dit *« slooow »*) et charge **au démarrage** — quatre
blocs de 4 Ko dans les deux ROMs de 2 Ko. Il n'y a ni double tampon ni diffusion
continue.

Passer `SPI_Taktfrequenz` de 400 kHz à quelques MHz (une carte SD en accepte 25)
et ajouter un double tampon lève la limite. C'est du travail modéré, pas une
refonte.

### Place restante pour tout ça

LUT libres : **4 196 (73 %)** avec Gosof seul, **1 313 (23 %)** si l'on ajoute le
SC-01A. Un lecteur d'échantillons et un mélangeur tiennent dans 23 % ; pas
beaucoup plus.

### ⚠️ Ce que je n'ai PAS pu établir

**Où sort physiquement l'audio de Gosof sur le Smart FA.** Le module ne
documente aucun DAC ni ampli, et `dac.vhd` produit un flux delta-sigma 1 bit qui
demande au minimum un filtre. La seule voie son identifiée sur la carte est
`Audio_RX` (P41), une liaison série **vers l'ESP**.

Ça n'est pas un détail de câblage : si le son passe déjà par l'ESP, alors les
sons personnalisés existent déjà de l'autre côté (GOSOWAV), et la question
devient *où* les faire — pas *si*. À trancher avant d'écrire une ligne de plus.
