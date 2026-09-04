-- gosof_v230.vhd — GOSOF COMPLET sur une porteuse GOSOF 2.30 de bontango.
--
-- Ce n'est plus un banc : c'est le portage. gosof80 entier, avec les VRAIS DIP de
-- la carte, sa carte SD, son module MP3 et son haut-parleur. Le module Pstore
-- Smart FA (Spartan-6) prend la place du "EP2C5T144C8 dev Board" (Cyclone II).
--
-- LE BROCHAGE. La regle a ete etablie et verifiee :
--   numero de pastille serigraphie sur la Gosof (1..112, continu)
--     1-28 -> P4.N     29-56 -> P1.N-28     57-84 -> P2.N-56     85-112 -> P3.N-84
--   puis position -> broche Spartan-6 par gottfa-hw/pinout/GottFA80_SLX9.ucf.
--
-- ⚠️ LE NOM « PIN_nn » NE SERT JAMAIS. CONNECTORS_MAP.md fait correspondre des
--    positions a des PIN_nn de la devboard Cyclone 10 ; la porteuse Gosof porte un
--    Cyclone II, ou le meme nom designe une autre position. C'est cette confusion
--    qui a donne P56 au lieu de P67 pour l'audio, et coute une demi-journee.
--    Les LOC de GottFA80_SLX9.ucf, elles, sont exactes : ce sont ses NOMS DE
--    SIGNAUX qu'il ne faut pas reprendre.
--
-- L'ANCRAGE : la sortie audio est sur la pastille 24 -> P4.24 -> P67. Etabli par
-- le tracage du cuivre du PCB, le tracage vectoriel du schema, ET une mesure a
-- l'analyseur sur la carte. C'est le seul point mesure ; P2 et P3 reposent sur la
-- serigraphie, la signature des alimentations et 18 broches concordantes.
--
-- ⚠️ PAS DE PORT reset_sw, ET CE N'EST PAS UN OUBLI. Aucune source de reset
--    n'existe sur cette porteuse : les 112 broches ont ete verifiees. Sur la
--    devboard d'origine c'est le bouton embarque, qui ne passe par aucun
--    connecteur. Or reset_sw va droit a i_Rst_L de SD_Card : a '0' la machine
--    d'etat reste bloquee, cpu_reset_l n'est jamais relache, et LE 6502 NE
--    DEMARRE JAMAIS, en silence total. Sur une pastille nue il flotterait -- panne
--    intermittente. Il est donc cable a '1' ici.
--
-- ⚠️ DFP_Busy N'EST PAS SORTI NON PLUS. Le port existe dans gosof80 mais rien ne
--    le lit : XST le supprime, et une contrainte sur une broche supprimee echoue
--    ou est ignoree. Il est cable a '1' -- « module jamais occupe » -- tant que la
--    voie MP3 n'est pas exploitee.
--
-- ⚠️ SECURITE, mot pour mot de provision/usb_install.py:15-18 :
--    /!\ COUPER LE 43 V pendant toute la procedure : pendant chaque configuration
--        du FPGA, HSWAPEN etant a la masse, TOUTES les broches utilisateur sont
--        tirees au HAUT, et les grilles des MOSFET de bobines sont actives au
--        niveau haut.
--    /!\ NE JAMAIS alimenter l USB et P6 en meme temps : meme noeud +5 V, sans
--        diode.
--    Ici HSWAPEN a la masse joue EN NOTRE FAVEUR : pendant la configuration,
--    SD_CS monte donc la carte SD est deselectionnee, DFP_tx monte donc l'UART est
--    au repos, et les DIP comme l'ULN2803 sont tires au haut sans consequence.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gosof_v230 is
	generic (
		-- SANS_SD : la ROM du jeu vient du bitstream au lieu de la carte SD.
		--
		-- A true, c'est le mode PROUVE : on a entendu Volcano et la parole du
		-- SC-01A avec. A false c'est le portage complet -- la carte SD choisit le
		-- jeu par les DIP -- mais ce chemin n'a JAMAIS ete exerce sur ce portage,
		-- et son mode de panne est le silence total sans message (SD_Card.vhd:255
		-- est le seul point qui relache cpu_reset_l, et son etat `error` est un
		-- puits sans retour).
		SANS_SD : boolean := true
	);
	port (
		clk_50   : in  std_logic;                       -- P51, oscillateur Y2

		-- L'audio. Pastille 24 -> P4.24 -> P67. MESUREE.
		-- La carte porte deja le filtre : R4 3,3K + C8 4,7nF vers la masse, puis
		-- le potentiometre R5, C7 et l'ampli TDA7267. Rien a cabler.
		audio    : out std_logic;

		-- Les cinq fils du MPU, derriere l'ULN2803. Il INVERSE deja : d'ou
		-- riot_pa_i(n) <= Sound_meta(n) sans `not` dans gosof80, qui est correct.
		sound    : in  std_logic_vector(4 downto 0);

		-- Les DIP de la carte. Tous vers la masse, SANS aucune resistance de
		-- rappel sur le circuit : ce sont les PULLUP internes du FPGA qui
		-- fabriquent le '1'. Sans eux la carte lirait des DIP au hasard.
		sb_opt   : in  std_logic_vector(1 to 6);        -- S1, Soundcard CFG
		game_sel : in  std_logic_vector(5 downto 0);    -- S3, 6 poles
		option   : in  std_logic_vector(3 downto 0);    -- S2, 4 poles
		test_sw  : in  std_logic;                       -- poussoir S4, actif bas

		-- La carte SD (TF-01A).
		sd_cs    : out std_logic;
		sd_clk   : out std_logic;
		sd_mosi  : out std_logic;
		sd_miso  : in  std_logic;                       -- SORTIE de la carte SD

		-- Le module MP3 : on ne cable que notre emission.
		dfp_tx   : out std_logic;

		-- Les temoins. led_0 est le « SD Error » (D5), cable CATHODE cote FPGA
		-- donc ACTIF BAS -- et SD_Card.vhd le declare deja ainsi. led_1 et led_2
		-- vont a D1 et D2, anodes cote FPGA, actifs hauts.
		-- ⚠️ L'attribution D1<->led_1 n'est PAS prouvee : contrairement a D5, le
		--    schema ne donne aucune legende de fonction. Sans risque electrique.
		led_0    : out std_logic;
		led_1    : out std_logic;
		led_2    : out std_logic
	);
end gosof_v230;

architecture rtl of gosof_v230 is
begin

	Gosof : entity work.gosof80
		generic map (
			SANS_SD          => SANS_SD,
			TRACE            => false,
			-- Le vrai SC-01A parle : on ferme la voie MP3 la ou il parle, sinon
			-- deux voix disent la meme phrase. Mesure : 18 commandes sur 31 pour
			-- Volcano. PAROLE_MP3_AUSSI=true retablirait l'amont.
			PAROLE_MP3_AUSSI => false
		)
		port map (
			clk_50   => clk_50,
			reset_sw => '1',            -- aucune source sur cette porteuse
			test     => test_sw,
			Audio_O  => audio,
			Sound    => sound,
			SB_Opt   => sb_opt,
			LED_0    => led_0,
			LED_1    => led_1,
			LED_2    => led_2,
			game_sel => game_sel,
			option   => option,
			DFP_Busy => '1',            -- rien ne lit ce port : XST le supprimerait
			DFP_tx   => dfp_tx,
			SD_CS    => sd_cs,
			SD_MISO  => sd_miso,
			SD_MOSI  => sd_mosi,
			SD_CLK   => sd_clk);

end rtl;
