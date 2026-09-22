-- tb_gosof80_sd.vhd -- gosof80 en MODE SD, face a une carte SD simulee qui sert
-- les VRAIS 4 Ko du bloc 0.
--
-- Pourquoi ce banc existe. Sur la porteuse, la ROM mise dans le bitstream parle ;
-- la meme ROM chargee depuis la carte SD arrive intacte (trace : 4096 octets,
-- somme 8592, reset relache) -- et la carte reste muette. tb_gosof80.vhd ne sait
-- tourner qu'en SANS_SD. Celui-ci fait le chemin complet : lecture SD, ecriture
-- des deux SB_ROM, relachement du reset, 6502, poussoir Test, SC-01.
--
-- ⚠️ LES OCTETS DE LA ROM NE SONT PAS DANS CE FICHIER. C'est du code Gottlieb : ils
--    sont lus a l'execution dans le fichier BLOC (hors du depot, ~/gosof-roms).
--
-- Ce qu'on attend, si le mode SD est sain : apres le relachement du reset, le
-- poussoir Test enfonce lance la routine $FA5B et le SC-01 recoit des phonemes
-- (rapports « TRACE PHONEME » de GOSOF80.vhd). Aucun phoneme = le defaut est
-- reproduit en simulation.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sd_carte_bloc is
	generic (
		BLOC     : string;              -- 4096 octets bruts : secteurs SECTEUR0 .. SECTEUR0+7
		SECTEUR0 : natural := 660;
		OCCUPE   : natural := 3         -- reponses « occupe » a ACMD41 avant d'etre prete
	);
	port (cs_n, sclk, mosi : in std_logic; miso : out std_logic := '1');
end sd_carte_bloc;

architecture comportement of sd_carte_bloc is
	type mem_t is array (0 to 4095) of std_logic_vector(7 downto 0);
	impure function charger return mem_t is
		type octets_t is file of character;
		file f : octets_t open read_mode is BLOC;
		variable c : character;
		variable m : mem_t;
	begin
		for i in 0 to 4095 loop
			read(f, c);
			m(i) := std_logic_vector(to_unsigned(character'pos(c), 8));
		end loop;
		return m;
	end function;
	constant DONNEES : mem_t := charger;
begin
	carte : process
		type file_t is array (0 to 63) of std_logic_vector(7 downto 0);
		type cmd_t  is array (0 to 5)  of std_logic_vector(7 downto 0);
		variable q          : file_t;
		variable qh, qt     : natural := 0;
		variable rx, cur    : std_logic_vector(7 downto 0) := x"FF";
		variable nbits      : natural := 0;
		variable cmd        : cmd_t;
		variable ncmd       : natural := 0;
		variable app, pret  : boolean := false;
		variable occupe     : natural := 0;
		variable flux       : boolean := false;
		variable sec        : natural := 0;
		variable pos        : integer := 0;
		variable idx        : natural;
		variable arg        : unsigned(31 downto 0);
		procedure pousser(b : std_logic_vector(7 downto 0)) is
		begin
			q(qt) := b; qt := (qt + 1) mod 64;
		end procedure;
		procedure r1 is
		begin
			pousser(x"FF");
			if pret then pousser(x"00"); else pousser(x"01"); end if;
		end procedure;
		impure function donnee(s : natural; i : natural) return std_logic_vector is
		begin
			if s >= SECTEUR0 and s < SECTEUR0 + 8 then
				return DONNEES((s - SECTEUR0) * 512 + i);
			end if;
			return x"00";
		end function;
	begin
		wait on sclk, cs_n;
		if cs_n /= '0' then
			miso <= '1'; nbits := 0;
		elsif cs_n'event then
			miso <= cur(7);
		elsif rising_edge(sclk) then
			rx := rx(6 downto 0) & mosi; nbits := nbits + 1;
			if nbits = 8 then
				nbits := 0;
				if ncmd = 0 then
					if rx(7 downto 6) = "01" then cmd(0) := rx; ncmd := 1; end if;
				else
					cmd(ncmd) := rx; ncmd := ncmd + 1;
					if ncmd = 6 then
						ncmd := 0;
						idx := to_integer(unsigned(cmd(0)(5 downto 0)));
						arg := unsigned(cmd(1)) & unsigned(cmd(2)) & unsigned(cmd(3)) & unsigned(cmd(4));
						if app then
							app := false;
							if idx = 41 then
								if occupe < OCCUPE then occupe := occupe + 1; else pret := true; end if;
							end if;
							r1;
						else
							case idx is
								when 0  => pret := false; occupe := 0; flux := false; qh := qt; r1;
								when 8  => r1; pousser(x"00"); pousser(x"00"); pousser(x"01"); pousser(x"AA");
								when 55 => app := true; r1;
								when 58 => r1; pousser(x"C0"); pousser(x"FF"); pousser(x"80"); pousser(x"00");
								when 18 => r1; flux := true; sec := to_integer(arg); pos := 0;
								           report "carte : CMD18 secteur " & integer'image(sec);
								when 12 => flux := false; qh := qt; pousser(x"FF"); r1; pousser(x"00");
								when others => r1;
							end case;
						end if;
					end if;
				end if;
				if qh /= qt then
					cur := q(qh); qh := (qh + 1) mod 64;
				elsif flux then
					if pos = 0 then cur := x"FE";
					elsif pos <= 512 then cur := donnee(sec, pos - 1);
					else cur := x"A5";
					end if;
					if pos = 514 then sec := sec + 1; pos := 0; else pos := pos + 1; end if;
				else
					cur := x"FF";
				end if;
			end if;
		elsif falling_edge(sclk) then
			miso <= cur(7 - nbits);
		end if;
	end process;
end comportement;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_gosof80_sd is
	generic (
		BLOC     : string  := "/root/gosof-roms/bloc0.bin";
		OCCUPE   : natural := 3;
		SANS_SD  : boolean := false;    -- true : la reference, ROM du paquet gosof_jeu
		TEST_MS  : integer := 120;      -- S4 enfonce a partir de cet instant
		FIN_MS   : integer := 400
	);
end tb_gosof80_sd;

architecture essai of tb_gosof80_sd is
	signal clk      : std_logic := '0';
	signal fini     : boolean := false;
	signal test_sw  : std_logic := '1';
	signal audio_o, led0, led1, led2, dfp_tx : std_logic;
	signal sd_cs, sd_mosi, sd_clk, sd_miso : std_logic;
begin
	clk <= not clk after 10 ns when not fini;

	dut : entity work.gosof80
		generic map (SANS_SD => SANS_SD, TRACE => true, PAROLE_MP3_AUSSI => false,
		             SD_DELAI => 50000)                    -- 1 ms au lieu de 500
		port map (
			clk_50 => clk, reset_sw => '1', test => test_sw,
			Audio_O => audio_o, Sound => "00000",
			SB_Opt => (others => '1'),                      -- S1 tout OFF
			LED_0 => led0, LED_1 => led1, LED_2 => led2,
			game_sel => "111111",                           -- S3 tout OFF : MA-216, bloc 0
			option => "0111",                               -- S2 : DIP1-3 OFF, DIP4 ON
			DFP_Busy => '1', DFP_tx => dfp_tx,
			SD_CS => sd_cs, SD_MISO => sd_miso, SD_MOSI => sd_mosi, SD_CLK => sd_clk);

	carte : entity work.sd_carte_bloc
		generic map (BLOC => BLOC, OCCUPE => OCCUPE)
		port map (cs_n => sd_cs, sclk => sd_clk, mosi => sd_mosi, miso => sd_miso);

	-- LED_0 = SDcard_error (actif bas) : elle passe a '1' en all_done, quand le reset
	-- du 6502 est relache.
	chargement : process
	begin
		wait until led0 = '1';
		report "SD : CHARGEMENT TERMINE, reset du 6502 relache a " & time'image(now);
		wait;
	end process;

	scenario : process
	begin
		wait for TEST_MS * 1 ms;
		report "S4 ENFONCE a " & time'image(now);
		test_sw <= '0';
		wait for (FIN_MS - TEST_MS) * 1 ms;
		fini <= true;
		wait;
	end process;
end essai;
