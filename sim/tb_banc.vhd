-- tb_banc.vhd — verifier le SOMMET banc_sc01 avant de le synthetiser.
--
-- Ce que ce banc teste et que tb_sc01.vhd ne testait pas :
--   - le SEQUENCEUR cable qui remplace le 6502 (protocole A/R, strobe, avance) ;
--   - le MELANGEUR, avec sa voie « son » au repos (0x80) ;
--   - le DAC delta-sigma, donc la sortie reelle de la broche P44.
--
-- audio_o est un flux 1 bit a 50 MHz. On ne l'echantillonne pas : on le FILTRE,
-- en comptant les '1' sur des fenetres de 260 cycles (= 192 kHz). C'est le meme
-- travail que le filtre RC de dac.vhd, et ca reconstruit l'onde.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_banc is
	generic (
		FICHIER : string  := "banc.txt";
		FENETRE : integer := 260          -- 50 MHz / 260 ~= 192,3 kHz
	);
end tb_banc;

architecture essai of tb_banc is
	signal clk       : std_logic := '0';
	signal reset_sw  : std_logic := '1';   -- bouton relache (rappel haut)
	signal audio_o   : std_logic;
	signal led_parle : std_logic;
	signal led_coeur : std_logic;
begin
	clk <= not clk after 10 ns;

	dut : entity work.banc_sc01
		port map (clk_50 => clk, reset_sw => reset_sw, audio_o => audio_o,
		          led_parle => led_parle, led_coeur => led_coeur);

	-- Filtre-decimateur : somme des '1' par fenetre. Une valeur par ligne.
	capture : process(clk)
		file f      : text;
		variable l  : line;
		variable st : file_open_status;
		variable n  : integer := 0;
		variable s  : integer := 0;
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
				write(l, s - FENETRE/2);        -- centre sur zero
				writeline(f, l);
				n := 0; s := 0;
			end if;
		end if;
	end process;

	-- Temoin : quand le premier phoneme part, et quand le premier son sort.
	mouchard : process
	begin
		wait until led_parle = '1' for 100 ms;
		report "PREMIER PHONEME (led_parle) a " & time'image(now);
		wait;
	end process;
end essai;
