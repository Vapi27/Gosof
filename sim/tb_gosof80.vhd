-- tb_gosof80.vhd — la PREMIERE simulation du sommet gosof80.
--
-- Ce banc pose la question qu'aucune simulation de ce portage n'avait posee :
-- le T65 demarre-t-il et execute-t-il la ROM du jeu ? Jusqu'ici, rien ne l'avait
-- jamais fait tourner, ni en simulation ni sur silicium.
--
-- Il exige SANS_SD=true et le paquet gosof_jeu ENGENDRE (pas le vide) : sans
-- carte SD, SD_Card.vhd:255 ne relacherait jamais cpu_reset_l.
--
-- La capture reprend la methode de tb_banc : Audio_O est un flux 1 bit a 50 MHz,
-- on ne l'echantillonne pas, on le FILTRE en comptant les '1' par fenetre.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_gosof80 is
	generic (
		FICHIER : string  := "gosof.txt";
		FENETRE : integer := 260;              -- 50 MHz / 260 ~= 192,3 kHz
		JEU     : string  := "111110";         -- Volcano (MA-216)
		CODE    : integer := 1                 -- code de son a poser sur Sound(4:0)
	);
end tb_gosof80;

architecture essai of tb_gosof80 is
	signal clk      : std_logic := '0';
	signal audio_o  : std_logic;
	signal son      : std_logic_vector(4 downto 0) := "00000";
	signal led0, led1, led2, dfp_tx, sd_cs, sd_mosi, sd_clk : std_logic;
	signal jeu_v    : std_logic_vector(5 downto 0);
begin
	clk <= not clk after 10 ns;
	g : for i in 0 to 5 generate
		jeu_v(5 - i) <= '1' when JEU(JEU'left + i) = '1' else '0';
	end generate;

	dut : entity work.gosof80
		generic map (SANS_SD => true)
		port map (
			clk_50 => clk, reset_sw => '1', test => '1',
			Audio_O => audio_o, Sound => son,
			SB_Opt => (others => '1'),
			LED_0 => led0, LED_1 => led1, LED_2 => led2,
			game_sel => jeu_v, option => "1000",
			DFP_Busy => '1', DFP_tx => dfp_tx,
			SD_CS => sd_cs, SD_MISO => '0', SD_MOSI => sd_mosi, SD_CLK => sd_clk);

	-- Le jeu : on laisse le reset se relacher (1,31 ms), puis on pose un code de
	-- son, exactement comme le ferait le MPU du flipper sur ses cinq fils.
	scenario : process
	begin
		son <= "00000";
		wait for 2 ms;
		son <= std_logic_vector(to_unsigned(CODE, 5));
		wait for 3 ms;
		son <= "00000";
		wait;
	end process;

	-- MESURER CE QUE VAUT LE SIGNAL, pas seulement compter les '1'. Un flux bloque
	-- a '0' et un flux a 'X' donnent le meme comptage, et ce sont deux pannes
	-- completement differentes : l'une dit « le circuit ne tourne pas », l'autre
	-- « un signal n'est pas initialise ». Sans ca on debogue a l'aveugle.
	valeurs : process
		variable n1, n0, nx : integer := 0;
	begin
		loop
			wait for 200 ns;
			exit when now >= 4900 us;
			case audio_o is
				when '1' => n1 := n1 + 1;
				when '0' => n0 := n0 + 1;
				when others => nx := nx + 1;
			end case;
		end loop;
		report "audio_o : " & integer'image(n1) & " a '1', " & integer'image(n0)
		     & " a '0', " & integer'image(nx) & " metavaleurs";
		wait;
	end process;

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
				assert st = open_ok report "ouverture impossible" severity failure;
				ouvert := true;
			end if;
			if audio_o = '1' then s := s + 1; end if;
			n := n + 1;
			if n = FENETRE then
				write(l, s - FENETRE/2); writeline(f, l);
				n := 0; s := 0;
			end if;
		end if;
	end process;
end essai;
