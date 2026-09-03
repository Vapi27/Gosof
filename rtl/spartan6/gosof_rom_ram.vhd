-- gosof_rom_ram.vhd — les six memoires de Gosof, en Spartan-6.
--
-- Entites et ports IDENTIQUES a l'original Altera : gosof80 les instancie par
-- leur nom, rien d'autre ne change. Toutes en UNE latence (outdata_reg_a =
-- UNREGISTERED dans les GENERIC MAP d'origine, verifie fichier par fichier).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gosof_mem.all;

-- 128 x 8, SINGLE_PORT, write-first — la RAM de travail du 6502 de la carte son.
entity RAM is
	port (
		address : in  std_logic_vector(6 downto 0);
		clock   : in  std_logic := '1';
		data    : in  std_logic_vector(7 downto 0);
		wren    : in  std_logic;
		q       : out std_logic_vector(7 downto 0)
	);
end RAM;

architecture spartan6 of RAM is
	signal mem : octet_t(0 to 127) := (others => (others => '0'));
begin
	process (clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				mem(to_integer(unsigned(address))) <= data;
				q <= data;                       -- write-first
			else
				q <= mem(to_integer(unsigned(address)));
			end if;
		end if;
	end process;
end spartan6;

-- 2048 x 8, SINGLE_PORT : ECRITE au demarrage (chargement depuis la carte SD),
-- puis lue. D'ou data/wren, malgre le nom.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gosof_mem.all;

entity SB_ROM is
	port (
		address : in  std_logic_vector(10 downto 0);
		clock   : in  std_logic := '1';
		data    : in  std_logic_vector(7 downto 0);
		wren    : in  std_logic;
		q       : out std_logic_vector(7 downto 0)
	);
end SB_ROM;

architecture spartan6 of SB_ROM is
	signal mem : octet_t(0 to 2047) := (others => (others => '0'));
begin
	process (clock)
	begin
		if rising_edge(clock) then
			if wren = '1' then
				mem(to_integer(unsigned(address))) <= data;
				q <= data;
			else
				q <= mem(to_integer(unsigned(address)));
			end if;
		end if;
	end process;
end spartan6;
