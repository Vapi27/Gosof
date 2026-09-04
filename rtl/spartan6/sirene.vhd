-- sirene.vhd — UNE broche, UN son qu'on ne peut pas confondre.
--
-- POURQUOI CE CIRCUIT REMPLACE trouve_audio.vhd. Le premier chercheur emettait
-- trois hauteurs a la suite sur trois broches, et demandait de retenir laquelle
-- venait en premier. C'est une epreuve de memoire dans un haut-parleur de
-- flipper, pas une mesure : la reponse « je ne suis pas sur » etait la bonne, et
-- c'est l'instrument qu'il fallait changer.
--
-- Ici : UNE SEULE broche pilotee, et un son qui alterne 440 Hz et 880 Hz toutes
-- les demi-secondes -- un deux-tons de sirene. On ne le confond ni avec du bruit,
-- ni avec un ronflement, ni avec rien. La question devient binaire : on l'entend,
-- ou on ne l'entend pas.
--
-- Toutes les autres broches restent NON DECLAREES, donc tirees au bas par bitgen
-- et jamais pilotees : aucun conflit possible avec une sortie de la carte.
--
-- ⚠️ Creneau plein rail dans le filtre de la carte puis le TDA7267 : baisser le
--    potentiometre R5 avant de charger.
--
-- ⚠️ COUPER LE 43 V pendant la configuration (HSWAPEN a la masse : toutes les
--    broches montent au HAUT), et ne jamais alimenter l'USB et P6 ensemble.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sirene is
	port (
		clk_50 : in  std_logic;
		son    : out std_logic
	);
end sirene;

architecture rtl of sirene is
	signal lent  : unsigned(24 downto 0) := (others => '0');  -- 2^25 = 0,67 s
	signal demi  : unsigned(17 downto 0) := (others => '0');
	signal carre : std_logic := '0';
	signal seuil : unsigned(17 downto 0);
begin
	-- une demi-seconde de 440 Hz, une demi-seconde de 880 Hz, en boucle.
	seuil <= to_unsigned(56818, 18) when lent(lent'high) = '0'   -- 440 Hz
	    else to_unsigned(28409, 18);                             -- 880 Hz

	process (clk_50)
	begin
		if rising_edge(clk_50) then
			lent <= lent + 1;
			if demi >= seuil then
				demi  <= (others => '0');
				carre <= not carre;
			else
				demi <= demi + 1;
			end if;
		end if;
	end process;

	son <= carre;
end rtl;
