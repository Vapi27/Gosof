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
