-- gosof_roms.vhd — les quatre ROMs de son de Gosof, en Spartan-6.
-- Entites et ports identiques a l'original Altera (mode ROM, 1 cycle).

-- SND1 — 2048 x 8, mode ROM. Original : init_file => "../ROMs/BH1.hex".
--
-- Le fichier attendu ici est UN OCTET HEXADECIMAL PAR LIGNE, pas de l'Intel HEX :
-- la conversion se fait a la construction, pas dans le VHDL. Absent, la memoire
-- prend le motif de repli du paquet (voir gosof_mem.vhd) — non nul, pour que la
-- synthese ne supprime pas la ROM et ne fausse pas la mesure de place.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gosof_mem.all;

entity SND1 is
	port (
		address : in  std_logic_vector(10 downto 0);
		clock   : in  std_logic := '1';
		q       : out std_logic_vector(7 downto 0)
	);
end SND1;

architecture spartan6 of SND1 is
	constant FICHIER : string := "rom/BH1.txt";
	signal mem : octet_t(0 to 2047) := charger(FICHIER, 2048);
begin
	process (clock)
	begin
		if rising_edge(clock) then
			q <= mem(to_integer(unsigned(address)));
		end if;
	end process;
end spartan6;

-- SND2 — 2048 x 8, mode ROM. Original : init_file => "../ROMs/BH2.hex".
--
-- Le fichier attendu ici est UN OCTET HEXADECIMAL PAR LIGNE, pas de l'Intel HEX :
-- la conversion se fait a la construction, pas dans le VHDL. Absent, la memoire
-- prend le motif de repli du paquet (voir gosof_mem.vhd) — non nul, pour que la
-- synthese ne supprime pas la ROM et ne fausse pas la mesure de place.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gosof_mem.all;

entity SND2 is
	port (
		address : in  std_logic_vector(10 downto 0);
		clock   : in  std_logic := '1';
		q       : out std_logic_vector(7 downto 0)
	);
end SND2;

architecture spartan6 of SND2 is
	constant FICHIER : string := "rom/BH2.txt";
	signal mem : octet_t(0 to 2047) := charger(FICHIER, 2048);
begin
	process (clock)
	begin
		if rising_edge(clock) then
			q <= mem(to_integer(unsigned(address)));
		end if;
	end process;
end spartan6;

-- Qbert1 — 2048 x 8, mode ROM. Original : init_file => "./ROMs/qbert1.hex".
--
-- Le fichier attendu ici est UN OCTET HEXADECIMAL PAR LIGNE, pas de l'Intel HEX :
-- la conversion se fait a la construction, pas dans le VHDL. Absent, la memoire
-- prend le motif de repli du paquet (voir gosof_mem.vhd) — non nul, pour que la
-- synthese ne supprime pas la ROM et ne fausse pas la mesure de place.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gosof_mem.all;

entity Qbert1 is
	port (
		address : in  std_logic_vector(10 downto 0);
		clock   : in  std_logic := '1';
		q       : out std_logic_vector(7 downto 0)
	);
end Qbert1;

architecture spartan6 of Qbert1 is
	constant FICHIER : string := "rom/qbert1.txt";
	signal mem : octet_t(0 to 2047) := charger(FICHIER, 2048);
begin
	process (clock)
	begin
		if rising_edge(clock) then
			q <= mem(to_integer(unsigned(address)));
		end if;
	end process;
end spartan6;

-- Qbert2 — 2048 x 8, mode ROM. Original : init_file => "./ROMs/qbert2.hex".
--
-- Le fichier attendu ici est UN OCTET HEXADECIMAL PAR LIGNE, pas de l'Intel HEX :
-- la conversion se fait a la construction, pas dans le VHDL. Absent, la memoire
-- prend le motif de repli du paquet (voir gosof_mem.vhd) — non nul, pour que la
-- synthese ne supprime pas la ROM et ne fausse pas la mesure de place.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gosof_mem.all;

entity Qbert2 is
	port (
		address : in  std_logic_vector(10 downto 0);
		clock   : in  std_logic := '1';
		q       : out std_logic_vector(7 downto 0)
	);
end Qbert2;

architecture spartan6 of Qbert2 is
	constant FICHIER : string := "rom/qbert2.txt";
	signal mem : octet_t(0 to 2047) := charger(FICHIER, 2048);
begin
	process (clock)
	begin
		if rising_edge(clock) then
			q <= mem(to_integer(unsigned(address)));
		end if;
	end process;
end spartan6;
