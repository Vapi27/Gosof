# GOSOF sur Spartan-6 — etat au 2026-09-04

Ce fichier dit ce qui est **prouve**, ce qui est **ouvert**, et ce qui reste a faire.
Le detail des mesures est dans `MESURE.md` ; le brochage dans `gosof_v230.ucf`.

## 1. Ce qui est PROUVE, et comment

| fait | preuve |
|---|---|
| Le SC-01A synthetise et la parole est **intelligible** | ENTENDU : « TEST — TURN ALL SWITCHES OFF » |
| Le 6502 execute la ROM du jeu | idem : le ROM ne parle que s'il tourne |
| La carte SD livre une ROM **exacte au bit pres** | le ROM **somme ses deux EPROM** avant de dire cette phrase (`$FA70`, `$FA8A`) ; sinon il dirait « EPROM ONE/TWO FAILS » |
| `cpu_reset_l` est relache au bon moment | idem |
| Toute la chaine audio | SD -> SB_ROM -> T65 -> RIOT -> SC-01A -> `audio_mix` -> `dac_dsm2` -> P67 -> RC -> TDA7267 |
| Le brochage 32 broches de la porteuse 2.30 | P67 mesure a l'analyseur ; le reste par serigraphie + `GottFA80_SLX9.ucf` |
| `PULLUP` sur les cinq lignes de son | R6 (4x4,7K) + R8 (10K) tirent les entrees de l'ULN au +5V -> repos a 00000 |

## 2. LE defaut qui bloquait tout : le bus du SC-01 etait inverse

Une seule ligne, `rtl/spartan6/sc01_glue.vhd` : `p => not cpu_data(5 downto 0)`.

Controle croise en simulation (Volcano, poussoir Test tenu, les quatre phonemes
de la routine `$FA49`) :

| octet ecrit | lu **brut** | lu **inverse** |
|---|---|---|
| `$00` | EH3 — voyelle tenue sans fin | **STOP** |
| 21 | AH1 | **T** |
| 4 | DT | **EH** |
| 32 | A | **S** |

La colonne inversee epelle « T EH S (T) » — la phrase `$FCBC` du ROM, mot pour mot.
Le ROM ecrit ses codes **deja inverses** (`LDA (ptr),Y / EOR #$3F / STA $2000`, fin
testee par `CMP #$C0` = `$FF` inverse) parce que la MA-216 porte des inverseurs
devant P0..P5. L'octet `$00` du reset vaut donc **STOP** — mais lu brut c'est EH3,
**une voyelle que la puce tient a l'infini** : le « AAAH » permanent. **Une cause,
les deux symptomes** (le AAAH et le charabia).

## 3. Ce qui n'est PAS un defaut, et qu'il ne faut pas rechercher

**Les commandes 4 et 16 sont MUETTES chez Mars, par conception du ROM.** Mesure en
simulation, chaque commande maintenue seule depuis un reset propre, 60 ms :

| commande | position de K2 | ecritures DAC | verdict |
|---|---|---|---|
| 1 | S1 (ULN br. 15) | 237 405 | **son franc** |
| 2 | S2 (br. 16) | 244 167 | **son franc** |
| 4 | S4 (br. 17) | **0** | **silence — normal** |
| 8 | S8 (br. 18) | 232 701 | **son franc** |
| 16 | S16 (br. 14) | **0** | **silence — normal** (la routine saute au reset) |

Sur banc, le poussoir S5 ne peut produire qu'une commande a UN bit, celle que
designe le cavalier K2. **Mettre K2 sur S1, S2 ou S8.**

⚠️ Un balayage rapide (20 ms par code) ne vaut RIEN pour ca : un phoneme dure 47 a
250 ms, donc le ROM reste occupe et les codes suivants paraissent muets a tort.
Chaque commande doit etre essayee **seule, depuis un reset**.

## 4. Ce qui reste OUVERT

1. **L'ordre PHYSIQUE des poles de S3 n'a jamais ete mesure.** L'ordre *logique*
   est prouve (manuel recoupe contre le RTL). Mais « pole 1 seul sur ON » — cense
   donner Volcano — laisse le CPU tourner et **S4 muet**, signature d'une famille
   autre que MA-216 : si l'ordre physique etait inverse, `"011111"` donnerait
   MA-490, ou `riot_pb_i(6) <= '0'` rend le poussoir mort. « Tout OFF » (symetrique)
   fonctionne. **A trancher : pole 6 seul sur ON doit donner Volcano si l'ordre est
   inverse.**
2. **U5 n'est pas gravee avec le correctif.** La carte demarre encore sur l'ancien
   firmware quand on coupe l'USB. A graver **43 V coupe**.
3. Attribution D1 <-> `led_1` non prouvee (sans risque electrique).
4. Le module MP3 (DFPlayer) n'est pas exploite : `DFP_Busy => '1'`, et
   `PAROLE_MP3_AUSSI => false` puisque le vrai SC-01A parle.

## 4bis. Deux trous du dossier, trouves en corrigeant l'hybride (2026-09-19)

Ce ne sont pas des defauts du RTL autonome -- il est propre sur ce point -- mais deux raisons
pour lesquelles une faute de ce genre passerait inapercue ici.

1. **Aucune simulation n'exerce une valeur `SB_Opt` non nominale.** `sim/tb_gosof80.vhd:74` et
   `rtl/spartan6/gosof_banc.vhd:127` posent tous deux `SB_Opt => (others => '1')`. C'est le bon
   repos, mais `options = "11"` desactive l'attract : une faute d'affectation des six bits est
   donc **invisible par construction** dans tout ce qui existe aujourd'hui. Si l'on veut que ce
   genre de faute ne repasse plus, c'est la qu'il faut ajouter quelque chose, pas dans le RTL.

2. **Cinq des six affectations de broches de S1 n'ont jamais ete mesurees a l'ohmmetre.** Seule
   `sb_opt<6>` = P127 a une source independante du schema (le journal de bontango, cite en tete
   de `gosof_v230.ucf`). Les cinq autres reposent sur la seule regle de serigraphie. Ce n'est
   pas une correction a faire : c'est une mesure a faire **avant** de s'appuyer dessus -- et
   elle se recoupe avec le point 1 du paragraphe 4 (l'ordre physique des poles de S3).

Pour memoire : l'hybride GottFA80_PLuS, lui, avait un vrai defaut a cet endroit -- six entrees
pour quatre interrupteurs, comblees en dupliquant, ce qui forcait `SB1-1` (« USED IN SELF-TEST
ONLY ») sur ON des qu'on choisissait l'attract a 10 s et rendait l'autotest de la carte son
impossible. Corrige dans `Vapi27/GottFA80_PLuS` (`db4f2b5`). **Ici, `gosof_v230.vhd:205` cable
`SB_Opt => sb_opt` droit : six bits, six broches distinctes, rien a reprendre.**

## 5. Les CINQ defauts de la base pristine, pour l'email a bontango

1. **Le bus du SC-01 n'est pas inverse** : `cpu_data => cpu_dout(5 downto 0)`
   (`GOSOF80.vhd:186` d'origine). Inaudible chez lui — son leurre ne sort aucun son —
   mais cela fausse deja **ses durees de phoneme**, puisqu'il indexe `time_map` avec
   le code inverse.
2. **`SD_Card.vhd` : toute panne de lecture est SILENCIEUSE.** La reponse R1 de
   `CMD18` n'est jamais testee ; la chasse au jeton `0xFE` (`check_for_FE_flag`) n'a
   ni borne, ni compteur d'essais, ni detection de jeton d'erreur ; et l'etat `error`
   devient **inatteignable** des que la lecture commence (ses trois seuls sites sont
   avant CMD18). Un echec laisse donc `cpu_reset_l` a `'0'` pour toujours, **LED SD
   Error eteinte**. C'est le pire mode de panne possible pour un utilisateur.
3. **`SD_Card.vhd` : debordement de compteur** — `counter` est declare
   `range 0 to 5000000` et incremente avant le test, donc toute simulation meurt a
   exactement 100 ms. Inoffensif en synthese, mais gosof80 etait **insimulable**.
4. **`SDcard_error` vaut `'1'` au reset ET a `all_done`** : la LED eteinte ne prouve
   rien du tout.
5. **`LED_2` est du cablage combinatoire pur** (`riot_pa_i(7)` = OU des lignes de
   son) : elle s'allume meme si le processeur n'a jamais demarre.

## 6. Outils produits, reutilisables

- `outils/dis6502.py` — desassembleur 6502 + carte memoire de la MA-216 vue par le
  ROM. C'est lui qui a trouve le self-test parle et le `EOR #$3F`.
- `sim/tb_gosof80.vhd` — generique `TEST_0` (poussoir Test tenu) et decodage des
  phonemes dans `Trace_Sim` (nom du code, **brut et inverse**) : c'est ce decodage
  qui a tranche la polarite.
- `rtl/spartan6/gosof_v230.vhd` — generiques `SANS_SD`, `DIAG`, `SON_INTERNE`.
- `variants/spartan6_smartfa/construire_v230.sh [dir] [jeu.vhd] [SANS_SD] [DIAG] [SON_INTERNE]`.

## 7. Le self-test du ROM : le meilleur outil de diagnostic, et il est gratuit

**S4 « Test » maintenu** fait entrer le ROM dans sa routine de test (`$FA5B` Mars,
`$FA49` Volcano) :

| ce qu'on entend | ce que ca prouve |
|---|---|
| « TEST … TURN ALL SWITCHES OFF » | RAM bonne **et les deux ROM sommees justes** |
| « RAM TEST FAILS » | la RAM du RIOT |
| « EPROM ONE/TWO FAILS » | la ROM chargee depuis la SD est fausse |
| rien | le 6502 ne demarre pas |

⚠️ « TURN ALL SWITCHES OFF » parle du bloc **S1 « Soundcard CFG »**, pas de S3 : tant
qu'un DIP de S1 est sur ON, le ROM **boucle** en `$FAB4` et ne traite plus aucune
commande. Recharger le bitstream pour en sortir.
