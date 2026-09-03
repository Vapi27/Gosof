-- gosof_mem.vhd — equivalents Spartan-6 des megafonctions altsyncram de Gosof.
--
-- Portage Pstore vers XC6SLX9 (carte Smart FA V1.0). Entites et ports
-- IDENTIQUES a l'original Altera : le sommet gosof80 les instancie par leur nom,
-- rien d'autre ne change.
--
-- /!\ LATENCE. Les six memoires de Gosof declarent outdata_reg_a = UNREGISTERED,
--     donc UN seul cycle. C'est une difference avec le portage WillFA7, ou
--     rom_2K.vhd etait a CLOCK0 (deux cycles) alors que ram.vhd etait a un —
--     un ecart invisible dans la liste des ports, et qui decale toutes les
--     lectures d'un cycle si on le rate. Verifie ici fichier par fichier dans
--     les GENERIC MAP de l'original.
--
-- /!\ MODE. RAM et SB_ROM sont en SINGLE_PORT (donc ECRIVABLES : data + wren).
--     SND1, SND2, Qbert1 et Qbert2 sont en ROM (lecture seule, init_file).
--
--   RAM      128 x 8   SINGLE_PORT   UNREGISTERED
--   SB_ROM  2048 x 8   SINGLE_PORT   UNREGISTERED
--   SND1    2048 x 8   ROM  ../ROMs/BH1.hex
--   SND2    2048 x 8   ROM  ../ROMs/BH2.hex
--   Qbert1  2048 x 8   ROM  ./ROMs/qbert1.hex
--   Qbert2  2048 x 8   ROM  ./ROMs/qbert2.hex
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package gosof_mem is
	type octet_t is array (natural range <>) of std_logic_vector(7 downto 0);

	-- Lit un fichier d'un octet hexadecimal par ligne.
	--
	-- QUAND LE FICHIER EST ABSENT, on ne rend PAS des zeros : on rend un motif
	-- derive de l'adresse. Les ROMs de jeu ne sont pas dans le depot amont
	-- (BH1/BH2 = Black Hole, qbert1/2), et une ROM entierement nulle serait
	-- SUPPRIMEE par la synthese — sa sortie est constante. La mesure de place
	-- annoncerait alors un circuit plus petit qu'il ne sera jamais, ce qui est
	-- exactement l'erreur qu'on cherche a eviter en mesurant.
	impure function charger(nom : string; profondeur : natural) return octet_t;
end package;

package body gosof_mem is
	-- Un octet hexadecimal ecrit a la main : `hread` pour std_logic_vector est
	-- une addition VHDL-2008, absente en 93 — et le portage entier tient en 93
	-- pour rester lisible par Quartus comme par XST. Rend -1 si la ligne n'est
	-- pas deux chiffres hexadecimaux (ligne vide, commentaire, fin de fichier).
	function chiffre(c : character) return integer is
	begin
		case c is
			when '0' to '9' => return character'pos(c) - character'pos('0');
			when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
			when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
			when others     => return -1;
		end case;
	end function;

	function deux_chiffres(s : string) return integer is
		variable h, b : integer;
		variable k    : integer := s'left;
	begin
		while k <= s'right and (s(k) = ' ' or s(k) = HT) loop
			k := k + 1;
		end loop;
		if k + 1 > s'right then
			return -1;
		end if;
		h := chiffre(s(k));
		b := chiffre(s(k + 1));
		if h < 0 or b < 0 then
			return -1;
		end if;
		return h * 16 + b;
	end function;

	impure function charger(nom : string; profondeur : natural) return octet_t is
		file f          : text;
		variable etat   : file_open_status;
		variable l      : line;
		variable v      : integer;
		variable m      : octet_t(0 to profondeur - 1);
		variable i      : natural := 0;
	begin
		-- Motif de repli : le poids faible de l'adresse. Non nul, donc la ROM
		-- est reellement instanciee et la mesure de place est honnete.
		for k in m'range loop
			m(k) := std_logic_vector(to_unsigned(k mod 256, 8));
		end loop;
		if nom = "" then
			return m;
		end if;
		file_open(etat, f, nom, read_mode);
		if etat /= open_ok then
			return m;                      -- absent : on garde le motif de repli
		end if;
		m := (others => (others => '0'));  -- le fichier fait foi a partir d'ici
		while not endfile(f) and i < profondeur loop
			readline(f, l);
			v := deux_chiffres(l.all);
			if v >= 0 then
				m(i) := std_logic_vector(to_unsigned(v, 8));
				i := i + 1;
			end if;
		end loop;
		file_close(f);
		return m;
	end function;
end package body;
