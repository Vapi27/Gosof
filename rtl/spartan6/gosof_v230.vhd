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
		SANS_SD : boolean := true;
		-- DIAG : detourne D1 et D2 pour repondre a UNE question -- le 6502
		-- tourne-t-il ? Les temoins d'origine ne le disent pas :
		--   LED_0 « SD Error » est a '1' (eteinte) AU RESET comme a all_done
		--     (SD_Card.vhd:160 et :354) : son extinction ne prouve RIEN.
		--   LED_2 est du cablage combinatoire pur -- riot_pa_i(7) est un OU des
		--     quatre lignes de son (GOSOF80.vhd:382). Elle s'allume meme si le
		--     processeur n'a jamais demarre.
		-- En DIAG :
		--   D1 (P26) : le flux audio a CHANGE depuis la mise sous tension.
		--              Allumee => le 6502 execute et ecrit son DAC.
		--   D2 (P27) : sd_clk a bascule dans la derniere seconde.
		--              Allumee => la machine d'etat SD parle a la carte.
		-- Les deux se lisent ensemble :
		--   D2 seule  -> la SD tourne mais le CPU n'est jamais parti : la lecture
		--                echoue ou boucle, le reset n'est jamais relache.
		--   aucune    -> la machine d'etat SD ne tourne meme pas.
		--   D1        -> le CPU tourne : le probleme est en aval de lui.
		DIAG : boolean := false;
		-- SON_INTERNE : ignorer les cinq fils du MPU et jouer les codes de son
		-- soi-meme, un toutes les ~2,7 s.
		--
		-- POURQUOI. Les sorties de l'ULN2803 sont a COLLECTEUR OUVERT : elles ne
		-- savent que tirer vers le bas, et c'est le PULLUP du FPGA qui fabrique le
		-- '1'. Sans flipper au bout, les entrees de l'ULN flottent, tous les
		-- transistors sont bloques, et le FPGA lit 11111 EN PERMANENCE -- soit la
		-- commande 31, sans interruption. Pour Volcano, speech_ctrl marque le 31
		-- comme parole : la carte parle en boucle et rien ne lui dit d'arreter.
		-- Ce n'est pas une panne, c'est une carte son sans MPU en face.
		SON_INTERNE : boolean := false
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
	signal l1_int, l2_int : std_logic;
	signal flux, flux_p   : std_logic;
	signal clk_p          : std_logic := '0';
	signal a_change       : std_logic := '0';
	signal sd_vu          : std_logic := '0';
	signal fenetre        : unsigned(25 downto 0) := (others => '0');
	signal sd_clk_i       : std_logic;
	signal son_cpt        : unsigned(27 downto 0) := (others => '0');
	signal code           : integer range 0 to 31 := 1;
	signal son_eff        : std_logic_vector(4 downto 0);
begin

	-- ------------------------------------------------------------------
	-- LE TEMOIN QUI MANQUAIT. Rien dans gosof80 ne dit si le 6502 tourne.
	-- Ici on regarde deux choses que lui seul peut produire.
	-- ------------------------------------------------------------------
	Sonde : process (clk_50)
	begin
		if rising_edge(clk_50) then
			flux_p <= flux;
			clk_p  <= sd_clk_i;
			-- le flux delta-sigma change des que le DAC est alimente par autre
			-- chose qu'une constante : c'est la signature du processeur au travail
			if flux /= flux_p then a_change <= '1'; end if;
			-- l'horloge SPI ne bascule que si la machine d'etat SD tourne
			fenetre <= fenetre + 1;
			if sd_clk_i /= clk_p then sd_vu <= '1'; end if;
			if fenetre = 0 then sd_vu <= '0'; end if;   -- fenetre glissante ~1,3 s
		end if;
	end process;

	-- ------------------------------------------------------------------
	-- Le MPU du flipper, quand il n'y en a pas : un code toutes les ~2,7 s,
	-- puis ~2,7 s de repos a zero -- l'etat de repos reel des entrees.
	-- ------------------------------------------------------------------
	Sequenceur : process (clk_50)
	begin
		if rising_edge(clk_50) then
			son_cpt <= son_cpt + 1;
			if son_cpt(son_cpt'high) = '1' and son_cpt(son_cpt'high - 1 downto 0) = 0 then
				if code >= 31 then code <= 1; else code <= code + 1; end if;
			end if;
		end if;
	end process;

	son_eff <= sound when not SON_INTERNE
	      else std_logic_vector(to_unsigned(code, 5)) when son_cpt(son_cpt'high) = '0'
	      else "00000";

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
			Audio_O  => flux,
			Sound    => son_eff,
			SB_Opt   => sb_opt,
			LED_0    => led_0,
			LED_1    => l1_int,
			LED_2    => l2_int,
			game_sel => game_sel,
			option   => option,
			DFP_Busy => '1',            -- rien ne lit ce port : XST le supprimerait
			DFP_tx   => dfp_tx,
			SD_CS    => sd_cs,
			SD_MISO  => sd_miso,
			SD_MOSI  => sd_mosi,
			SD_CLK   => sd_clk_i);

	audio  <= flux;
	sd_clk <= sd_clk_i;
	led_1  <= a_change when DIAG else l1_int;
	led_2  <= sd_vu    when DIAG else l2_int;

end rtl;
