--
-- SD_Card.vhd
-- read SD card in 'raw' Mode to move code to RAM/ROM
-- version with reset_l and 16KByte
-- for GoSof(80)
-- bontango 09.2021
--
-- v01 added feedback on successfull SD card read
-- v02 synchronous reset
-- v03 extended CMD to 14 bytes, added second R1 position (needed for some cards), added error state
-- v04 read 4Kblock ( 8 sectors) for two 2k SOUNDROMS

library IEEE;
use IEEE.std_logic_1164.all;
--use IEEE.std_logic_arith.all;
--use IEEE.std_logic_unsigned.all;
use IEEE.numeric_std.all;

	entity SD_Card is
		-- DELAI : cycles de 50 MHz avant le premier essai, et entre deux relances.
		-- 25 000 000 = 500 ms sur la carte ; un banc de simulation le raccourcit.
		generic ( DELAI : integer range 1 to 25000000 := 25000000 );
		port(
		i_Clk		: IN STD_LOGIC  := '1';
		-- Control/Data Signals,
		i_Rst_L : in std_logic;     -- FPGA Reset		
		-- PMOD SPI Interface
		o_SPI_Clk  : out std_logic;
		i_SPI_MISO : in std_logic;
		o_SPI_MOSI : out std_logic;
		o_SPI_CS_n : out std_logic;
		-- selektion
		selection : in std_logic_vector(7 downto 0);
		-- sd card
		address_sd_card	: buffer  std_logic_vector(13 downto 0);
		data_sd_card	: out std_logic_vector(7 downto 0);
		wr_rom :  out std_logic;		
		-- start CPU
		cpu_reset_l : out STD_LOGIC;
		-- feedback
		SDcard_error : out STD_LOGIC;
		-- INSTRUMENT DE MESURE : trame d'etat en UART 115200 8N1, voir le processus Trace.
		dbg_tx : out std_logic;
		-- TEMOINS DU 6502 fournis par GOSOF80 : 19 octets, emis dans la trame B.
		trace_cpu : in std_logic_vector(151 downto 0) := (others => '0')
		);
    end SD_Card;
	 
   architecture Behavioral of SD_Card is		
		type STATE_T is ( Startdelay, send_read_request, wait_for_read, continue, 
								initiate_read_sector, wait_for_begin_of_data,check_for_FE_flag, sector_read, wait_for_byte_read,
								check_sector_byte, inc_addr_and_unset_wr, stop_read, delay_and_repeat, all_done, error );
		signal state_A : STATE_T;       
		
		
		-- SPI stuff for SD card commands	
		signal TX_Data_A : std_LOGIC_VECTOR ( 111 downto 0); -- 14 Bytes ( 6 cmd bytes, 1 NCR ,1 Return ,4 CMD Echo )
		signal RX_Data_A : std_LOGIC_VECTOR ( 111 downto 0);  -- we also send 0xFF with CS disable before and after
		signal TX_Start_A : std_LOGIC;
		signal TX_Done_A : std_LOGIC;
		signal MOSI_A : std_LOGIC;
		signal SS_A :  std_LOGIC;
		signal SPI_Clk_A :  std_LOGIC;

		-- SPI stuff for SD card read, byte by byte
		signal TX_Data_R : std_LOGIC_VECTOR ( 7 downto 0); 
		signal RX_Data_R : std_LOGIC_VECTOR ( 7 downto 0);
		signal TX_Start_R : std_LOGIC;
		signal TX_Done_R : std_LOGIC;
		signal MOSI_R : std_LOGIC;
		signal SS_R :  std_LOGIC;
		signal SPI_Clk_R :  std_LOGIC;
		
		-----		
		signal cmd_count : integer range 0 to 16; 
		signal R1_response : std_LOGIC_VECTOR (7 downto 0);		
		signal Echo_response : std_LOGIC_VECTOR (7 downto 0);		
		signal active_master : std_LOGIC_VECTOR (1 downto 0) := "00";
		signal do_not_disable_SS : std_LOGIC;		
		signal sector : unsigned (15 downto 0);	
		
		signal byte_count : integer range 0 to 520; 
		-- octets lus sans trouver de jeton 0xFE ; au-dela de 10 000 (~200 ms a
		-- 403 kHz, deux fois le delai maximal de la norme) on part en `error`.
		signal fe_attente : integer range 0 to 10000 := 0;		
		-- --- TRACE : ce que la machine a VU, fige pour l'instrument -------------------
		-- Rien de ceci n'influence la machine d'etat : ces signaux sont seulement ECRITS
		-- par elle et LUS par le processus Trace.
		signal rx_snap   : std_logic_vector(55 downto 0) := (others => '1'); -- octets fil 7..13 de la derniere reponse
		signal cmd_snap  : integer range 0 to 16 := 0;                      -- la commande dont rx_snap est la reponse
		signal nb_jetons : unsigned(7 downto 0)  := (others => '0');        -- jetons 0xFE trouves
		signal somme     : unsigned(15 downto 0) := (others => '0');        -- somme des octets ecrits en ROM
		signal relances  : unsigned(7 downto 0)  := (others => '0');        -- redemarrages apres erreur
		type trame_t is array (0 to 21) of std_logic_vector(7 downto 0);
		signal trame     : trame_t := (others => (others => '1'));
		signal tr_tick   : integer range 0 to 4999999 := 0;                 -- 100 ms a 50 MHz
		signal tr_baud   : integer range 0 to 433 := 0;                     -- 50 MHz / 434 = 115 207 bauds
		signal tr_bit    : integer range 0 to 9 := 0;
		signal tr_octet  : integer range 0 to 22 := 22;                     -- 22 = au repos
		signal tr_seq    : unsigned(7 downto 0) := (others => '0');
		signal tr_b      : std_logic := '0';                                -- '1' : la prochaine trame est B
		signal tr_tx     : std_logic := '1';
		function code_etat(s : STATE_T) return integer is
		begin
			case s is
				when Startdelay => return 0;             when send_read_request => return 1;
				when wait_for_read => return 2;          when continue => return 3;
				when initiate_read_sector => return 4;   when wait_for_begin_of_data => return 5;
				when check_for_FE_flag => return 6;      when sector_read => return 7;
				when wait_for_byte_read => return 8;     when check_sector_byte => return 9;
				when inc_addr_and_unset_wr => return 10; when stop_read => return 11;
				when delay_and_repeat => return 12;      when all_done => return 13;
				when error => return 14;
			end case;
		end function;
		
		signal attempts : integer range 0 to 5000; 
		-- !! LE RESET DU 6502 N'EXISTAIT PAS SUR CETTE PORTEUSE, ET C'EST LA PANNE DU MODE SD.
		--    Les trois sorties ci-dessous n'etaient remises a zero QUE par la branche de
		--    reset (i_Rst_L = '0'). Sur la carte Cyclone d'origine, i_Rst_L est un bouton :
		--    la branche vit, et de toute facon un registre Altera demarre a 0. Ici reset_sw
		--    est cable a '1' (aucune source sur la porteuse) : la branche est MORTE, et
		--    cpu_reset_l n'etait plus affecte qu'a '1'. XST a donc le droit d'en faire la
		--    constante '1' -- et il l'a fait : son rapport liste un registre pour
		--    SDcard_error et pour wr_rom, AUCUN pour cpu_reset_l. Le 6502 tournait donc des
		--    la configuration, sur une ROM vide, et le chargement SD -- parfait, mesure par
		--    la trace -- ecrivait la ROM sous ses pieds sans qu'il redemarre jamais dessus.
		--    Silence. En SANS_SD le reset vient d'un compteur a valeur initiale explicite :
		--    d'ou "la ROM dans le bitstream parle, la meme ROM lue sur la SD non".
		--    La valeur initiale EXPLICITE ci-dessous oblige le registre a exister et a
		--    demarrer a la bonne valeur, avec ou sans branche de reset vivante.
		--    Reproduit en simulation (tb_gosof80_sd.vhd) : sans elle, cpu_reset_l vaut 'U',
		--    le T65 n'est jamais en reset et n'ecrit jamais $3000.
		signal cpu_reset_i : std_logic := '0';   -- 6502 tenu jusqu'a all_done
		signal sd_erreur_i : std_logic := '1';   -- D5 eteinte (actif bas) jusqu'a une erreur
		signal wr_rom_i    : std_logic := '0';
		signal counter  : integer range 0 to 25000000;   -- delay, for 10ms use 500.000
	begin		
	cpu_reset_l  <= cpu_reset_i;
	SDcard_error <= sd_erreur_i;
	wr_rom       <= wr_rom_i;
		
		-- signals for the two SPI Master
	o_SPI_MOSI <=	
	MOSI_A when active_master = "01" else
	MOSI_R when active_master = "10" else
	'0';

	o_SPI_Clk <=
	SPI_Clk_A when active_master = "01"  else
	SPI_Clk_R when active_master = "10"  else
	'0';

	-- Les horloges de reveil (cmd_count = 0) partent avec CS HAUT, comme le veut
	-- la procedure d'initialisation SPI : l'amont les envoyait carte selectionnee.
	o_SPI_CS_n <=
	'1' when active_master = "01" and cmd_count = 0 else
	SS_A when active_master = "01"  else
	'0' when active_master = "10" else
	'1';
	
	
SD_CARD_ACCESS: entity work.SPI_Master
    generic map (      
      Laenge => 112,
		SPI_Taktfrequenz => 400000) -- 400KHz for commands
    port map (
			  TX_Data  => TX_Data_A,
           RX_Data  => RX_Data_A,
           MOSI     => MOSI_A,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_A,
           SS       => SS_A,
           TX_Start => TX_Start_A,
           TX_Done  => TX_Done_A,
           clk      => i_Clk,	  
			  do_not_disable_SS => do_not_disable_SS
      );
		
SD_CARD_READ: entity work.SPI_Master --read i byte by byte (slooow)
    generic map (      
      Laenge => 8,
		SPI_Taktfrequenz => 400000) -- 400KHz for commands
    port map (
			  TX_Data  => TX_Data_R,
           RX_Data  => RX_Data_R,
           MOSI     => MOSI_R,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_R,
           SS       => SS_R,
           TX_Start => TX_Start_R,
           TX_Done  => TX_Done_R,
           clk      => i_Clk,
			  do_not_disable_SS => do_not_disable_SS
      );

		
		SD_Card: process (i_Clk, i_Rst_L )
			--constant all_high : std_LOGIC_VECTOR (47 downto 0) := x"FFFFFFFFFFFF";
			constant CMD0 : std_LOGIC_VECTOR (47 downto 0) := x"400000000095"; --reset			
			constant CMD8 : std_LOGIC_VECTOR (47 downto 0) := x"48000001AA87"; --check the version of SD card					
			--constant CMD1 : std_LOGIC_VECTOR (47 downto 0) := x"4100000000F9"; -- initiate the initialization process (old cards)
			--only support for 'new' Sd cards at the moment
			constant CMD55 : std_LOGIC_VECTOR (47 downto 0) := x"7700000000FF";	-- leading cmd for AMD commands 
			constant ACMD41 : std_LOGIC_VECTOR (47 downto 0) := x"6940000000FF";	-- initiate the initialization process			
			constant CMD17 : std_LOGIC_VECTOR (47 downto 0) := x"5100000000FF"; --single-read block
			constant CMD18 : std_LOGIC_VECTOR (47 downto 0) := x"5200000000FF"; --multi-read block
			constant CMD12 : std_LOGIC_VECTOR (47 downto 0) := x"4C00000000FF"; --stop to read data
			constant CMD58 : std_LOGIC_VECTOR (47 downto 0) := x"7A00000000FF"; --read OCR
			
			variable trouve : boolean;
		begin
		if rising_edge(i_Clk) then
			if i_Rst_L = '0' then --Reset condidition (reset_l)    
				cpu_reset_i <= '0';
				TX_Start_A <= '0';		
				TX_Start_R <= '0';		
				TX_Data_R <= x"FF";				
				cmd_count <= 0;
				active_master <= "00";
				do_not_disable_SS <= '0'; --default
				wr_rom_i <= '0';
				address_sd_card <= (others => '0');
				byte_count <= 0;
				sd_erreur_i <= '1'; -- active low
				counter <= 0;
				attempts <= 0;
				state_A <= Startdelay;    
			else			
				case state_A is
				-- STATE MASCHINE ----------------
				 when Startdelay => 
						active_master <= "01";			
					--give SD card time to power up					
					-- PORTABILITE : on n'incremente QUE si on n'est pas deja au bout.
					-- counter est declare `integer range 0 to 5000000` et l'increment
					-- s'executait AVANT le test : au cycle ou il vaut 5000000,
					-- l'assignation tente 5000001. GHDL verifie la plage a l'execution
					-- de l'assignation, avant que le `counter <= 0` du if ne l'ecrase --
					-- et la simulation meurt a EXACTEMENT 100 ms, dans toutes les
					-- configurations. En synthese le compteur boucle, c'est inoffensif.
					-- C'est pour cela que gosof80 n'avait jamais pu etre simule au-dela.
					--
					-- La correction est NEUTRE : l'etat change toujours quand le compteur
					-- atteint 5000000, au meme cycle qu'avant. Defaut PRISTINE, identique
					-- dans origin/main:SD_Card.vhd. A signaler a bontango.
					-- 500 ms et non plus 100 : valeur de la revision amont de 06.2025
					-- (hyb_ay/lib_common/SD_Card.vhd). Laisse aussi passer les messages
					-- du chargeur ROM de l'ESP, emis au demarrage sur P41 -- la broche de
					-- sd_cs sur cette porteuse.
					if ( counter = DELAI ) then --500ms 
						state_A <= send_read_request;
						counter <= 0;						
					else
						counter <= counter +1;					
					end if;																													
				when send_read_request =>						
				   case cmd_count is
						when 1 => TX_Data_A <= x"FF" & CMD0 & x"FFFFFFFFFFFFFF"; --go idle state, resets SD card
						when 2 => TX_Data_A <= x"FF" & CMD8 & x"FFFFFFFFFFFFFF";	-- send interface condition
						when 3 => TX_Data_A <= x"FF" & CMD55 & x"FFFFFFFFFFFFFF";						
						when 4 => TX_Data_A <= x"FF" & ACMD41 & x"FFFFFFFFFFFFFF";		
						when 5 => TX_Data_A <= x"FF" & CMD58 & x"FFFFFFFFFFFFFF";		
						-- !! LA COMMANDE EN FIN DE TRAME. La trame fait 112 bits, taillee pour la
						--    reponse R7 de CMD8 : avec la commande au debut, CINQ octets etaient
						--    cadences APRES le R1 et jetes sans etre regardes. Une carte rapide y
						--    envoie deja le jeton 0xFE du premier bloc : il etait perdu, et la
						--    chasse au jeton se raccrochait au premier 0xFE trouve DANS les donnees.
						--    Les 4096 octets etaient ecrits quand meme, decales, et le reset
						--    relache sur une ROM fausse : carte muette, aucune erreur. Ici plus
						--    rien n'est cadence apres la commande : R1, remplissage et jeton sont
						--    lus un par un par le maitre R, qui ne prend que le 0xFE (R1 a son bit
						--    7 a 0, il ne peut pas l'etre). Defaut PRISTINE, present aussi dans le
						--    SD_Card.vhd de WillFA7.
						when 6 => TX_Data_A <= x"FFFFFFFFFFFFFFFF" & CMD18;	
									 do_not_disable_SS <= '1';
									 -- special: calculate sector on GoSOF SD
									 -- where to read rom dependign on dip switch
									 -- first rom starts at sector 660
									 -- we have 4 KByte of data
									 -- which is 8 sectors 512Byte each									 
									 -- l'argument de CMD18 occupe maintenant les bits 39..8 ; le secteur va
									 -- dans ses 16 bits bas.
									 TX_Data_A(23 downto 8)  <= std_logic_vector (unsigned(selection) *8 + 660);									 
						when 7 => TX_Data_A <= x"FF" & CMD12 & x"FFFFFFFFFFFFFF";	
									 do_not_disable_SS <= '0';	
						when others => TX_Data_A <= x"FF" & x"FFFFFFFFFFFF" & x"FFFFFFFFFFFFFF"; -- init and read
					end case;
					TX_Start_A <= '1'; -- set flag for sending byte		
					state_A <= wait_for_read;					
										
				when wait_for_read =>					
						if (TX_Done_A = '1') then -- Master sets TX_Done when TX is done ;-)
							TX_Start_A <= '0'; -- reset flag 		
								-- R1 : le PREMIER octet a bit 7 nul parmi les octets fil 7..13, et non
								-- plus une position fixe. La norme autorise 1 a 8 octets de NCR ; l'amont
								-- n'acceptait que 1 (et 2 pour ACMD41 seul) : une carte a NCR=2 echouait
								-- des CMD0, en silence. L'echo de CMD8 est 4 octets apres le R1.
								trouve := false;
								R1_response <= x"FF"; Echo_response <= x"00";
								for k in 0 to 6 loop
									if not trouve and RX_Data_A(55 - 8*k) = '0' then
										trouve := true;
										R1_response <= RX_Data_A(55 - 8*k downto 48 - 8*k);
										if k <= 2 then
											Echo_response <= RX_Data_A(55 - 8*(k+4) downto 48 - 8*(k+4));
										end if;
									end if;
								end loop;
								rx_snap <= RX_Data_A(55 downto 0); cmd_snap <= cmd_count;   -- TRACE
								data_sd_card <= RX_Data_A( 47 downto 40);								
							state_A <= continue;							
						end if;
										
				when continue =>		
					if (TX_Done_A = '0') then -- Master sets back TX_Done when ready again				
								cmd_count <= cmd_count +1;
								case cmd_count is
									when 1 => --check response of CMD0
										if ( R1_response /= x"01") then
											if (attempts < 8) then
												cmd_count <= 1; --repeat
												attempts <= attempts +1;
												state_A <= send_read_request; 
											else
												state_A <= error;
											end if;	
										else --success
											attempts <= 0;
											state_A <= send_read_request; -- next cmd to send																																						
										end if;																		
									when 2 => --check response of CMD8
										if ( ( R1_response /= x"01") or (Echo_response /= x"AA")) then
											state_A <= error;
										else
											state_A <= send_read_request; -- next cmd to send																											
										end if;
									when 4 => -- count 4 is SD card init--repeat CMD55 & ACMD41 until card is READY
										-- 300 essais x ~10,6 ms = 3,2 s ; la norme en exige 1. L'amont en
										-- faisait 5000 : 53 s de silence avant la moindre erreur.
										if ( R1_response /= x"00") then 										
											if (attempts < 300) then
												cmd_count <= 3; --repeat go back to init
												attempts <= attempts +1;
												state_A <= delay_and_repeat; 
											else
												state_A <= error;
											end if;	
										else --success
											attempts <= 0;
											state_A <= send_read_request; -- next cmd to send																																						
										end if;													
									when 6 => --last command send, we now read data
										cmd_count <= 0;	
										TX_Data_R <= x"FF";
										active_master <= "10";		
										address_sd_card <= (others => '0');			
										byte_count <= 0;							
										fe_attente <= 0;
										nb_jetons <= (others => '0'); somme <= (others => '0');   -- TRACE
										state_A <= initiate_read_sector;
									when 7 => -- we send CMD12 to stop read sector, all done
										wr_rom_i <= '0';		
										-- start cpu
										cpu_reset_i <= '1';						
										state_A <= all_done;																
										
									when others =>
										state_A <= send_read_request; -- next cmd to send																											
								end case;
					end if;
					
				when delay_and_repeat =>	
					counter <= counter +1;					
					if ( counter = 500000 ) then --10ms 
						state_A <= send_read_request;
						counter <= 0;						
					end if;											
		--------------------------------------
		-- second master  --------------------
		-- read 8 sectors -------------------
		--------------------------------------
		
				when initiate_read_sector =>				
							TX_Start_R <= '1'; -- set flag for sending byte												
							state_A <= wait_for_begin_of_data;					
							
				when wait_for_begin_of_data =>
							if (TX_Done_R = '1') then -- Master sets TX_Done when TX is done ;-)
							TX_Start_R <= '0'; -- reset flag 		
							state_A <= check_for_FE_flag;
						end if;
						
				when check_for_FE_flag =>							
						if (TX_Done_R = '0') then -- Master sets back TX_Done when ready again						
						data_sd_card <= RX_Data_R;
						   if RX_Data_R = x"FE" then							
						   	nb_jetons <= nb_jetons + 1;   -- TRACE
								state_A <= sector_read; --flag found, next byte is data
							elsif fe_attente = 10000 then
								-- Le jeton n'arrive jamais : ERREUR VISIBLE (D5) plutot que de
								-- chercher pour l'eternite -- ou, pire, de se raccrocher a un
								-- 0xFE fortuit et de relacher le reset sur une ROM fausse.
								state_A <= error;
							else
								fe_attente <= fe_attente + 1;
								state_A <= initiate_read_sector; --next byte to read and check
							end if;							
						end if;
	
				when sector_read =>
							TX_Start_R <= '1'; -- set flag for sending byte		
							wr_rom_i <= '0'; --stop writing to ram/rom
							state_A <= wait_for_byte_read;					
							
				when wait_for_byte_read =>
							if (TX_Done_R = '1') then -- Master sets TX_Done when TX is done ;-)							
									TX_Start_R <= '0'; -- reset flag 	
									-- count byte
									byte_count <= byte_count +1;		
									--assign data
									data_sd_card <= RX_Data_R;											
									state_A <= check_sector_byte;
							end if;
							
				when check_sector_byte =>							
						if (TX_Done_R = '0') then -- Master sets back TX_Done when ready again
							-- where are we in sector read?
							if byte_count <= 512 then	-- in sector read
								wr_rom_i <= '1';	-- write to ram/rom with current data & address
								somme <= somme + unsigned(RX_Data_R);   -- TRACE : l'octet que wr_rom ecrit
								state_A <= inc_addr_and_unset_wr;		-- write to ram/rom
							elsif byte_count = 513 then -- premier octet de CRC : lire le second
								state_A <= sector_read;
							else -- 514 : second octet de CRC lu, le secteur est FINI
								-- !! On ne lit plus de 515e octet. L'ancien code en lisait un de
								--    plus et le jetait : si la carte enchaine le bloc suivant sans
								--    octet de remplissage, c'etait le JETON 0xFE qui partait a la
								--    poubelle -- meme effet que la trame CMD18. La chasse au jeton
								--    qui suit accepte zero, un ou plusieurs octets de remplissage.
								byte_count <= 0;
								fe_attente <= 0;
								state_A <= initiate_read_sector;		-- next sector
							end if;																											
						end if;
						
				when inc_addr_and_unset_wr =>		
								wr_rom_i <= '0';	
								-- prepare address for next
								address_sd_card <= std_LOGIC_VECTOR(unsigned(address_sd_card) +1);
								-- finished?								
								if unsigned(address_sd_card) = "00111111111111" then 	-- 4 KByte read in this case									
										state_A <= stop_read;		--just read last byte
								else
										state_A <= sector_read;		-- next byte						
								end if;
												
				when stop_read =>																
								cmd_count <= 7; --we use cmd counter from init routine								
								active_master <= "01"; --because sending of a command								
								state_A <= send_read_request; 
								
				when all_done =>		
					sd_erreur_i <= '1'; --active low
				when error =>		
					sd_erreur_i <= '0'; --active low
					-- NOUVEL ESSAI toutes les 500 ms, depuis les horloges de reveil. L'amont
					-- restait ici pour toujours : une carte SD inaccessible au premier essai
					-- (inseree en retard, ligne encore tenue par l'ESP qui demarre) rendait
					-- la carte son muette jusqu'a la coupure du courant. CS est relache
					-- pendant l'attente : une erreur survenue en lecture le laissait BAS.
					active_master <= "01";
					do_not_disable_SS <= '0';
					wr_rom_i <= '0';
					if ( counter = DELAI ) then
						counter <= 0;
						cmd_count <= 0;
						attempts <= 0;
						if relances /= 255 then relances <= relances + 1; end if;
						state_A <= send_read_request;
					else
						counter <= counter + 1;
					end if;
				end case;	
			end if; --rst 
		end if; --rising edge					
	end process;
				
					

	-- ------------------------------------------------------------------------
	-- TRACE (instrument de mesure). Toutes les 100 ms, une trame de 22 octets en
	-- UART 115200 8N1 sur dbg_tx, lue cote ESP par PSTORE RXDUMP (UART1, GPIO18).
	-- Ce processus ne fait que LIRE la machine d'etat.
	--   0-1   A5 5A      synchro
	--   2     etat       code_etat(state_A) : 0 Startdelay .. 13 all_done, 14 error
	--   3     cmd_count
	--   4-5   attempts   poids faible d'abord
	--   6     cmd_snap   la commande dont 7-13 est la reponse
	--   7-13  rx_snap    octets fil 7..13 de cette reponse (R1 attendu en 8)
	--   14    nb_jetons
	--   15-16 adresse    address_sd_card, poids faible d'abord
	--   17-18 somme      des octets ecrits en ROM, poids faible d'abord
	--   19    fe_attente (poids faible)
	--   20    relances   redemarrages depuis CMD0 apres une erreur
	--   21    seq        compteur de trames
	-- Une trame sur deux est la TRAME B (A5 5B) : les temoins du 6502, voir
	-- Temoins_CPU dans GOSOF80.vhd pour l'ordre des 19 octets.
	-- ------------------------------------------------------------------------
	Trace : process (i_Clk)
		variable att : unsigned(15 downto 0);
		variable adr : unsigned(15 downto 0);
		variable b   : std_logic_vector(7 downto 0);
	begin
		if rising_edge(i_Clk) then
			if tr_tick = 4999999 then tr_tick <= 0; else tr_tick <= tr_tick + 1; end if;
			if tr_octet = 22 then
				tr_tx <= '1';
				if tr_tick = 0 and tr_b = '1' then
					-- TRAME B : A5 5B, les 19 octets de temoins du 6502, seq.
					trame(0) <= x"A5";
					trame(1) <= x"5B";
					for k in 0 to 18 loop
						trame(k + 2) <= trace_cpu(8*k + 7 downto 8*k);
					end loop;
					trame(21) <= std_logic_vector(tr_seq);
					tr_seq   <= tr_seq + 1;
					tr_b     <= '0';
					tr_octet <= 0; tr_bit <= 0; tr_baud <= 0;
				elsif tr_tick = 0 then
					tr_b <= '1';
					att := to_unsigned(attempts, 16);
					adr := resize(unsigned(address_sd_card), 16);
					trame(0)  <= x"A5";
					trame(1)  <= x"5A";
					trame(2)  <= std_logic_vector(to_unsigned(code_etat(state_A), 8));
					trame(3)  <= std_logic_vector(to_unsigned(cmd_count, 8));
					trame(4)  <= std_logic_vector(att(7 downto 0));
					trame(5)  <= std_logic_vector(att(15 downto 8));
					trame(6)  <= std_logic_vector(to_unsigned(cmd_snap, 8));
					trame(7)  <= rx_snap(55 downto 48);
					trame(8)  <= rx_snap(47 downto 40);
					trame(9)  <= rx_snap(39 downto 32);
					trame(10) <= rx_snap(31 downto 24);
					trame(11) <= rx_snap(23 downto 16);
					trame(12) <= rx_snap(15 downto 8);
					trame(13) <= rx_snap(7 downto 0);
					trame(14) <= std_logic_vector(nb_jetons);
					trame(15) <= std_logic_vector(adr(7 downto 0));
					trame(16) <= std_logic_vector(adr(15 downto 8));
					trame(17) <= std_logic_vector(somme(7 downto 0));
					trame(18) <= std_logic_vector(somme(15 downto 8));
					trame(19) <= std_logic_vector(to_unsigned(fe_attente mod 256, 8));
					trame(20) <= std_logic_vector(relances);
					trame(21) <= std_logic_vector(tr_seq);
					tr_seq   <= tr_seq + 1;
					tr_octet <= 0; tr_bit <= 0; tr_baud <= 0;
				end if;
			else
				if tr_baud = 433 then
					tr_baud <= 0;
					if tr_bit = 9 then tr_bit <= 0; tr_octet <= tr_octet + 1;
					else tr_bit <= tr_bit + 1; end if;
				else
					tr_baud <= tr_baud + 1;
				end if;
				b := trame(tr_octet);
				case tr_bit is
					when 0      => tr_tx <= '0';               -- bit de depart
					when 9      => tr_tx <= '1';               -- bit d'arret
					when others => tr_tx <= b(tr_bit - 1);     -- poids faible d'abord
				end case;
			end if;
		end if;
	end process;
	dbg_tx <= tr_tx;

    end Behavioral;				
