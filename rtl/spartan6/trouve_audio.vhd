-- trouve_audio.vhd — DEMANDER A LA CARTE quelle broche va au haut-parleur.
--
-- POURQUOI CE CIRCUIT EXISTE. Trois sources donnent trois reponses differentes
-- pour la broche audio d'une porteuse GOSOF 2.30 :
--     P44  -- indiquee par le proprietaire de la carte
--     P56  -- via CONNECTORS_MAP.md:129 (PIN_31 -> P4.15) puis GottFA80_SLX9.ucf
--     P67  -- si la « position 24 » du PCB se lit dans la numerotation P4
-- Le tracage du schema ET du cuivre du PCB aboutit tous deux a « position 24 »,
-- mais la table du contrat place PIN_31 en position 15 : deux numerotations pour
-- le meme connecteur physique. Aucun raisonnement ne departage ca. La carte, si.
--
-- COMMENT IL REPOND. Chaque broche candidate emet un creneau PLEIN RAIL, a une
-- HAUTEUR DIFFERENTE, chacune son tour :
--     1er  ~2 s   P44   220 Hz   grave
--     2e   ~2 s   P56   440 Hz   medium
--     3e   ~2 s   P67   880 Hz   aigu
--     puis ~4 s de silence complet, qui marque le debut du cycle.
-- La hauteur ET le rang designent la broche : deux indices concordants, pas un.
--
-- ⚠️ UNE SEULE BROCHE EST PILOTEE A LA FOIS. Les deux autres sont en HAUTE
--    IMPEDANCE ('Z'), pas a zero. Sur cette porteuse, deux de ces trois positions
--    vont a des fonctions que nous ne connaissons pas : si l'une est une SORTIE de
--    la carte -- lecteur SD, module MP3 -- la piloter serait un conflit. En 'Z' on
--    ecoute sans rien imposer.
--
-- ⚠️ Un creneau plein rail traverse le filtre RC de la carte (R4 3,3K / C8 4,7nF)
--    et attaque l'ampli TDA7267. Baissez le potentiometre R5 avant de charger.
--
-- ⚠️ SECURITE, mot pour mot de provision/usb_install.py:15-18 :
--    /!\ COUPER LE 43 V pendant toute la procedure : pendant chaque configuration
--        du FPGA, HSWAPEN etant a la masse, TOUTES les broches utilisateur sont
--        tirees au HAUT, et les grilles des MOSFET de bobines sont actives au
--        niveau haut.
--    /!\ NE JAMAIS alimenter l USB et P6 en meme temps : meme noeud +5 V, sans
--        diode.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity trouve_audio is
	port (
		clk_50 : in    std_logic;      -- P51
		cand_1 : inout std_logic;      -- P44, 220 Hz, en premier
		cand_2 : inout std_logic;      -- P56, 440 Hz, en deuxieme
		cand_3 : inout std_logic       -- P67, 880 Hz, en troisieme
	);
end trouve_audio;

architecture rtl of trouve_audio is
	-- 2^27 cycles a 50 MHz = 2,68 s par creneau de temps.
	signal cyc  : unsigned(29 downto 0) := (others => '0');
	signal fen  : unsigned(2 downto 0);            -- 0..7, huit creneaux

	-- demi-periodes : 50e6 / (2 x f)
	signal d1, d2, d3 : unsigned(17 downto 0) := (others => '0');
	signal c1, c2, c3 : std_logic := '0';
begin

	Horloges : process (clk_50)
	begin
		if rising_edge(clk_50) then
			cyc <= cyc + 1;
			if d1 >= 113636 then d1 <= (others=>'0'); c1 <= not c1; else d1 <= d1 + 1; end if;  -- 220 Hz
			if d2 >=  56818 then d2 <= (others=>'0'); c2 <= not c2; else d2 <= d2 + 1; end if;  -- 440 Hz
			if d3 >=  28409 then d3 <= (others=>'0'); c3 <= not c3; else d3 <= d3 + 1; end if;  -- 880 Hz
		end if;
	end process;

	fen <= cyc(29 downto 27);

	-- UN SEUL PILOTE A LA FOIS. 'Z' partout ailleurs : on n'impose rien aux deux
	-- autres broches, dont on ignore la fonction sur cette carte.
	cand_1 <= c1 when fen = "000" else 'Z';
	cand_2 <= c2 when fen = "001" else 'Z';
	cand_3 <= c3 when fen = "010" else 'Z';
	-- creneaux 3 a 7 : silence complet, ~13 s. C'est la respiration qui marque le
	-- debut du cycle -- sans elle on ne saurait pas quel bip est le premier.

end rtl;
