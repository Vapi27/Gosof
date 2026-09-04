-- gosof_banc.vhd — GOSOF COMPLET sur la carte, sans flipper autour.
--
-- Ce sommet n'est PAS un modele reduit : il instancie gosof80 en entier -- le
-- T65, le RIOT, les ROMs du jeu, le SC-01A, le melangeur, le DAC. Il ne fait
-- que le rendre autonome au banc :
--
--   - les DIP sont cables en dur (pas de bloc de DIP sur un module nu) ;
--   - les cinq fils du MPU (Sound) sont pilotes par un sequenceur interne qui
--     joue les codes de son l'un apres l'autre. C'est ca, « faire parler le jeu
--     sans flipper » ;
--   - SANS_SD=true : la ROM est dans le bitstream, pas sur carte SD.
--
-- POURQUOI ALLER AU MATERIEL MAINTENANT. ghdl tient 0,7 ms de temps simule par
-- seconde sur ce design : entendre UNE seconde de jeu coute 23 minutes de calcul.
-- La carte le fait en une seconde. Le FPGA est un bien meilleur simulateur que
-- ghdl, une fois qu'on sait quoi ecouter -- et la simulation a deja repondu a ce
-- qu'elle pouvait repondre a bon compte (le T65 execute, le jeu ecrit $3xxx, le
-- melangeur n'ecrete pas).
--
-- CE QU'ON PERD : toute observabilite. Ni TRACE, ni compteur, ni rapport. Le seul
-- temoin est le haut-parleur. C'est assume, et c'est pour ca que le sequenceur
-- balaie les codes lentement -- pour qu'on ait le temps d'entendre.
--
-- ⚠️ SORTIE AUDIO : creneau delta-sigma 1 bit, plein rail. Elle EXIGE le filtre RC
--    de dac.vhd:9-16 (3,3 kOhm en serie, 4,7 nF a la masse) puis un diviseur.
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

entity gosof_banc is
	generic (
		-- Volcano. Le numero de jeu est celui des DIP de Gosof, pas celui de la
		-- carte SD (qui en est le complement) -- GOSOF80.vhd:527.
		JEU      : std_logic_vector(5 downto 0) := "111110";
		-- Codes de son balayes, et duree de chacun en cycles de 20 ns.
		-- 2^27 = 134 217 728 cycles = 2,68 s : assez long pour entendre.
		CODE_MIN : integer := 1;
		CODE_MAX : integer := 31
	);
	port (
		clk_50 : in  std_logic;                     -- P51, oscillateur Y2
		-- DEUX BROCHES, C'EST TOUT.
		--
		-- L'AUDIO va sur P56 = position P4.15. Chaine etablie sur la carte Gosof :
		--     Gosof PIN_31  ->  P4.15  ->  Spartan-6 P56
		-- (CONNECTORS_MAP.md:129, puis GottFA80_SLX9.ucf:154). Dans le brochage
		-- GottFA80 cette position s'appelle « CS_SDcard » : sur une porteuse Gosof
		-- elle porte l'audio. Le nom du contrat ne dit rien de la carte d'accueil.
		--
		-- La carte Gosof porte DEJA le filtre : R4 3,3K + C8 4,7nF vers la masse,
		-- puis un potentiometre R5 20K, C7 100nF, et l'ampli TDA7267. C'est
		-- exactement le RC que dac.vhd:9-16 reclame. Rien a cabler.
		--
		-- PAS DE BROCHE DE RESET. reset_sw etait cable sur P3.25, dont la fonction
		-- sur une porteuse Gosof est inconnue : si elle y est tiree au bas, le
		-- design restait en reset pour toujours, sans que rien ne le dise. Le reset
		-- de mise sous tension de gosof80 (SANS_SD) suffit.
		audio  : out std_logic                      -- P56 = P4.15
	);
end gosof_banc;

architecture rtl of gosof_banc is
	signal cpt   : unsigned(27 downto 0) := (others => '0');
	signal code  : integer range 0 to 31 := 0;
	signal son   : std_logic_vector(4 downto 0);
	signal flux  : std_logic;
	signal l0, l1, l2, dtx, scs, smo, scl : std_logic;

	-- LE MARQUEUR. Un creneau PLEIN RAIL, alterne avec le son du jeu. C'est le
	-- SEUL moyen de distinguer deux pannes qui s'entendent pareil : « le bitstream
	-- ne tourne pas » et « le son du jeu est trop faible pour ce montage ».
	-- On sait que ce signal-la S'ENTEND sur cette carte : c'est exactement la forme
	-- du battement de coeur a 1,5 Hz que Valere a entendu dans son haut-parleur.
	--   marq(28) : ~2,7 s de jeu, puis ~2,7 s de marqueur
	--   440 Hz   : 50e6 / 440 / 2 = 56818 cycles de demi-periode
	signal marq   : unsigned(28 downto 0) := (others => '0');
	signal bip_d  : unsigned(16 downto 0) := (others => '0');
	signal bip_c  : std_logic := '0';
	signal sortie : std_logic;
begin

	-- ------------------------------------------------------------------
	-- Le sequenceur de codes de son : il fait ce que fait le MPU du flipper,
	-- poser un code sur cinq fils. Un code toutes les ~2,7 s, puis 2,7 s de
	-- repos a zero -- l'etat de repos reel des entrees.
	-- ------------------------------------------------------------------
	Sequence : process (clk_50)
	begin
		if rising_edge(clk_50) then
			cpt <= cpt + 1;
			if cpt(cpt'high) = '1' and cpt(cpt'high - 1 downto 0) = 0 then
				if code >= CODE_MAX then code <= CODE_MIN; else code <= code + 1; end if;
			end if;
		end if;
	end process;

	-- bit de poids fort du compteur : une periode sur deux a zero.
	son <= std_logic_vector(to_unsigned(code, 5)) when cpt(cpt'high) = '0'
	  else "00000";

	-- ------------------------------------------------------------------
	-- GOSOF COMPLET. Rien n'est retire : c'est bien le programme du jeu qui
	-- tourne sur le T65 et fabrique le son, echantillon par echantillon.
	-- ------------------------------------------------------------------
	-- NB : pas « Jeu » comme etiquette -- VHDL ignore la casse et ca entrerait en
	-- collision avec le generique JEU. (Quatrieme collision de ce type sur ce
	-- projet, apres ns, ms et strobe.)
	Gosof : entity work.gosof80
		generic map (SANS_SD => true, TRACE => false)
		port map (
			clk_50   => clk_50,
			reset_sw => '1',                  -- jamais de reset externe : voir l'entite
			test     => '1',
			Audio_O  => flux,
			Sound    => son,
			SB_Opt   => (others => '1'),      -- options carte son, toutes au repos
			LED_0    => l0, LED_1 => l1, LED_2 => l2,
			game_sel => JEU,
			option   => "1000",               -- option(3)='1' : pas de forcage jeu 0
			DFP_Busy => '1',                  -- module MP3 absent : jamais occupe
			DFP_tx   => dtx,
			SD_CS    => scs, SD_MISO => '0', SD_MOSI => smo, SD_CLK => scl);

	-- Le marqueur ne depend NI du reset NI du jeu : comme le battement de coeur,
	-- il bat meme si tout le reste est mort. C'est ce qui en fait un temoin.
	Marqueur : process (clk_50)
	begin
		if rising_edge(clk_50) then
			marq <= marq + 1;
			if bip_d >= 56818 then
				bip_d <= (others => '0');
				bip_c <= not bip_c;
			else
				bip_d <= bip_d + 1;
			end if;
		end if;
	end process;

	-- Le marqueur ne dure plus que ~0,34 s toutes les ~5,4 s. Il reste le temoin
	-- qui distingue « ca ne tourne pas » de « c'est trop faible », mais la carte
	-- Gosof a un VRAI ampli : un creneau plein rail de 2,7 s y serait penible.
	sortie <= bip_c when marq(27 downto 24) = "1111" else flux;

	audio <= sortie;

end rtl;
