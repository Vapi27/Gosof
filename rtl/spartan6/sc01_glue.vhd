-- sc01_glue.vhd — le vrai SC-01A a la place du leurre de Gosof.
--
-- Meme role que Votrax-SC01.vhd, meme polarite d'AR ('1' = pret, '0' = occupe,
-- verifie des deux cotes), mais il SORT DU SON.
--
-- ⚠️ TROIS DIFFERENCES DE COMPORTEMENT avec le leurre, toutes traitees ici.
--
-- 1. LE DOUBLE STROBE. Le leurre IGNORE le strobe pendant qu'il parle (son etat
--    Speech ne le teste jamais). Le vrai coeur RELANCE a chaque front montant,
--    sans condition. Un read-modify-write du 6502 (INC, DEC, ASL en absolu) ou
--    un STA double dans la page du SC01, aujourd'hui sans effet, tronquerait
--    demain un phoneme. IGNORE_STB_WHILE_BUSY retablit le comportement du leurre.
--
-- 2. LA PORTE DE CARTE. Aujourd'hui le leurre est strobe SANS CONDITION alors
--    que son AR n'est consomme que pour la MA-216. Inoffensif tant que rien ne
--    sort ; il faut fermer la porte des qu'il sort du son.
--
-- 3. L'INFLEXION. Le vrai SC-01 prend deux bits de plus que les six du phoneme.
--    Gosof n'ecrit que six bits (cpu_dout(5 downto 0)) et jette D6/D7. Rien ne
--    prouve que la MA-216 cablait I1/I2 sur ces deux-la, et une inflexion
--    parasite change la hauteur de la voix sans qu'aucun essai ne le signale.
--    Defaut : "00", la valeur de repos. INFLECTION_SRC = 1 pour essayer D7/D6.
--
-- Note sur les durees : la grille du leurre EST celle du SC-01 (douze valeurs
-- distinctes, 47 a 250 ms). Le leurre les emet a 1,2 ms par unite (« +20 % »
-- dit son en-tete) ; le vrai coeur a 720 kHz est donc ~15 % plus rapide que ce
-- que la machine fait aujourd'hui. C'est le seul reglage a faire A L'OREILLE, et
-- il se fait par DDS_INC — mais la meme horloge fixe aussi la hauteur de voix,
-- donc tempo et timbre ne se reglent PAS separement.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sc01_glue is
	generic (
		-- Vrai : l'horloge du SC-01 suit l'octet que le JEU ecrit, comme sur la
		-- vraie carte. Faux : elle est figee a DDS_INC_FIXE, pour experimenter.
		PILOTE_PAR_LE_JEU     : boolean := true;
		DDS_INC_FIXE          : integer := 3435974;   -- 720 kHz, si non pilote
		IGNORE_STB_WHILE_BUSY : boolean := true;
		INFLECTION_SRC        : integer := 0          -- 0 = "00", 1 = cpu_data(7..6)
	);
	port (
		clk        : in  std_logic;
		reset_n    : in  std_logic;
		speech_en  : in  std_logic;                       -- '1' seulement sur une carte a parole
		strobe     : in  std_logic;                       -- sc01_strobe de GOSOF80
		-- L'octet ecrit par le jeu en page 0x3xxx : c'est lui qui fixe la
		-- hauteur de la voix sur la vraie carte Gottlieb.
		clk_dac    : in  std_logic_vector(7 downto 0);
		cpu_data   : in  std_logic_vector(7 downto 0);    -- huit bits : D5..D0 + inflexion
		ar         : out std_logic;
		audio_s18  : out signed(17 downto 0)
	);
end sc01_glue;

architecture rtl of sc01_glue is
	signal sclock_en, cclock_en : std_logic;
	signal stb_coeur : std_logic;
	signal ar_coeur  : std_logic;
	signal inflexion : std_logic_vector(1 downto 0);
	signal audio_brut : signed(17 downto 0);
	signal inc : unsigned(31 downto 0);
	signal d_borne : integer range 64 to 255;
begin
	-- L'HORLOGE DU SC-01 EST ECRITE PAR LE JEU. Sur la carte Gottlieb, la page
	-- 0x3xxx est un convertisseur qui fixe l'horloge du SC-01 : c'est ainsi que
	-- le jeu fait varier la hauteur de la voix en cours de phrase. Gosof decodait
	-- deja cette page (dac_latch_speech) et jetait la valeur.
	--
	-- Formule de MAME (src/mame/shared/gottlieb_a.cpp, convert_speech_clock) :
	--     f = 950000 + (d - 0xA0) * 5500,  d borne a 0x40 minimum
	-- MAME la donne pour ce qu'elle est : « totally random guesswork; would like
	-- to get real measurements on a board ». C'est neanmoins la meilleure
	-- reference publique, et shufps l'implemente a l'identique dans son exemple.
	--
	-- Traduite en increment de DDS, une MULTIPLICATION suffit — l'exemple de
	-- shufps fait une division 64 bits, chere en logique pour le meme resultat :
	--     inc = 4533577 + (d - 160) * 26247
	-- Ecart mesure contre la formule de MAME : moins de 0,5 Hz sur toute la
	-- plage, de 422 kHz a 1,4725 MHz.
	-- Garde ecrite dans ce sens A DESSEIN : avec une metavaleur, une comparaison
	-- IEEE rend FALSE. Ecrite « 64 when < 64 else to_integer(...) », la garde
	-- laisserait donc passer 'U' vers le else et sortirait de la plage. Ici le
	-- cas sur est le defaut. Logique synthetisee identique.
	d_borne <= to_integer(unsigned(clk_dac)) when unsigned(clk_dac) >= 64 else 64;

	inc <= to_unsigned(4533577 + (d_borne - 160) * 26247, 32) when PILOTE_PAR_LE_JEU
	  else to_unsigned(DDS_INC_FIXE, 32);
	inflexion <= cpu_data(7 downto 6) when INFLECTION_SRC = 1 else "00";

	-- La porte de carte, et le masque anti-double-strobe.
	stb_coeur <= strobe and speech_en and ar_coeur when IGNORE_STB_WHILE_BUSY
	        else strobe and speech_en;

	horloges : entity work.sc01_dds
		port map (clk => clk, reset_n => reset_n, inc => inc,
		          sclock_en => sclock_en, cclock_en => cclock_en);

	coeur : entity work.sc01a
		generic map (
			ENABLE_F2N => false,   -- defaut de l'auteur, non verifie par lui, et +26 cycles
			IS_SC01A   => 1        -- MAME : SC01 au debut 1981, SC01A « past mid-late 1981 ».
			                       -- Les jeux a parole de Gosof vont de 1981 a 1983.
		)
		port map (
			clk         => clk,
			reset_n     => reset_n,
			p           => cpu_data(5 downto 0),
			inflection  => inflexion,
			stb         => stb_coeur,
			ar          => ar_coeur,
			sclock_en   => sclock_en,
			cclock_en   => cclock_en,
			audio_out   => audio_brut,
			audio_valid => open
		);

	-- Hors carte a parole, on rend le silence et « pret » : exactement ce que le
	-- jeu attend d'un socle vide.
	ar        <= ar_coeur when speech_en = '1' else '1';
	audio_s18 <= audio_brut when speech_en = '1' else (others => '0');
end rtl;
