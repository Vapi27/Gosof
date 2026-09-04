-- tb_gosof80.vhd — le banc du SOMMET. Le seul qui fasse tourner le jeu.
--
-- CE QU'IL REPOND, ET QU'AUCUNE SYNTHESE NE PEUT REPONDRE :
--   1. le T65 demarre-t-il et execute-t-il la ROM du jeu ?
--   2. le jeu ECRIT-IL la page $3xxx -- l'horloge du SC-01 ? Si oui, le timbre
--      est pilote en cours de partie et le defaut x"A0" ne decide de rien. Si
--      non, c'est ce defaut-la qui fixe la voix de toute la machine.
--   3. le melangeur ECRETE-t-il en pratique ? La saturation est indispensable,
--      mais on ignorait si elle etait atteinte -- donc si sa forme comptait.
--
-- Il exige SANS_SD=true et le paquet gosof_jeu ENGENDRE (pas le vide) : sans
-- carte SD, SD_Card.vhd:255 ne relacherait jamais cpu_reset_l. Le garde-fou de
-- GOSOF80 arrete la simulation si on se trompe de paquet.
--
-- Audio_O est un flux 1 bit a 50 MHz. On ne l'echantillonne pas, on le FILTRE :
-- somme des '1' par fenetre, comme le fera le RC 3,3 kOhm / 4,7 nF.
--
-- ⚠️ CONTROLE NEGATIF. Ce banc ECHOUE si le son est constant. C'est deliberé :
--    un banc qui « passe » quoi qu'il arrive ne prouve rien, et cette seance a
--    deja produit trois temoins qui disaient oui sans rien mesurer. Un flux
--    bloque a '0' et un flux a 'X' donnent d'ailleurs le MEME comptage de '1' --
--    d'ou la repartition par valeur, et pas un simple compteur.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_gosof80 is
	generic (
		FICHIER : string  := "gosof.txt";
		FENETRE : integer := 260;          -- 50 MHz / 260 ~= 192,3 kHz
		JEU     : string  := "111110";     -- Volcano (MA-216)
		-- Balayage des codes de son : de CODE_1 a CODE_N, DUREE chacun.
		CODE_1  : integer := 1;
		CODE_N  : integer := 8;
		-- En MICROSECONDES, pas en `time` : ghdl refuse de surcharger un generique
		-- de type time en ligne de commande (« unhandled type for generic override »).
		DUREE_US : integer := 4000;
		-- Le reset interne se relache a 2^16 cycles = 1,31 ms.
		DEBUT_US : integer := 2000;
		REPOS_US : integer := 1000;
		-- pour le controle croise de la double parole
		MP3_AUSSI : boolean := false
	);
end tb_gosof80;

architecture essai of tb_gosof80 is
	signal clk     : std_logic := '0';
	signal audio_o : std_logic;
	signal son     : std_logic_vector(4 downto 0) := "00000";
	signal jeu_v   : std_logic_vector(5 downto 0);
	signal led0, led1, led2, dfp_tx, sd_cs, sd_mosi, sd_clk : std_logic;
	signal fini    : boolean := false;
begin
	clk <= not clk after 10 ns;

	-- le numero de jeu, depuis la chaine du generique
	g : for i in 0 to 5 generate
		jeu_v(5 - i) <= '1' when JEU(JEU'left + i) = '1' else '0';
	end generate;

	dut : entity work.gosof80
		generic map (SANS_SD => true, TRACE => true, PAROLE_MP3_AUSSI => MP3_AUSSI)
		port map (
			clk_50 => clk, reset_sw => '1', test => '1',
			Audio_O => audio_o, Sound => son,
			SB_Opt => (others => '1'),
			LED_0 => led0, LED_1 => led1, LED_2 => led2,
			game_sel => jeu_v, option => "1000",
			DFP_Busy => '1', DFP_tx => dfp_tx,
			SD_CS => sd_cs, SD_MISO => '0', SD_MOSI => sd_mosi, SD_CLK => sd_clk);

	-- ------------------------------------------------------------------
	-- Le MPU du flipper : il pose un code sur cinq fils, rien d'autre.
	-- ------------------------------------------------------------------
	scenario : process
	begin
		son <= "00000";
		wait for DEBUT_US * 1 us;
		for c in CODE_1 to CODE_N loop
			report "SON code " & integer'image(c) & " a " & time'image(now);
			son <= std_logic_vector(to_unsigned(c, 5));
			wait for DUREE_US * 1 us;
			son <= "00000";
			wait for REPOS_US * 1 us;
		end loop;
		wait for 2 ms;
		fini <= true;
		wait;
	end process;

	-- ------------------------------------------------------------------
	-- La capture : une valeur par fenetre, centree sur zero.
	-- ------------------------------------------------------------------
	capture : process(clk)
		file f : text;
		variable l : line;
		variable st : file_open_status;
		variable n, s : integer := 0;
		variable ouvert : boolean := false;
	begin
		if rising_edge(clk) then
			if not ouvert then
				file_open(st, f, FICHIER, write_mode);
				assert st = open_ok report "ouverture impossible : " & FICHIER severity failure;
				ouvert := true;
			end if;
			if audio_o = '1' then s := s + 1; end if;
			n := n + 1;
			if n = FENETRE then
				write(l, s - FENETRE/2);
				writeline(f, l);
				n := 0; s := 0;
			end if;
		end if;
	end process;

	-- ------------------------------------------------------------------
	-- LE CONTROLE NEGATIF. Il mesure ce que VAUT le signal, pas seulement
	-- combien de '1' il contient -- '0' bloque et 'X' bloque se comptent
	-- pareil. Et il ECHOUE si le son ne varie pas.
	-- ------------------------------------------------------------------
	verdict : process
		variable n1, n0, nx : integer := 0;
		variable vu_bas, vu_haut : boolean := false;
		variable fen, cpt : integer := 0;
		variable vmin : integer := 999999;
		variable vmax : integer := -999999;
	begin
		-- on ne juge que ce qui suit le relachement du reset
		wait for DEBUT_US * 1 us;
		loop
			wait for 200 ns;
			exit when fini;
			case audio_o is
				when '1' => n1 := n1 + 1; vu_haut := true;
				when '0' => n0 := n0 + 1; vu_bas  := true;
				when others => nx := nx + 1;
			end case;
			-- fenetre glissante grossiere, pour l'amplitude
			cpt := cpt + 1;
			if audio_o = '1' then fen := fen + 1; end if;
			if cpt = 960 then           -- 192 us
				if fen < vmin then vmin := fen; end if;
				if fen > vmax then vmax := fen; end if;
				cpt := 0; fen := 0;
			end if;
		end loop;

		report "VERDICT  audio_o : " & integer'image(n1) & " a '1', "
		     & integer'image(n0) & " a '0', " & integer'image(nx) & " metavaleurs"
		     & "  |  amplitude de fenetre " & integer'image(vmin) & ".." & integer'image(vmax)
		     & " sur 960";

		assert nx = 0
			report "METAVALEURS sur Audio_O : un signal du chemin audio n'est pas "
			     & "initialise. Le son serait indefini, et un compteur de '1' ne le "
			     & "verrait pas."
			severity failure;

		assert vu_bas and vu_haut
			report "Audio_O est BLOQUE a un niveau : le DAC ne tourne pas, ou son "
			     & "entree est figee. Rien ne sortirait du haut-parleur."
			severity failure;

		assert (vmax - vmin) > 32
			report "Audio_O ne VARIE PAS : rapport cyclique quasi constant ("
			     & integer'image(vmin) & ".." & integer'image(vmax) & "/960). Le DAC "
			     & "idle au milieu -- le 6502 n'ecrit rien. C'est un SILENCE, pas un son."
			severity failure;

		report "OK : le son varie, sans metavaleur.";
		std.env.finish;
	end process;
end essai;
