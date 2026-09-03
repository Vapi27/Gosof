-- banc_sc01.vhd — le SC-01A seul dans le FPGA, pour l'ENTENDRE au banc.
--
-- POURQUOI CE SOMMET EXISTE. Gosof complet ne peut pas parler sur un module
-- Smart FA : il lit ses ROMs de jeu sur CARTE SD, le module n'a pas de lecteur,
-- et les ROMs ne sont pas dans le depot amont (rtl/spartan6/gosof_roms.vhd:7-9
-- le dit : motif de repli, « non nul, pour que la synthese ne supprime pas la
-- ROM »). Sans ROM le 6502 n'execute rien, rien ne strobe le SC-01A, silence.
-- Un .ucf parfait n'y changerait rien.
--
-- Ce sommet-ci enleve tout ce qui n'est pas necessaire pour entendre la voix :
-- ni SD, ni ROM de jeu, ni 6502, ni les 33 broches de Gosof. Il garde la chaine
-- qui produit le son — sc01_dds -> sc01a -> audio_mix -> dac — et remplace le
-- processeur par un sequenceur cable.
--
-- LE SEQUENCEUR EST LA TRANSPOSITION EXACTE de la procedure dire() du banc de
-- simulation (sim/tb_sc01.vhd), celle dont les neuf simulations ont prouve
-- qu'elle fait parler le coeur : attendre A/R haut, presenter le code, strober,
-- attendre que le SC-01 rende la main. Meme protocole que la MA-216.
--
-- IL PILOTE AUSSI L'HORLOGE. Le programme change l'octet de la page 0x3xxx entre
-- les mots : on entend sur la carte ce que la simulation a mesure — la hauteur et
-- le tempo suivent l'octet que le jeu ecrit. C'est le point a verifier en vrai.
--
-- ⚠️ SORTIE AUDIO : creneau delta-sigma 1 bit, pleine amplitude 0/3,3 V. Elle
--    EXIGE le filtre RC externe que dac.vhd:9-16 porte en commentaire (3,3 kOhm
--    en serie, 4,7 nF vers la masse) PUIS un diviseur au potentiometre. Branchee
--    telle quelle sur une entree ligne, elle l'attaque a plein rail.
--
-- ⚠️ SECURITE, reprise mot pour mot de provision/usb_install.py:15-18 :
--    /!\ COUPER LE 43 V pendant toute la procedure : pendant chaque configuration
--        du FPGA, HSWAPEN etant a la masse, TOUTES les broches utilisateur sont
--        tirees au HAUT, et les grilles des MOSFET de bobines sont actives au
--        niveau haut.
--    /!\ NE JAMAIS alimenter l USB et P6 en meme temps : meme noeud +5 V, sans
--        diode.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity banc_sc01 is
	port (
		clk_50     : in  std_logic;                     -- P51, oscillateur Y2
		reset_sw   : in  std_logic;                     -- P32, bouton, actif BAS
		-- LE MEME SIGNAL AUDIO SUR LES QUATRE SORTIES DU CONNECTEUR P4.
		-- Mesure au banc : le haut-parleur de la porteuse de Valere est cable sur
		-- P4.3, la position que le brochage GottFA80 nomme « LED_ON ». On l'a su
		-- parce qu'il a ENTENDU le battement de coeur a 1,5 Hz -- 50 MHz / 2^25 =
		-- 1,49 Hz, au dixieme pres. Plutot que de deviner laquelle est la bonne, ou
		-- de faire deplacer un fil qui ne se deplace pas, on emet sur les quatre.
		-- Aucune ne porte autre chose que des LED ou l'audio dans ce brochage.
		audio_p43  : out std_logic;                     -- P4.3  (« LED_ON »)
		audio_p45  : out std_logic;                     -- P4.5  (« LED_SDcard »)
		audio_p46  : out std_logic;                     -- P4.6  (« Sound », l'audio d'origine)
		audio_p47  : out std_logic                      -- P4.7  (« LED_Int »)
	);
end banc_sc01;

architecture rtl of banc_sc01 is

	-- ------------------------------------------------------------------
	-- Le programme. Un mot de 16 bits par pas :
	--     [15:8] octet d'horloge du jeu (page 0x3xxx)
	--     [5:0]  code de phoneme
	-- Les codes viennent de la source, pas de memoire : MAME
	-- src/devices/sound/votrax.cpp, s_phone_table[64].
	--     0x0F V   0x15 AH1  0x18 L   0x19 K   0x00 EH3  0x0D N   0x26 O
	--     0x0E B   0x13 AW1  0x3E PA1 (pause)  0x3F STOP
	-- ------------------------------------------------------------------
	type t_prog is array (natural range <>) of std_logic_vector(15 downto 0);
	constant PROG : t_prog := (
		-- VOLCANO a l'horloge nominale 0xA0 (950 kHz)
		x"A00F", x"A015", x"A018", x"A019", x"A000", x"A00D", x"A026", x"A03F",
		x"A03E", x"A03E",
		-- BALL a 0x70 (686 kHz) — grave
		x"700E", x"7013", x"7018", x"703F",
		x"703E",
		-- BALL a 0xA0 (950 kHz) — nominal
		x"A00E", x"A013", x"A018", x"A03F",
		x"A03E",
		-- BALL a 0xD0 (1214 kHz) — aigu
		x"D00E", x"D013", x"D018", x"D03F",
		-- longue respiration avant de reboucler
		x"A03E", x"A03E", x"A03E"
	);

	-- Delais, en cycles de 20 ns.
	constant T_PRESENT : integer :=        100;   -- 2 us avant le strobe
	constant T_STROBE  : integer :=         50;   -- 1 us de strobe (Tsw mini 200 ns)
	constant T_GAP     : integer :=     10_000;   -- 200 us de respiration
	constant T_POR     : integer :=     50_000;   -- 1 ms de reset a la mise sous tension
	-- Gardes-fous. En simulation un « wait ... for » suffit ; sur silicium une
	-- attente sans borne est un blocage definitif, la carte reste muette sans
	-- rien signaler. Ces deux delais bornent chaque attente d'A/R.
	constant T_ATT_OCC : integer :=    250_000;   -- 5 ms pour passer occupe
	constant T_ATT_PRT : integer := 30_000_000;   -- 600 ms pour revenir pret

	type t_etat is (Repos, Pret, Presente, Impulsion, Occupe, Parle, Gap);
	signal etat : t_etat := Repos;

	signal idx      : integer range 0 to PROG'high := 0;
	signal compte   : unsigned(25 downto 0) := (others => '0');
	signal por      : unsigned(16 downto 0) := (others => '0');
	signal reset_n  : std_logic := '0';

	signal clk_dac  : std_logic_vector(7 downto 0) := x"A0";
	signal phoneme  : std_logic_vector(7 downto 0) := (others => '0');
	signal strobe   : std_logic := '0';
	signal ar       : std_logic;
	signal sc01_s18 : signed(17 downto 0);
	signal melange  : std_logic_vector(15 downto 0);
	signal flux     : std_logic;

begin

	-- ------------------------------------------------------------------
	-- Reset : le bouton ET un reset de mise sous tension. Sans le second, la
	-- carte demarrerait dans un etat non initialise si personne n'appuie.
	-- ------------------------------------------------------------------
	Reset_Interne : process (clk_50)
	begin
		if rising_edge(clk_50) then
			if por < T_POR then
				por     <= por + 1;
				reset_n <= '0';
			else
				reset_n <= reset_sw;          -- bouton actif BAS, rappel haut au repos
			end if;
		end if;
	end process;

	-- ------------------------------------------------------------------
	-- Le sequenceur : ce que faisait le 6502 de la MA-216.
	-- ------------------------------------------------------------------
	Sequenceur : process (clk_50)
	begin
		if rising_edge(clk_50) then
			if reset_n = '0' then
				etat    <= Repos;
				idx     <= 0;
				compte  <= (others => '0');
				strobe  <= '0';
				clk_dac <= x"A0";
				phoneme <= (others => '0');
			else
				case etat is

					when Repos =>
						-- laisser le coeur sortir de son propre reset
						if compte < 5000 then
							compte <= compte + 1;
						else
							compte <= (others => '0');
							etat   <= Pret;
						end if;

					when Pret =>
						-- attendre A/R haut, mais pas indefiniment
						if ar = '1' then
							clk_dac <= PROG(idx)(15 downto 8);
							phoneme <= "00" & PROG(idx)(5 downto 0);
							compte  <= (others => '0');
							etat    <= Presente;
						elsif compte < T_ATT_PRT then
							compte <= compte + 1;
						else
							-- le coeur ne rend pas la main : on force le pas suivant
							compte <= (others => '0');
							if idx = PROG'high then idx <= 0; else idx <= idx + 1; end if;
						end if;

					when Presente =>
						if compte < T_PRESENT then
							compte <= compte + 1;
						else
							compte <= (others => '0');
							strobe <= '1';
							etat   <= Impulsion;
						end if;

					when Impulsion =>
						if compte < T_STROBE then
							compte <= compte + 1;
						else
							compte <= (others => '0');
							strobe <= '0';
							etat   <= Occupe;
						end if;

					when Occupe =>
						-- il doit passer occupe (A/R bas)
						if ar = '0' then
							compte <= (others => '0');
							etat   <= Parle;
						elsif compte < T_ATT_OCC then
							compte <= compte + 1;
						else
							compte <= (others => '0');
							etat   <= Gap;      -- strobe ignore : on n'insiste pas
						end if;

					when Parle =>
						if ar = '1' then
							compte <= (others => '0');
							etat   <= Gap;
						elsif compte < T_ATT_PRT then
							compte <= compte + 1;
						else
							compte <= (others => '0');
							etat   <= Gap;
						end if;

					when Gap =>
						if compte < T_GAP then
							compte <= compte + 1;
						else
							compte <= (others => '0');
							if idx = PROG'high then idx <= 0; else idx <= idx + 1; end if;
							etat <= Pret;
						end if;

				end case;
			end if;
		end if;
	end process;

	-- ------------------------------------------------------------------
	-- La chaine du son, identique a celle de GOSOF80.vhd.
	-- PILOTE_PAR_LE_JEU reste VRAI : c'est precisement ce qu'on vient verifier.
	-- ------------------------------------------------------------------
	Parole : entity work.sc01_glue
		generic map (
			PILOTE_PAR_LE_JEU     => true,
			IGNORE_STB_WHILE_BUSY => true,
			INFLECTION_SRC        => 0
		)
		port map (
			clk       => clk_50,
			reset_n   => reset_n,
			speech_en => '1',
			strobe    => strobe,
			clk_dac   => clk_dac,
			cpu_data  => phoneme,
			ar        => ar,
			audio_s18 => sc01_s18
		);

	-- La voie « son » de Gosof est absente ici : 0x80 est son point de repos
	-- exact (audio_mix.vhd:65-66 — 128 decale de 9 vaut 65536, moins 65536 = 0).
	Melangeur : entity work.audio_mix
		generic map (SPCH_GAIN => 512)
		port map (
			clk        => clk_50,
			gosof_u8   => x"80",
			speech_s18 => sc01_s18,
			dac_u16    => melange
		);

	Audio_DAC : entity work.dac
		generic map (msbi_g => 15)
		port map (
			clk_i   => clk_50,
			res_n_i => reset_n,
			dac_i   => melange,
			dac_o   => flux
		);

	-- Les quatre sorties portent le meme flux delta-sigma.
	audio_p43 <= flux;
	audio_p45 <= flux;
	audio_p46 <= flux;
	audio_p47 <= flux;

	-- Plus aucun temoin LED : sur un module nu au banc, LED_ON / LED_SDcard /
	-- LED_Int ne sont que des POSITIONS DE CONNECTEUR -- les diodes sont sur la
	-- porteuse. Je les avais donnees comme temoins fiables, elles ne l'etaient
	-- pas. Le son lui-meme est le seul temoin qui vaille ici.

end rtl;
