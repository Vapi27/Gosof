-- sc01_dds.vhd — les deux validations d'horloge du SC-01A.
--
-- Le coeur de shufps ne prend pas d'horloge a lui : il prend deux VALIDATIONS
-- d'un cycle sur clk_50, a f_sc01/18 et f_sc01/36. C'est la piece dont une
-- erreur donne une voix fausse SANS QUE RIEN NE LE SIGNALE — ni la synthese, ni
-- le placement, ni un banc qui regarde les signaux logiques.
--
-- L'increment se calcule ainsi :
--        inc = f_sc01 * 2^32 / (18 * 50 000 000)
-- Il est passe en GENERIQUE plutot que calcule ici : 720000 * 2^32 deborde
-- largement l'entier 32 bits de VHDL, et une arithmetique en flottant a
-- l'elaboration n'est pas garantie par XST.
--
--   f_sc01     inc (decimal)   inc (hexa)     ce que ca donne
--   ---------  --------------  -------------  ----------------------------------
--     614 000       2 930 122   x"002CB5CA"   tempo actuel du leurre, voix grave
--     720 000       3 435 974   x"00346DC6"   NOMINAL (fiche technique) <- defaut
--     737 000       3 517 101   x"0035AAAD"
--     774 000       3 693 672   x"00385C68"   accord des ROMs de coefficients
--     950 000       4 533 577   x"00452D49"
--
-- ⚠️ PLANCHER D'HORLOGE. Le pipeline de filtres prend 261 cycles entre une
--    validation et l'echantillon ; deux validations plus rapprochees et
--    l'impulsion est PERDUE EN SILENCE. Il faut clk >= 14,5 x f_sc01, soit un
--    plafond de 3,45 MHz a 50 MHz d'horloge. Confortable — mais c'est ce qui
--    interdit de descendre clk_50.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sc01_dds is
	port (
		clk       : in  std_logic;
		reset_n   : in  std_logic;
		-- L'increment est un PORT et non un generique : sur la vraie carte
		-- Gottlieb, le JEU ecrit l'horloge du SC-01 en cours de partie.
		inc       : in  unsigned(31 downto 0);
		sclock_en : out std_logic;
		cclock_en : out std_logic
	);
end sc01_dds;

architecture rtl of sc01_dds is
	signal phase : unsigned(31 downto 0) := (others => '0');
	signal alterne : std_logic := '0';
begin
	process (clk)
		variable somme : unsigned(32 downto 0);
	begin
		if rising_edge(clk) then
			if reset_n = '0' then
				phase     <= (others => '0');
				alterne   <= '0';
				sclock_en <= '0';
				cclock_en <= '0';
			else
				somme     := ('0' & phase) + ('0' & inc);
				phase     <= somme(31 downto 0);
				sclock_en <= somme(32);          -- la retenue : f_sc01/18
				cclock_en <= '0';
				if somme(32) = '1' then
					alterne <= not alterne;      -- une retenue sur deux : /36
					if alterne = '0' then
						cclock_en <= '1';
					end if;
				end if;
			end if;
		end if;
	end process;
end rtl;
