-- tb_sd_card.vhd -- le lecteur SD de Gosof face a une carte SD SIMULEE.
--
-- Pourquoi ce banc existe. Sur la porteuse, le mode SD est muet et rien ne dit
-- ou la lecture s'arrete. Avant de graver quoi que ce soit, on verifie ici :
--   1. que SD_Card charge les 4096 octets EXACTS du bon secteur, pour une carte
--      qui repond au plus tot (NAC=0 : jeton colle au R1) comme au plus tard ;
--   2. que la trame de trace (dbg_tx, 115200 8N1) sort et dit la verite -- on
--      la decode ici et on la confronte a ce que la machine a reellement fait.
--
-- La carte suit la norme en mode SPI : elle lit MOSI sur le front MONTANT de
-- SCLK et change MISO sur le front DESCENDANT ; NCR octets 0xFF entre la fin
-- d'une commande et sa reponse ; NAC octets 0xFF avant chaque jeton 0xFE.
-- Le contenu des secteurs est une fonction connue du numero de secteur et de la
-- position, et il CONTIENT des 0xFE : un lecteur qui se raccroche a un jeton
-- fortuit dans les donnees est donc pris en defaut.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sd_modele is
	generic (
		NCR     : natural := 1;   -- octets 0xFF entre commande et R1 (norme : 1..8)
		NAC     : natural := 0;   -- octets 0xFF avant le PREMIER jeton
		NAC2    : natural := 0;   -- octets 0xFF avant les jetons suivants
		N_IDLE  : natural := 3;   -- ACMD41 repond 0x01 (occupe) ce nombre de fois
		SOURD_MS : natural := 0   -- avant cet instant la carte n'entend rien : CS tenu
		                          -- HAUT par un tiers (l'ESP qui demarre sur la ligne)
	);
	port (
		cs_n : in  std_logic;
		sclk : in  std_logic;
		mosi : in  std_logic;
		miso : out std_logic := '1'
	);
end sd_modele;

architecture comportement of sd_modele is
	function octet(sec : natural; i : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned((sec * 37 + i * 13 + i / 7) mod 256, 8));
	end function;
begin
	carte : process
		type file_t is array (0 to 63) of std_logic_vector(7 downto 0);
		type cmd_t  is array (0 to 5)  of std_logic_vector(7 downto 0);
		variable q          : file_t;
		variable qh, qt     : natural := 0;
		variable rx         : std_logic_vector(7 downto 0) := x"FF";
		variable cur        : std_logic_vector(7 downto 0) := x"FF";
		variable nbits      : natural := 0;
		variable cmd        : cmd_t;
		variable ncmd       : natural := 0;
		variable app        : boolean := false;
		variable pret       : boolean := false;
		variable occupe     : natural := 0;
		variable flux       : boolean := false;
		variable sec        : natural := 0;
		variable pos        : integer := 0;
		variable idx        : natural;
		variable arg        : unsigned(31 downto 0);
		procedure pousser(b : std_logic_vector(7 downto 0)) is
		begin
			q(qt) := b; qt := (qt + 1) mod 64;
		end procedure;
		procedure r1 is
		begin
			for k in 1 to NCR loop pousser(x"FF"); end loop;
			if pret then pousser(x"00"); else pousser(x"01"); end if;
		end procedure;
	begin
		wait on sclk, cs_n;
		if cs_n /= '0' or now < SOURD_MS * 1 ms then
			miso  <= '1';                 -- haute impedance, tiree au haut
			nbits := 0;
		elsif cs_n'event then
			miso <= cur(7);
		elsif rising_edge(sclk) then
			rx    := rx(6 downto 0) & mosi;
			nbits := nbits + 1;
			if nbits = 8 then
				nbits := 0;
				-- 1. la commande, octet par octet
				if ncmd = 0 then
					if rx(7 downto 6) = "01" then cmd(0) := rx; ncmd := 1; end if;
				else
					cmd(ncmd) := rx; ncmd := ncmd + 1;
					if ncmd = 6 then
						ncmd := 0;
						idx  := to_integer(unsigned(cmd(0)(5 downto 0)));
						arg  := unsigned(cmd(1)) & unsigned(cmd(2)) & unsigned(cmd(3)) & unsigned(cmd(4));
						if app then
							app := false;
							if idx = 41 then
								if occupe < N_IDLE then occupe := occupe + 1; else pret := true; end if;
							end if;
							r1;
						else
							case idx is
								when 0  => pret := false; occupe := 0; flux := false; app := false;
								           qh := qt; r1;
								when 8  => r1; pousser(x"00"); pousser(x"00"); pousser(x"01"); pousser(x"AA");
								when 55 => app := true; r1;
								when 58 => r1; pousser(x"C0"); pousser(x"FF"); pousser(x"80"); pousser(x"00");
								when 18 => r1; flux := true; sec := to_integer(arg); pos := -NAC;
								           report "carte : CMD18 secteur " & integer'image(sec);
								when 12 => flux := false; qh := qt;
								           pousser(x"FF");            -- octet de bourrage
								           r1; pousser(x"00"); pousser(x"00");   -- occupe
								           report "carte : CMD12";
								when others => r1;
							end case;
						end if;
					end if;
				end if;
				-- 2. l'octet suivant sur MISO
				if qh /= qt then
					cur := q(qh); qh := (qh + 1) mod 64;
				elsif flux then
					if pos < 0 then cur := x"FF";
					elsif pos = 0 then cur := x"FE";
					elsif pos <= 512 then cur := octet(sec, pos - 1);
					elsif pos = 513 then cur := x"3C";
					else cur := x"C3";
					end if;
					if pos = 514 then sec := sec + 1; pos := -NAC2; else pos := pos + 1; end if;
				else
					cur := x"FF";
				end if;
			end if;
		elsif falling_edge(sclk) then
			miso <= cur(7 - nbits);
		end if;
	end process;
end comportement;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sd_card is
	generic (
		NCR    : natural := 1;
		NAC    : natural := 0;
		NAC2   : natural := 0;
		N_IDLE : natural := 3;
		SOURD_MS : natural := 0;       -- (GHDL 1.0 ne sait pas surcharger un generique `time`)
		TMAX_MS  : natural := 3000;
		SEL    : natural := 5         -- numero de jeu : secteurs 660 + 8*SEL ..
	);
end tb_sd_card;

architecture essai of tb_sd_card is
	signal clk       : std_logic := '0';
	signal cs_n, sclk, mosi, miso : std_logic;
	signal adr       : std_logic_vector(13 downto 0);
	signal donnee    : std_logic_vector(7 downto 0);
	signal wr        : std_logic;
	signal cpu_rst_l : std_logic;
	signal err_n     : std_logic;
	signal dbg       : std_logic;
	signal fini      : boolean := false;
	signal somme_att : unsigned(15 downto 0) := (others => '0');
	function octet(sec : natural; i : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned((sec * 37 + i * 13 + i / 7) mod 256, 8));
	end function;
	function hex(v : std_logic_vector(7 downto 0)) return string is
		constant h : string(1 to 16) := "0123456789ABCDEF";
	begin
		return h(to_integer(unsigned(v(7 downto 4))) + 1) & h(to_integer(unsigned(v(3 downto 0))) + 1);
	end function;
begin
	clk <= not clk after 10 ns when not fini;

	dut : entity work.SD_Card
		port map (i_Clk => clk, i_Rst_L => '1',      -- comme sur la porteuse
		          o_SPI_Clk => sclk, i_SPI_MISO => miso, o_SPI_MOSI => mosi, o_SPI_CS_n => cs_n,
		          selection => std_logic_vector(to_unsigned(SEL, 8)),
		          address_sd_card => adr, data_sd_card => donnee, wr_rom => wr,
		          cpu_reset_l => cpu_rst_l, SDcard_error => err_n, dbg_tx => dbg);

	carte : entity work.sd_modele
		generic map (NCR => NCR, NAC => NAC, NAC2 => NAC2, N_IDLE => N_IDLE, SOURD_MS => SOURD_MS)
		port map (cs_n => cs_n, sclk => sclk, mosi => mosi, miso => miso);

	-- Chaque ecriture en ROM confrontee au contenu attendu du secteur.
	verif : process(clk)
		variable n, faux : natural := 0;
		variable a       : natural;
		variable att     : std_logic_vector(7 downto 0);
	begin
		if rising_edge(clk) and wr = '1' then
			a   := to_integer(unsigned(adr));
			att := octet(660 + 8 * SEL + a / 512, a mod 512);
			somme_att <= somme_att + unsigned(att);
			n := n + 1;
			if donnee /= att then
				faux := faux + 1;
				if faux <= 5 then
					report "ECRITURE FAUSSE adresse " & integer'image(a) & " : lu " & hex(donnee)
					     & " attendu " & hex(att);
				end if;
			end if;
			if n = 4096 then
				report "4096 ecritures, " & integer'image(faux) & " fausses";
			end if;
		end if;
	end process;

	-- Decodeur UART de la trace : 115200 8N1, trames A5 5A + 20 octets.
	uart : process
		constant BIT_T : time := 8680 ns;
		variable b    : std_logic_vector(7 downto 0);
		type tr_t is array (0 to 21) of std_logic_vector(7 downto 0);
		variable tr   : tr_t;
		variable n    : natural := 0;
	begin
	  loop
		wait until dbg = '0';
		wait for BIT_T / 2;
		for k in 0 to 7 loop
			wait for BIT_T;
			b(k) := dbg;
		end loop;
		wait for BIT_T;
		assert dbg = '1' report "trace : bit d'arret absent" severity error;
		-- resynchronisation sur A5 5A
		if n = 0 and b /= x"A5" then next; end if;
		if n = 1 and b /= x"5A" then n := 0; next; end if;
		tr(n) := b; n := n + 1;
		if n = 22 then
			n := 0;
			report "TRACE etat=" & integer'image(to_integer(unsigned(tr(2))))
			     & " cmd=" & integer'image(to_integer(unsigned(tr(3))))
			     & " essais=" & integer'image(to_integer(unsigned(tr(5)) & unsigned(tr(4))))
			     & " rep(cmd " & integer'image(to_integer(unsigned(tr(6)))) & ")="
			     & hex(tr(7)) & " " & hex(tr(8)) & " " & hex(tr(9)) & " " & hex(tr(10)) & " "
			     & hex(tr(11)) & " " & hex(tr(12)) & " " & hex(tr(13))
			     & " jetons=" & integer'image(to_integer(unsigned(tr(14))))
			     & " adr=" & integer'image(to_integer(unsigned(tr(16)) & unsigned(tr(15))))
			     & " somme=" & integer'image(to_integer(unsigned(tr(18)) & unsigned(tr(17))))
			     & " relances=" & integer'image(to_integer(unsigned(tr(20))))
			     & " seq=" & integer'image(to_integer(unsigned(tr(21))));
		end if;
	  end loop;
	end process;

	-- Depuis les relances, l'etat `error` n'est plus un puits : on attend le
	-- relachement du reset, ou TMAX_MS.
	fin : process
	begin
		wait until cpu_rst_l = '1' for TMAX_MS * 1 ms;
		if cpu_rst_l = '1' then
			report "RESET RELACHE a " & time'image(now) & ", somme attendue "
			     & integer'image(to_integer(somme_att));
		else
			report "RESET JAMAIS RELACHE apres " & time'image(now);
		end if;
		wait for 250 ms;                -- encore deux trames apres la fin
		fini <= true;
		wait;
	end process;
end essai;
