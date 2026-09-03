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

entity gosof80 is
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
		SD_CLK : out    	std_logic		
		
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
	signal audio_dat_latch	: 	std_logic_vector(7 downto 0);
   signal audio_dat	: 	std_logic_vector(7 downto 0);	
	
	-- speech
	signal DAC_latch_speech	:  std_logic;
	signal sc01_strobe	:  std_logic;
	signal sc01_AR			:  std_logic;
	-- ajouts du portage : la voie parole, son melange, et la porte de carte
	signal sc01_audio	:  signed(17 downto 0);
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
	DDS_INC               => 3435974,   -- 720 kHz, valeur de la fiche technique
	IGNORE_STB_WHILE_BUSY => true,      -- comme le leurre : pas de relance en cours de phoneme
	INFLECTION_SRC        => 0          -- "00" : rien ne prouve que la MA-216 cablait I1/I2
)
port map(
         clk => clk_50,
			reset_n => reset_l,
			speech_en => speech_en,
			strobe => sc01_strobe,
			cpu_data => cpu_dout,
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
wr_soundrom1 <= '1' when ((wr_rom='1') and (address_sd_card(13 downto 11) ="000" )) else '0';
soundrom1_addr <=  --2K
	address_sd_card(10 downto 0) when wr_soundrom1 = '1' else
	'0' & cpu_addr(9 downto 0) when (SB_type = is_MA55 or SB_type = is_SYS1) else -- MA55 and SYS1 have only 1K rom
	cpu_addr(10 downto 0);

-- content of sound rom 2 is read from second 2K of SD
wr_soundrom2 <= '1' when ((wr_rom='1') and (address_sd_card(13 downto 11) ="001" )) else '0';
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

send_flag <= bg_send_flag when ( SB_type = is_MA55 or SB_type = is_SYS1 ) else
				 ( Sound_meta(0) or Sound_meta(1) or Sound_meta(2) or Sound_meta(3)) and not speech_ctrl(to_integer(unsigned(Sound_meta)));

				
				
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
   dac_u16    => audio_mixe
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
	cpu_reset_l => reset_l,
	-- feedback
	SDcard_error => LED_0
	);	
	
-- soundrom1 for MA219/MA309
-- soundrom for MA55 and others	
SOUNDROM1: entity work.SB_ROM -- ROM 2KByte
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
port map(
	address	=> soundrom2_addr,  -- 10 downto 0
	clock		=> clk_50, 
	data 		=> data_sd_card,
	wren 		=> wr_soundrom2,
	q			=> soundrom2_dout
	);

	
end rtl;