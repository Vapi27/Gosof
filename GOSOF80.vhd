-- Top level file for a Gottlieb compatible Soundboard
-- by bontango www.lisy.dev
-- 
-- This is free software: you can redistribute
-- it and/or modify it under the terms of the GNU General
-- Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your
-- option) any later version.
--
-- This is distributed in the hope that it will
-- be useful, but WITHOUT ANY WARRANTY; without even the
-- implied warranty of MERCHANTABILITY or FITNESS FOR A
-- PARTICULAR PURPOSE. See the GNU General Public License
-- for more details.
--
-- HW 'GOSOF80' v2.1
-- Version 0.1 - rom read from SD card
-- Version 0.2 - rom read from SD card MA 216 & MA390
-- Version 0.3 - added MA55 support
-- Version 0.4 - with option DIP4 to on, romcode is read always from first secor ( sector #660 in fact)
-- Version 0.5 - MA490 support (SYS1 works partially)
-- Version 0.6 - SYS1 support
-- Version 0.7 - added Rocky
-- Version 0.8 - sb_opt(6) was on wrong IO ( PIN_51 instead of PIN_93)
---- 			 	- remark: sys1 playing only '10' & '1000' sounds is OK while game over is high!!
-- Version 0.9 - added background music with SYS1 & MA55
-- Version 0.91 -- added clock adjustment via options

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- Le paquet du jeu : soit gosof_jeu_vide.vhd (des zeros, mode carte SD normal),
-- soit celui qu'engendre outils/rom_vers_vhdl.py (la ROM dans le bitstream).
-- Le script de construction choisit lequel des deux il compile.
use work.gosof_jeu.all;

entity gosof80 is
	generic (
		-- SANS_SD : la ROM du jeu vient du bitstream, pas de la carte SD.
		--
		-- POURQUOI CE GENERIQUE EXISTE. SD_Card.vhd:255 est le SEUL endroit du
		-- depot qui relache cpu_reset_l, et son etat `error` (:342) est un puits
		-- sans retour. Sans carte SD valide, le 6502 ne demarre JAMAIS : silence
		-- total, sans message, et le seul temoin est une LED qui, sur un module
		-- nu, n'existe pas. Tant que la SD est sur le chemin critique, on ne peut
		-- rien entendre du tout -- ni la carte son, ni la parole.
		--
		-- A true : les deux SB_ROM sont initialisees a la configuration du FPGA,
		-- les ecritures de la SD sont neutralisees, et le reset est relache par un
		-- simple compteur. La SD sort du chemin critique. Le reste du circuit est
		-- INCHANGE : meme decodage, meme processeur, meme chaine audio.
		SANS_SD : boolean := false;
		-- PAROLE_MP3_AUSSI : laisser le module MP3 parler MEME quand le vrai
		-- SC-01A parle. Faux par defaut, et c'est un CHANGEMENT DE COMPORTEMENT
		-- assume par rapport au Gosof d'origine -- voir le commentaire sur
		-- send_flag. A true, on retrouve exactement l'amont.
		PAROLE_MP3_AUSSI : boolean := false;
		-- TRACE : compte, en SIMULATION SEULEMENT, ce qu'aucun outil ne montre --
		-- les ecritures de la page $3xxx (l'horloge du SC-01, que le jeu pilote),
		-- les strobes de phoneme, et les cycles ou le melangeur ECRETE. La
		-- synthese ignore report ; a false le processus ne fait rien du tout.
		TRACE   : boolean := false
	);
	port(
		clk_50	: in std_logic;
		reset_sw	: in std_logic;
		test		: in std_logic := '1';
		Audio_O	: out std_logic;
		
		-- Sound input S1,S2,S4,S8,S16
		-- initial low due to 2803A on input of Gosof80
		Sound :	in 	std_logic_vector(4 downto 0);
		
		--Soudnboard Options S1 DIPs 1..6
		SB_Opt :	in 	std_logic_vector(1 to 6);
		
		--switches	:	
	   LED_0 	: out STD_LOGIC;						
		LED_1 	: out STD_LOGIC;
		LED_2 	: out STD_LOGIC;
		game_sel	:	in 	std_logic_vector(5 downto 0);  -- game selection S2		
		option   :	in 	std_logic_vector(3 downto 0);  -- GOSOF options
		
		-- DFPlayer
		DFP_Busy	   : in STD_LOGIC;
		DFP_tx	   : out STD_LOGIC;
		
		-- SDcard
		SD_CS : out    	std_logic;		
		SD_MISO : in 	std_logic;		
		SD_MOSI : out    	std_logic;		
		SD_CLK : out    	std_logic;
		-- TRACE du lecteur SD (instrument de mesure) : UART 115200 8N1, voir
		-- SD_Card.vhd, processus Trace. Au repos HAUT.
		DBG_TX : out    	std_logic
		
		);
end gosof80;

architecture rtl of gosof80 is 

	-- multi SD, type according to game select
	constant is_MA216 : std_logic_vector(2 downto 0):="000";
	constant is_MA309 : std_logic_vector(2 downto 0):="001";
	constant is_MA55 : std_logic_vector(2 downto 0):="010";
	constant is_MA490 : std_logic_vector(2 downto 0):="011";
	constant is_SYS1 : std_logic_vector(2 downto 0):="100";
	constant is_special : std_logic_vector(2 downto 0):="101";

	signal SB_type : 	std_logic_vector(2 downto 0);
	
	signal cpu_clk	   : std_logic; -- 892 KHz clock
	signal phi2			: 	std_logic; -- CPU clock phase 2
	signal uart_clk	: std_logic; -- 9600 baud clock for uart
	signal reset_l		: 	std_logic; -- Ccontroled by SD card reader
	-- Ce que rend SD_Card. En mode normal c'est lui qui devient reset_l ; en
	-- SANS_SD on le laisse tourner dans le vide et c'est le compteur qui decide.
	signal reset_sd	: 	std_logic;
	signal mix_sature	:	std_logic;
	-- 2^16 cycles a 50 MHz = 1,31 ms. Genereux : il ne s'agit que de laisser
	-- l'horloge processeur et le SC-01A sortir de leur propre initialisation,
	-- pas d'attendre un transfert. (2^20 = 21 ms rendait toute simulation du
	-- sommet inabordable pour rien.)
	signal por_cpt		:	unsigned(15 downto 0) := (others => '0');
	signal reset_por	: 	std_logic := '0';
	-- '1' quand la carte SD a le droit d'ecrire les ROMs.
	function bool_vers_sl(b : boolean) return std_logic is
	begin
		if b then return '1'; else return '0'; end if;
	end function;
	constant SD_ECRIT : std_logic := bool_vers_sl(not SANS_SD);
	constant MP3_AUSSI : std_logic := bool_vers_sl(PAROLE_MP3_AUSSI);

	signal Sound_meta : 	std_logic_vector(4 downto 0);
	signal cpu_addr	:	std_logic_vector(15 downto 0);
	-- portabilite VHDL-93 : le port A de T65 fait 24 bits et doit etre associe
	-- en entier ; on en tranche ensuite les 16 bits utiles.
	signal cpu_addr_24	:	std_logic_vector(23 downto 0);
	signal cpu_din		: 	std_logic_vector(7 downto 0);
	signal cpu_dout	:  std_logic_vector(7 downto 0);
	signal n_cpu_nmi	: 	std_logic;
	signal n_cpu_irq	:  std_logic;
	signal cpu_wr_n	:  std_logic;
	
	signal riot_dout	:  std_logic_vector(7 downto 0);
	signal riot_pa_i	:  std_logic_vector(7 downto 0);
	signal riot_pa_o	:  std_logic_vector(7 downto 0);
	signal riot_pb_i	:  std_logic_vector(7 downto 0);
	signal riot_pb_o	:	std_logic_vector(7 downto 0);
	signal riot_cs		:  std_logic;
	signal n_riot_irq : std_logic;
	signal riot_rs_n  : std_logic;	
	signal addr_6532  :	std_logic_vector(4 downto 0);
	
	-- ROM
	signal soundrom1_dout	:	std_logic_vector(7 downto 0);
	signal soundrom2_dout	: 	std_logic_vector(7 downto 0);	
	
	-- address decoding helper
	signal soundrom1_cs		: std_logic;
	signal soundrom2_cs		: std_logic;
	signal soundrom1_addr	:  std_logic_vector(10 downto 0);
	signal soundrom2_addr	:  std_logic_vector(10 downto 0);
	signal wr_soundrom1		: std_logic;
	signal wr_soundrom2		: std_logic;
			
	-- RAM
	signal RAM_dout	: 	std_logic_vector(7 downto 0);
	signal RAM_cs		:  std_logic;
    
	-- sounds
	signal DAC_latch	:  std_logic;
	-- VALEUR INITIALE, pas un ornement. Ce latch n'a aucun reset : tant que le 6502
	-- n'a pas ecrit en $1xxx il vaut 'U' en simulation, ce qui propage 'X' dans le
	-- melangeur puis dans le DAC -- et Audio_O reste indefini pour toujours. Sur
	-- silicium une bascule demarre a 0, donc cette initialisation ne fait que
	-- rendre le modele conforme au materiel. Mesure : sans elle, la premiere
	-- simulation du sommet donnait 21222 metavaleurs sur Audio_O contre 0 valeur
	-- utile. 0x80 est le point de repos exact de la voie son (audio_mix.vhd:65).
	signal audio_dat_latch	: 	std_logic_vector(7 downto 0) := x"80";
   signal audio_dat	: 	std_logic_vector(7 downto 0);	
	
	-- speech
	signal DAC_latch_speech	:  std_logic;
	signal sc01_strobe	:  std_logic;
	signal sc01_AR			:  std_logic;
	-- ajouts du portage : la voie parole, son melange, et la porte de carte
	signal sc01_audio	:  signed(17 downto 0);
	signal speech_clk_dac	:  std_logic_vector(7 downto 0) := x"A0";
	signal audio_mixe	:  std_logic_vector(15 downto 0);
	signal speech_en	:  std_logic;
	signal sc01_cs			:  std_logic;
	
	signal send_flag	:  std_logic:='0';
	signal DFcmd_cmd	:  std_logic_vector(7 downto 0);
	signal DFcmd_par1	:  std_logic_vector(7 downto 0);
	signal DFcmd_par2	:  std_logic_vector(7 downto 0);	
	
	-- background sound 
	signal bg_send_flag	:  std_logic:='0';
	signal bg_DFcmd_cmd	:  std_logic_vector(7 downto 0);
	signal bg_DFcmd_par1	:  std_logic_vector(7 downto 0);
	signal bg_DFcmd_par2	:  std_logic_vector(7 downto 0);	
	
	signal speech_ctrl :  std_logic_vector(31 downto 1);
	-- indice borne a la plage reelle du vecteur ; voir le commentaire sur send_flag
	signal speech_idx  :  integer range 1 to 31;
	
	-- SD card
	signal address_sd_card	:  std_logic_vector(13 downto 0);
	signal data_sd_card	:  std_logic_vector(7 downto 0);
	signal wr_rom			:  std_logic;
	signal SD_game_sel	:	std_logic_vector(7 downto 0);  
			
	-- MA490 only	
	signal ma490_irq_n			: std_logic;
	signal ma490_U11_q			: std_logic;
		
begin

-- what type of soundboard do we emulate?
	SB_type <=  is_MA216 when game_sel( 5 downto 3) = "111" else
					is_MA309 when game_sel( 5 downto 4) = "11" else
					is_MA55 when game_sel( 5 downto 4) = "10" else
					is_MA490 when game_sel( 5 downto 4) = "01" else
					is_SYS1 when game_sel( 5 downto 4) = "00" else
					is_special;

-- Le leurre etait strobe SANS CONDITION alors que son AR n'est consomme que
-- pour la MA-216 : inoffensif tant que rien ne sortait, dangereux des qu'il y a du son.
speech_en <= '1' when SB_type = is_MA216 else '0';

	
META1: entity work.Cross_Slow_To_Fast_Clock_Bus
port map(
   i_D => Sound,
	o_Q => Sound_meta,
   i_Fast_Clk => cpu_clk	
	--i_Fast_Clk => clk_50
	);

DFP_send: entity work.DFPlayer_Mini_CMD 
port map(   
			DFcmd_cmd => DFcmd_cmd,
			DFcmd_par1 => DFcmd_par1,
			DFcmd_par2 => DFcmd_par2,
         send_flag => send_flag,
         clk => uart_clk,
         rst => reset_l,
         txd => DFP_tx			
);

-- Le VRAI Votrax SC-01A, a la place du leurre. Meme polarite d'AR ('1' = pret),
-- donc riot_pb_i(7) et n_cpu_nmi ne changent pas. Il recoit HUIT bits de donnee
-- et non six : les deux du haut ne servent qu'a l'inflexion, et seulement si on
-- l'active (INFLECTION_SRC, defaut 0).
SC01_Reel: entity work.sc01_glue
generic map(
	PILOTE_PAR_LE_JEU     => true,      -- l'horloge du SC-01 suit l'octet ecrit par le jeu
	IGNORE_STB_WHILE_BUSY => true,      -- comme le leurre : pas de relance en cours de phoneme
	INFLECTION_SRC        => 0          -- "00" : rien ne prouve que la MA-216 cablait I1/I2
)
port map(
         clk => clk_50,
			reset_n => reset_l,
			speech_en => speech_en,
			strobe => sc01_strobe,
			cpu_data => cpu_dout,
			clk_dac => speech_clk_dac,
			ar => sc01_AR,
			audio_s18 => sc01_audio
);

-- phase 2 is complement of CPU clock
phi2 <= not(cpu_clk); 

-- IRQ signals ( should be '1')
n_cpu_irq <= n_riot_irq when ( SB_type = is_MA216 or SB_type = is_MA309 ) else
				 ma490_irq_n when ( SB_type = is_MA490 ) else
				 '1';

-- JK flip-flop on the piggyback board triggers CPU IRQ
ma490_U11_q <= not (riot_pb_i(0) or riot_pb_i(1) or riot_pb_i(2) or riot_pb_i(3));
U10: process(ma490_U11_q, riot_pb_o(6))
begin
	if riot_pb_o(6) = '0' then
		ma490_irq_n <= '1';
	elsif falling_edge(ma490_U11_q) then 
		ma490_irq_n <= '0';
	end if;
end process;

-- Address decoding here, cpu address bus 14-12 connect to 74LS138, only a few are used on non-speech board
--'000' riot cs
--'001' dac latch (sound)
--'010' SC01 latch 
--'011' dac latch (speech)
--'111' rom enable
riot_rs_n <= cpu_addr(9); -- ram select for riot RS_N = '0' do select ram
riot_cs 		<= '1' when cpu_addr(14 downto 12) ="000" and riot_rs_n='1' and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
					'1' when cpu_addr(11 downto 10) ="00" and riot_rs_n='1' and ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 '0';
ram_cs 		<= '1' when cpu_addr(14 downto 12) ="000" and riot_rs_n='0' and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
					'1' when cpu_addr(11 downto 10) ="00" and
					riot_rs_n='0' and ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					'0';
soundrom1_cs 		<= '1' when cpu_addr(14 downto 11) ="1110" and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
							'1' when cpu_addr(11 downto 10) ="01" and ( SB_type = is_MA55 or SB_type = is_SYS1 )else -- 0x0400 - 0x07FF & Mirror 0x0800 - 0x0BFF
							'1' when cpu_addr(11 downto 10) ="10" and ( SB_type = is_MA55 or SB_type = is_SYS1 )else -- Mirror 0x0800 - 0x0BFF
							'1' when cpu_addr(11) ='1' and SB_type = is_MA490 else
							'0';
soundrom2_cs 		<= '1' when cpu_addr(14 downto 11) ="1111" and ( SB_type = is_MA216 or SB_type = is_MA309 ) else
							'1' when cpu_addr(11 downto 10) ="11" and ( SB_type = is_MA55 or SB_type = is_SYS1 ) else -- 0x0C00 - 0x0FFF
							'0';
					
--MA only					
dac_latch 	<= '1' when cpu_addr(14 downto 12) ="001" and cpu_wr_n='0' else '0';
dac_latch_speech 	<= '1' when cpu_addr(14 downto 12) ="011" and cpu_wr_n='0' else '0';
SC01_cs <= '1' when cpu_addr(14 downto 12) ="010" and cpu_wr_n='0' else '0';
-- strobe is an AND of cs for SC-01, phi1 negated and Q1 negate from U2
sc01_strobe 	<= SC01_cs and not cpu_clk;
--sc01_strobe 	<= '1' when cpu_addr(14 downto 12) ="010" and cpu_wr_n='0' else '0';

-- address selection	
-- read from SD when wr_rom == 1
-- else map to address room

-- content of sound rom 1 is read from first 2K of SD
-- SD_ECRIT vaut '0' en SANS_SD : sans ca, la machine d'etat SD -- qui tourne
-- toujours, meme sans carte -- pourrait ecraser la ROM initialisee.
wr_soundrom1 <= '1' when ((wr_rom='1') and SD_ECRIT='1' and (address_sd_card(13 downto 11) ="000" )) else '0';
soundrom1_addr <=  --2K
	address_sd_card(10 downto 0) when wr_soundrom1 = '1' else
	'0' & cpu_addr(9 downto 0) when (SB_type = is_MA55 or SB_type = is_SYS1) else -- MA55 and SYS1 have only 1K rom
	cpu_addr(10 downto 0);

-- content of sound rom 2 is read from second 2K of SD
wr_soundrom2 <= '1' when ((wr_rom='1') and SD_ECRIT='1' and (address_sd_card(13 downto 11) ="001" )) else '0';
soundrom2_addr <=  --2K
	address_sd_card(10 downto 0) when wr_soundrom2 = '1' else
	'0' & cpu_addr(9 downto 0) when (SB_type = is_MA55 or SB_type = is_SYS1) else -- MA55 and SYS1 have only 1K rom
	cpu_addr(10 downto 0);

	
-- Bus control
cpu_din <= 
   ram_dout when ram_cs = '1' else
	riot_dout when riot_cs = '1' else
	soundrom1_dout when soundrom1_cs = '1' else
	soundrom2_dout when soundrom2_cs = '1' else	
	x"FF";
		
-- speech ctrl
-- speech_ctrl 0 is speech (-> MP3-Player), 1 is 'other'		
-- starting with sound #31 down to sound #1

speech_ctrl <=
"1111111111111111111111111111110" when game_sel = "100111" else  --Pink Panther
"0000010000000001011110111110011" when game_sel = "111111" else  --Mars
"0001000001100011011000110110011" when game_sel = "111110" else --Volcano
"0000000000111111010111111111011" when game_sel = "111101" else  --Black Hole						
"0011111110100101101111111111111" when game_sel = "111100" else  --Devils Dare
"0000000000011111111111111111111" when game_sel = "111011" else  --Rocky
"1111111111111111111111111111111" when game_sel = "111010" else  --Striker
"1111111111111111111111111111111" when game_sel = "111001" else  --Q*Bert's Quest
"1111111111111111111111111111111" when game_sel = "111000" else  --Caveman
-- speech_ctrl <= "0000011111111011111111111111101"; --Caveman
--"0000000000000000000000000000000" when game_sel = "110111" else  --numbers as wav
"1111111111111111111111111111111"; -- no speech

-- RIOT_PA
-- input for MA216 & MA309
-- MA55 use PA_out for 1408 DAC
--Sound board inputs through RIOT port A via GOSOF 
-- use not sound for benchtest with 2803A
riot_pa_i(0) <= Sound_meta(0);
riot_pa_i(1) <= Sound_meta(1);
riot_pa_i(2) <= Sound_meta(2);
riot_pa_i(3) <= Sound_meta(3);
riot_pa_i(4) <= Sound_meta(4);
riot_pa_i(5) <= '0'; -- wired, but not used
riot_pa_i(6) <= '0'; -- not wired, not used
-- Strobe signal generates IRQ when one of the inputs S1-S8 go low
-- we do this also for speech as the SB may want to stop current sound
riot_pa_i(7) <= ( Sound_meta(0) or Sound_meta(1) or Sound_meta(2) or Sound_meta(3));

-- RIOT PB
---
-- switches
--dip switch	1	2	3	4	5	6	7	8
--PB				3	J1	5	4	2	1	0	J1
--pin riot		21		18	19	22	23	24	
--
--Test attract mode and speech off for Mars
-- Manual: Switch ON -> 0, Switch OFF -> 1
riot_pb_i(0) <= Sound_meta(0) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
				    '1'; -- DIP7 not wired on Gosof PCB
riot_pb_i(1) <= Sound_meta(1) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 SB_Opt(6); --DIP6
riot_pb_i(2) <= Sound_meta(2) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 SB_Opt(5); --DIP5
riot_pb_i(3) <= Sound_meta(3) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else
					 SB_Opt(1); --DIP1
riot_pb_i(4) <= SB_Opt(4) when (SB_type = is_MA216 or SB_type = is_MA309) else --DIP4
					 SB_Opt(2); --MA55 and MA490 -- Attract mode sounds enable (S2 on board)
riot_pb_i(5) <= cpu_addr(10) when ( SB_type = is_MA55 or SB_type = is_SYS1 ) else --CS2 (needed?)
					 SB_Opt(3); --DIP3
riot_pb_i(6) <= '0' when ( SB_type = is_MA55 or SB_type = is_MA490 ) else  -- S16 Spare not used by games with MA-55 and MA490
					  Sound_meta(4) when ( SB_type = is_SYS1 ) else -- 5 inputs with System1 'Multisound'
					  test; -- connected to Testswitch against ground with MA216 & MA390
--for MA216 we have also a wire to A/R of SC01 ( is pB7 a input or a output IO?)
-- jumpered to Vcc in most games, can be strapped to riot PB7 out;
riot_pb_i(7) <= not sc01_AR when SB_type = is_MA216 else
					 SB_Opt(1) when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else --Sound or tones mode (DIP1), many games lack tone support and require this to be high (OFF)
					'1'; -- '1' for MA309 and games with no speech
n_cpu_nmi <=  not sc01_AR when SB_type = is_MA216 else 
				  test when ( SB_type = is_MA55 or SB_type = is_MA490 or SB_type = is_SYS1 ) else 
				  '1'; -- '1' for MA309 and games with no speech
-- DIP8 not wired on Gosof PCB


DFP_bg: entity work.background_sound
port map(   
         clk => uart_clk,
         rst => reset_l,
			game_over => Sound_meta(4),
			folder => x"09",
			DFcmd_cmd => bg_DFcmd_cmd,
			DFcmd_par1 => bg_DFcmd_par1,
			DFcmd_par2 => bg_DFcmd_par2,
         send_flag => bg_send_flag
);

-- prepare date for MP3 Player	      	  
-- Folder selection wav files
DFcmd_cmd <= bg_DFcmd_cmd when ( SB_type = is_MA55 or SB_type = is_SYS1 ) else X"0F"; -- cmd for folder to playback

DFcmd_par1 <=
X"0A" when game_sel = "111111" else  -- folder 10 Mars
X"0C" when game_sel = "111110" else -- folder 12 Volcano
X"0E" when game_sel = "111101" else  -- folder 14 Black Hole						
X"12" when game_sel = "111100" else  -- folder 18 Devils Dare
X"14" when game_sel = "111011" else  -- folder 20 - Rocky
X"17" when game_sel = "111010" else  -- folder 23 - Striker
X"19" when game_sel = "111001" else  -- folder 25 - Q*Bert's Quest
X"3F" when game_sel = "111000" else  -- folder 63 - Caveman
--X"40" when game_sel = "110111" else  -- folder 64 - Test (numbers as wav)
X"00"; --default 0 (e.g. for SYS1)
--

DFcmd_par2 <=  bg_DFcmd_par2 when ( SB_type = is_MA55 or SB_type = is_SYS1 ) else "000" & Sound_meta;

-- PORTABILITE : l'index de speech_ctrl est BORNE. Le vecteur est declare
-- (31 downto 1), mais to_integer(unsigned(Sound_meta)) vaut 0 a 31 -- et 0 est
-- justement l'etat de REPOS des entrees son. Le garde a gauche du `and` etait
-- cense proteger, mais en VHDL le `and` n'est PAS court-circuitant : les deux
-- operandes sont evalues, et l'indice 0 sort du vecteur. Ca se synthetise sans
-- broncher et ca ne peut pas se simuler -- la toute premiere elaboration de
-- gosof80 meurt a l'instant zero, avant meme le premier front d'horloge.
--
-- LA CORRECTION EST NEUTRE, et c'est verifiable : quand Sound_meta vaut 0, le
-- garde ( Sound_meta(0) or ... or Sound_meta(3) ) vaut deja '0', donc le
-- resultat est '0' quelle que soit la valeur lue. Borner l'indice a 1 ne change
-- donc aucun comportement -- ca rend seulement l'expression legale.
--
-- Defaut PRISTINE, present a l'identique dans origin/main:GOSOF80.vhd:369.
-- A signaler a bontango, pas a corriger en silence : c'est son programme.
-- a i¸ ECRITE DANS CE SENS A DESSEIN. Avec une metavaleur ('U' a l'instant zero),
-- une comparaison IEEE rend FALSE. Ecrite Â" 1 when = 0 else to_integer(...) Â", la
-- garde laisserait donc passer 'U' vers le else, to_integer rendrait 0, et 0 est
-- hors de la plage 1..31 : la simulation meurt quand meme. Le cas SUR doit etre
-- le defaut. (Meme piege exactement que la borne d'horloge de sc01_glue.vhd:86.)
speech_idx <= to_integer(unsigned(Sound_meta)) when unsigned(Sound_meta) >= 1 else 1;

-- LA DOUBLE PAROLE, ET POURQUOI ELLE APPARAIT MAINTENANT.
--
-- Chez bontango, le SC01 est un LEURRE : il ne sort aucun son (Votrax-SC01.vhd:15,
-- Â" only a simulation of signaling to fool the program Â"). La parole vient donc
-- entierement du module MP3, declenche par send_flag quand speech_ctrl marque la
-- commande de son comme Â" parole Â". C'est coherent : une seule voix.
--
-- Ce portage met un VRAI SC-01A a la place du leurre. Sur une carte MA-216, le
-- jeu ecrit un phoneme en $2xxx -- le coeur le synthetise -- ET send_flag monte,
-- parce que la meme commande est marquee parole. DEUX voix disent la meme phrase
-- en meme temps. Sur Volcano c'est 18 commandes sur 31 ; sur Black Hole 13.
--
-- On ferme donc la voie MP3 la ou le vrai chip parle, c'est-a-dire exactement la
-- ou speech_en vaut '1' (MA-216 seulement, :222). Partout ailleurs -- MA-309,
-- MA-55, MA-490, SYS1 -- speech_en vaut '0', le terme ajoute vaut '1', et le
-- comportement est INCHANGE : le MP3 y reste la seule source de parole.
--
-- PAROLE_MP3_AUSSI = true retablit l'amont a l'identique. Le generique existe
-- parce que c'est le programme de Ralf : le choix doit rester reversible, et se
-- voir.
send_flag <= bg_send_flag when ( SB_type = is_MA55 or SB_type = is_SYS1 ) else
				 ( Sound_meta(0) or Sound_meta(1) or Sound_meta(2) or Sound_meta(3))
				 and not speech_ctrl(speech_idx)
				 and ( MP3_AUSSI or not speech_en );

				
				
-- do some signaling 
--LED_1 <= not sc01_AR;
LED_1 <= '1' when SB_type = is_SYS1 else '0';
LED_2 <= riot_pa_i(7);

-- RAM
RIOT_RAM: entity work.RAM -- RIOT internal RAM 128Byte
port map(
	address	=> cpu_addr(6 downto 0),
	clock		=> clk_50, 
	data		=>  cpu_dout (7 DOWNTO 0),
	wren 		=> ram_cs and not cpu_wr_n,
	q			=> ram_dout
);

-- 9600 baud send clock
uart_gen: entity work.uart_clk_gen 
port map(   
	clk_in => clk_50,
	uart_clk_out	=> uart_clk
);

-- cpu clock 892Khz
clock_gen: entity work.cpu_clk_gen 
port map(   
	clk_in => clk_50,
	cpu_clk_out	=> cpu_clk,
	clk_adj => option(2 downto 0)
);

-- 6502 CPU
CPU : entity work.T65
port map(
	Enable => '1',
	Mode => "00",
	Res_n => reset_l,
	Clk => cpu_clk,
	Rdy => '1',
	Abort_n => '1',
	IRQ_n => n_Cpu_irq,
	NMI_n => n_Cpu_nmi,
	SO_n => '1',
	R_W_n => cpu_wr_n,
	A => cpu_addr_24,
	DI => cpu_din,
	DO => cpu_dout
);	

cpu_addr <= cpu_addr_24(15 downto 0);

-- we use a 6532 also for MA55 and MA490, so we have to adjust the address
addr_6532 <= cpu_addr(4 downto 0) when (SB_type = is_MA216 or SB_type = is_MA309) else
				  '1' & cpu_addr(3 downto 0);
				  
 
 
-- 6532 RAM-IO-Timer	
RIOT : entity work.R6532
port map(
	PHI2 		=> phi2, 	
	RST_N 	=> reset_l, 
	CS			=> riot_cs,
	RW_n 		=> cpu_wr_n,
	IRQ_N		=> n_riot_irq,
	
	ADD			=> addr_6532,
	DIN		=> cpu_dout,
	DOUT		=> riot_dout,
	
   PA_IN		=> riot_pa_i,
	PA_OUT		=> riot_pa_o,
   PB_IN		=> riot_pb_i,
	PB_OUT		=> riot_pb_o	

);

--Latch for pulling DAC data from the CPU data bus
-- La page 0x3xxx fixe l'horloge du SC-01 sur la vraie carte : Gosof la decodait
-- deja (dac_latch_speech) et jetait la valeur. On la garde.
Speech_Clock_Latch: Process(clk_50) is
Begin
	If rising_edge(clk_50) then
		if dac_latch_speech = '1' then
			speech_clk_dac <= cpu_dout;
		end if;
	end if;
end process;

Audio_DAC_Latch: Process(clk_50) is
Begin
	If rising_edge(clk_50) then
		if dac_latch = '1' then
			audio_dat_latch <= cpu_dout;
		end if;		
	end if;
end process;

-- different audio sources for MA216/Ma309 and other soundboards
audio_dat <= audio_dat_latch when ( SB_type = is_MA216 or SB_type = is_MA309) else
				 riot_pa_o;
				 
				 
-- Delta-Sigma audio DAC
-- Les deux voies se rejoignent ICI. Sur la carte de bontango elles se melangent
-- en analogique, chacune avec son potentiometre ; le SC-01A etant desormais dans
-- le FPGA, la somme est numerique et il faut la borner soi-meme.
Melangeur : entity work.audio_mix
generic map( SPCH_GAIN => 512 )
port map(
   clk        => clk_50,
   gosof_u8   => audio_dat,
   speech_s18 => sc01_audio,
   dac_u16    => audio_mixe,
   sature     => mix_sature
);

Audio_DAC : entity work.dac
generic map(
  msbi_g => 15)
port  map(
   clk_i   => clk_50,
   res_n_i => reset_l,
   dac_i   => audio_mixe,
   dac_o   => audio_O
);

---------------------
-- SD card stuff
----------------------

SD_game_sel <= "00000000" when option(3) = '0' else -- with DIP4 ON read gamne #0 (sector #660 )
					"00" & not game_sel(5 downto 0);

-- ------------------------------------------------------------------------
-- LE RESET, ET D'OU IL VIENT.
-- En mode normal c'est la carte SD qui le relache, une fois les 4 Ko charges.
-- En SANS_SD la ROM est deja dans le bitstream : un compteur suffit. 2^20
-- cycles a 50 MHz = 21 ms, largement de quoi laisser l'horloge processeur et
-- le SC-01A sortir de leur propre initialisation.
Reset_Sans_SD : process (clk_50)
begin
	if rising_edge(clk_50) then
		if por_cpt(por_cpt'high) = '0' then
			por_cpt   <= por_cpt + 1;
			reset_por <= '0';
		else
			reset_por <= '1';
		end if;
	end if;
end process;

reset_l <= reset_por when SANS_SD else reset_sd;

-- LE GARDE-FOU. Construire en SANS_SD avec le paquet gosof_jeu VIDE donnerait un
-- 6502 executant 4 Ko de zeros : ca se compile, ca se place, ca se charge, et ca
-- ne dit rien. C'est exactement la famille de pannes que ce projet paie cher.
assert (not SANS_SD) or JEU_PRESENT
	report "SANS_SD=true mais le paquet gosof_jeu est le paquet VIDE : les ROMs "
	     & "seraient a zero et le 6502 executerait du neant. Engendrez la ROM "
	     & "avec outils/rom_vers_vhdl.py et compilez ce fichier-la a la place de "
	     & "rtl/spartan6/gosof_jeu_vide.vhd."
	severity failure;

-- ------------------------------------------------------------------------
-- TRACE DE SIMULATION. Trois inconnues qu'aucune synthese ne peut lever :
--   1. le jeu ECRIT-IL la page $3xxx ? Si oui, l'horloge du SC-01 est pilotee
--      en cours de partie et la valeur par defaut x"A0" n'a plus d'importance.
--      Si non, c'est ce defaut-la qui fixe le timbre de toute la machine.
--   2. combien de phonemes le jeu strobe-t-il reellement ?
--   3. le melangeur ECRETE-t-il ? La saturation est indispensable, mais on ne
--      savait pas si elle etait atteinte -- donc si sa forme comptait.
-- A TRACE=false ce processus est vide et la synthese l'ignore.
Trace_Sim : process (clk_50)
	variable n_horl, n_phon, n_sat, n_dac, n_mp3 : integer := 0;
	variable mp3_prec : std_logic := '0';
	variable horl_vue : std_logic_vector(7 downto 0) := (others => 'U');
	variable stb_prec : std_logic := '0';
	-- PAS `ms` : ce nom masquerait l'unite de temps ms et la division
	-- `now / 1 ms` cesserait de compiler. (Piege paye trois fois cette seance,
	-- apres `ns` dans deux bancs de simulation.)
	variable n_ms_prec : integer := -1;
	variable n_ms      : integer;
		-- Le nom du phoneme SC-01 pour un code de 6 bits (table du constructeur).
		-- Sert a VERIFIER la polarite du bus : le ROM Gottlieb ecrit ses codes
		-- EOR #$3F, donc UNE des deux colonnes (brut / inverse) doit epeler de
		-- l'anglais, et l'autre du charabia.
		function nom_phon(c : integer) return string is
		begin
			case c is
				when 0 => return "EH3"; when 1 => return "EH2"; when 2 => return "EH1"; when 3 => return "PA0";
				when 4 => return "DT"; when 5 => return "A1"; when 6 => return "A2"; when 7 => return "ZH";
				when 8 => return "AH2"; when 9 => return "I3"; when 10 => return "I2"; when 11 => return "I1";
				when 12 => return "M"; when 13 => return "N"; when 14 => return "B"; when 15 => return "V";
				when 16 => return "CH"; when 17 => return "SH"; when 18 => return "Z"; when 19 => return "AW1";
				when 20 => return "NG"; when 21 => return "AH1"; when 22 => return "OO1"; when 23 => return "OO";
				when 24 => return "L"; when 25 => return "K"; when 26 => return "J"; when 27 => return "H";
				when 28 => return "G"; when 29 => return "F"; when 30 => return "D"; when 31 => return "S";
				when 32 => return "A"; when 33 => return "AY"; when 34 => return "Y1"; when 35 => return "UH3";
				when 36 => return "AH"; when 37 => return "P"; when 38 => return "O"; when 39 => return "I";
				when 40 => return "U"; when 41 => return "Y"; when 42 => return "T"; when 43 => return "R";
				when 44 => return "E"; when 45 => return "W"; when 46 => return "AE"; when 47 => return "AE1";
				when 48 => return "AW2"; when 49 => return "UH2"; when 50 => return "UH1"; when 51 => return "UH";
				when 52 => return "O2"; when 53 => return "O1"; when 54 => return "IU"; when 55 => return "U1";
				when 56 => return "THV"; when 57 => return "TH"; when 58 => return "ER"; when 59 => return "EH";
				when 60 => return "E1"; when 61 => return "AW"; when 62 => return "PA1"; when 63 => return "STOP";
				when others => return "?";
			end case;
		end function;
begin
	if TRACE and rising_edge(clk_50) then
		if dac_latch_speech = '1' then
			n_horl := n_horl + 1;
			if cpu_dout /= horl_vue then
				horl_vue := cpu_dout;
				report "TRACE $3xxx <= " & integer'image(to_integer(unsigned(cpu_dout)))
				     & " decimal (octet d'horloge SC-01) a " & time'image(now);
			end if;
		end if;
		if dac_latch = '1'         then n_dac  := n_dac + 1;  end if;
		if mix_sature = '1'        then n_sat  := n_sat + 1;  end if;
		if sc01_strobe = '1' and stb_prec = '0' then
			n_phon := n_phon + 1;
			report "TRACE PHONEME #" & integer'image(n_phon) & " octet=" & integer'image(to_integer(unsigned(cpu_dout)))
			     & "  brut=" & nom_phon(to_integer(unsigned(cpu_dout(5 downto 0))))
			     & "  inverse=" & nom_phon(63 - to_integer(unsigned(cpu_dout(5 downto 0))))
			     & "  a " & time'image(now);
		end if;
		stb_prec := sc01_strobe;
		if send_flag = '1' and mp3_prec = '0' then n_mp3 := n_mp3 + 1; end if;
		mp3_prec := send_flag;

		-- un bilan par milliseconde : une trace evenement par evenement noierait
		-- l'information sous des milliers de lignes.
		n_ms := now / 1 ms;
		if n_ms /= n_ms_prec then
			n_ms_prec := n_ms;
			if n_ms > 0 then
				report "TRACE t=" & integer'image(n_ms) & "ms  ecritures DAC=" & integer'image(n_dac)
				     & "  ecritures $3xxx=" & integer'image(n_horl)
				     & "  phonemes=" & integer'image(n_phon)
				     & "  cycles ecretes=" & integer'image(n_sat)
				     & "  declenchements MP3=" & integer'image(n_mp3);
			end if;
		end if;
	end if;
end process;

SD_CARD: entity work.SD_Card
port map(	
	--
	i_clk		=> clk_50,	
	-- Control/Data Signals,
   i_Rst_L  => reset_sw,    
	-- PMOD SPI Interface
   o_SPI_Clk  => SD_CLK,
   i_SPI_MISO => SD_MISO,
   o_SPI_MOSI => SD_MOSI,
   o_SPI_CS_n => SD_CS,	
	-- selection	
	selection => SD_game_sel,
	-- data
	address_sd_card => address_sd_card,
	data_sd_card => data_sd_card,
	wr_rom => wr_rom,
	-- control CPU
	cpu_reset_l => reset_sd,
	-- feedback
	SDcard_error => LED_0,
	dbg_tx => DBG_TX
	);	
	
-- soundrom1 for MA219/MA309
-- soundrom for MA55 and others	
SOUNDROM1: entity work.SB_ROM -- ROM 2KByte
generic map( INIT => JEU_ROM1 )   -- zeros avec le paquet vide ; la ROM en SANS_SD
port map(
	address	=> soundrom1_addr,  -- 10 downto 0
	clock		=> clk_50, 
	data 		=> data_sd_card,
	wren 		=> wr_soundrom1,
	q			=> soundrom1_dout
	);

-- soundrom2 for MA219/MA309
-- maskrom (R6530 internal) for MA55 and others	
SOUNDROM2: entity work.SB_ROM -- ROM 2KByte
generic map( INIT => JEU_ROM2 )
port map(
	address	=> soundrom2_addr,  -- 10 downto 0
	clock		=> clk_50, 
	data 		=> data_sd_card,
	wren 		=> wr_soundrom2,
	q			=> soundrom2_dout
	);

	
end rtl;
