-- tb_sc01.vhd — banc d'essai d'ECOUTE du SC-01A pilote par l'octet du jeu.
--
-- But : entendre ce que MAME appelle « totally random guesswork ». On fabrique
-- le son en simulation et on l'ecoute, sans flipper et sans fréquencemètre.
--
-- Le banc ne suppose AUCUNE table de phonemes : il balaie les codes demandes.
-- Les seuls codes dont le sens est source (sc01a.vhd:224) sont PA0=0x03,
-- PA1=0x3E et STOP=0x3F ; la table de durees du leurre les corrobore.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_sc01 is
	generic (
		FICHIER  : string  := "audio.txt";
		OCTET_JEU : integer := 160;   -- octet ecrit par le jeu en page 0x3xxx
		PH_DEBUT : integer := 0;
		PH_FIN   : integer := 63;
		-- Suite libre de codes hexa a deux chiffres, ex "0F15181900 0D26" pour
		-- VOLCANO. Vide => on balaie PH_DEBUT..PH_FIN.
		SEQ      : string := "";
		FE       : integer := 192000 -- frequence d'echantillonnage de la capture
	);
end tb_sc01;

architecture essai of tb_sc01 is
	signal clk       : std_logic := '0';
	signal reset_n   : std_logic := '0';
	signal strobe    : std_logic := '0';
	signal cpu_data  : std_logic_vector(7 downto 0) := (others => '0');
	signal clk_dac   : std_logic_vector(7 downto 0) := (others => '0');
	signal ar        : std_logic;
	signal audio     : signed(17 downto 0);
	signal fini      : boolean := false;
begin
	clk     <= not clk after 10 ns;              -- 50 MHz
	clk_dac <= std_logic_vector(to_unsigned(OCTET_JEU, 8));

	dut : entity work.sc01_glue
		generic map (PILOTE_PAR_LE_JEU => true)
		port map (clk => clk, reset_n => reset_n, speech_en => '1',
		          strobe => strobe, clk_dac => clk_dac, cpu_data => cpu_data,
		          ar => ar, audio_s18 => audio);

	-- ------------------------------------------------------------------
	-- Le jeu : un phoneme apres l'autre, en respectant A/R comme la MA-216.
	-- ------------------------------------------------------------------
	parole : process
		function hexval(c : character) return integer is
		begin
			case c is
				when '0' to '9' => return character'pos(c) - character'pos('0');
				when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
				when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
				when others     => return -1;
			end case;
		end function;

		-- Un phoneme, dans les regles de la MA-216 : on attend A/R, on presente
		-- le code, on strobe, on attend que le SC-01 rende la main.
		procedure dire(p : integer) is
		begin
			report "phoneme 0x" & to_hstring(to_unsigned(p,8)) & " a " & time'image(now);
			if ar /= '1' then
				wait until ar = '1' for 600 ms;
			end if;
			cpu_data <= std_logic_vector(to_unsigned(p, 8));
			wait for 2 us;
			strobe <= '1';                       -- Tsw = 200 ns mini
			wait for 1 us;
			strobe <= '0';
			wait until ar = '0' for 5 ms;
			wait until ar = '1' for 600 ms;
			wait for 200 us;                     -- respiration entre phonemes
		end procedure;

		variable haut : integer := -1;
	begin
		reset_n <= '0';
		wait for 2 us;
		reset_n <= '1';
		wait for 10 us;

		if SEQ'length = 0 then
			for p in PH_DEBUT to PH_FIN loop
				dire(p);
			end loop;
		else
			-- deux caracteres hexa par phoneme ; tout le reste est ignore,
			-- ce qui permet d'aerer la chaine avec des espaces.
			for i in SEQ'range loop
				if hexval(SEQ(i)) >= 0 then
					if haut < 0 then
						haut := hexval(SEQ(i));
					else
						dire(haut * 16 + hexval(SEQ(i)));
						haut := -1;
					end if;
				end if;
			end loop;
		end if;

		wait for 5 ms;
		fini <= true;
		wait;
	end process;

	-- ------------------------------------------------------------------
	-- Diagnostic : dire ce qui se passe, au lieu de le supposer.
	-- ------------------------------------------------------------------
	mouchard : process
	begin
		wait until audio /= 0 for 1 sec;
		if audio /= 0 then
			report "PREMIER SON a " & time'image(now) & " valeur " & integer'image(to_integer(audio));
		else
			report "AUCUN SON en 1 s de temps simule" severity warning;
		end if;
		wait;
	end process;

	trace_ar : process(ar)
	begin
		report "AR -> " & std_logic'image(ar) & " a " & time'image(now);
	end process;

	trace_stb : process(strobe)
	begin
		if strobe = '1' then
			report "strobe montant a " & time'image(now) & " (ar=" & std_logic'image(ar) & ")";
		end if;
	end process;

	-- ------------------------------------------------------------------
	-- La capture : un entier signe par ligne, a FE.
	-- ------------------------------------------------------------------
	capture : process
		file f      : text;
		variable l  : line;
		variable st : file_open_status;
		constant TE : time := 1 sec / FE;
	begin
		file_open(st, f, FICHIER, write_mode);
		assert st = open_ok report "ouverture impossible : " & FICHIER severity failure;
		loop
			wait for TE;
			exit when fini;
			write(l, to_integer(audio));
			writeline(f, l);
		end loop;
		file_close(f);
		report "capture terminee";
		std.env.finish;
	end process;
end essai;
