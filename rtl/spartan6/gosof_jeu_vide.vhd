-- gosof_jeu_vide.vhd — le paquet `gosof_jeu` VIDE, celui qu'on peut versionner.
--
-- gosof80 reference toujours le paquet `gosof_jeu`, dans les deux modes. Il en
-- existe donc DEUX versions du meme paquet, et le script de construction en
-- choisit une :
--
--   ce fichier-ci                     -> ROMs a zero. Mode normal : les ROMs de
--                                        jeu arrivent de la carte SD au demarrage.
--   engendre par outils/rom_vers_vhdl -> ROM du jeu, embarquee dans le bitstream.
--                                        Mode SANS_SD, pour le banc.
--
-- Le second contient du code Gottlieb et n'est JAMAIS commite ; celui-ci ne
-- contient que des zeros et peut l'etre.
--
-- JEU_PRESENT est le garde-fou. Construire en SANS_SD avec ce paquet-ci donnerait
-- un 6502 executant 4 Ko de zeros -- ce qui se compile, se place, se charge, et
-- ne dit rien. L'assert de GOSOF80.vhd l'arrete au lieu de le laisser passer.
library ieee;
use ieee.std_logic_1164.all;
use work.gosof_mem.all;

package gosof_jeu is
	constant JEU_PRESENT : boolean := false;
	constant JEU_NOM     : string  := "aucun";
	constant JEU_ROM1 : octet_t(0 to 2047) := (others => (others => '0'));
	constant JEU_ROM2 : octet_t(0 to 2047) := (others => (others => '0'));
end gosof_jeu;
