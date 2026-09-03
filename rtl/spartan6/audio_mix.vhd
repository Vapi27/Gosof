-- audio_mix.vhd — reunir les deux sources de son de Gosof avant le DAC.
--
-- POURQUOI CETTE PIECE EXISTE. Sur la carte de bontango les deux sources sont
-- melangees en ANALOGIQUE : le DAC du FPGA d'un cote, l'entree du module MP3 de
-- l'autre, chacune avec son potentiometre (« Sound Vol. » et « Speech Vol. »).
-- En mettant le SC-01A DANS le FPGA, les deux deviennent numeriques et il faut
-- les additionner soi-meme.
--
-- ⚠️ LA SATURATION N'EST PAS OPTIONNELLE. Sans elle, un son fort plus une parole
--    forte reboucle en negatif : c'est un claquement a pleine puissance dans le
--    haut-parleur d'une machine.
--
-- ⚠️ Gosof seul n'occupe plus que la MOITIE de l'echelle : -6 dB par rapport a
--    aujourd'hui, a rattraper au potentiometre. C'est le prix de la reserve qui
--    permet a la parole de s'ajouter sans ecreter en permanence.
--
-- Au repos la branche parole vaut exactement zero (les phonemes PA0/PA1/STOP
-- vident l'etat des filtres), donc aucun muet exterieur, aucun decalage du point
-- de repos.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_mix is
	generic (
		-- Gain de la parole en Q8 : 256 = x1,0. C'est le « Speech Vol. » numerique.
		-- Il doit pouvoir MONTER : les echantillons de reference du coeur cretent
		-- ~11 dB sous une source qui remplirait ses 8 bits.
		SPCH_GAIN : integer := 512
	);
	port (
		clk        : in  std_logic;
		-- la voie « son » de Gosof, telle qu'elle sort du bus du processeur
		gosof_u8   : in  std_logic_vector(7 downto 0);
		-- la voie « parole », signee, telle qu'elle sort du SC-01A
		speech_s18 : in  signed(17 downto 0);
		-- vers dac.vhd, qui est NON SIGNE : binaire decale
		dac_u16    : out std_logic_vector(15 downto 0)
	);
end audio_mix;

architecture rtl of audio_mix is
	constant CRETE_P : integer :=  131071;
	constant CRETE_N : integer := -131072;

	function borner(v : signed) return signed is
	begin
		if v > to_signed(CRETE_P, v'length) then
			return to_signed(CRETE_P, 18);
		elsif v < to_signed(CRETE_N, v'length) then
			return to_signed(CRETE_N, 18);
		else
			return resize(v, 18);
		end if;
	end function;

	signal gos_s18 : signed(17 downto 0);
	signal produit : signed(28 downto 0);
	signal parole  : signed(17 downto 0);
	signal somme   : signed(18 downto 0);
	signal melange : signed(17 downto 0);
begin
	-- 8 bits non signes, milieu a 0x80, vers +-65536 : la moitie de l'echelle,
	-- soit 6 dB de reserve pour la parole.
	gos_s18 <= shift_left(resize(signed('0' & gosof_u8), 18), 9)
	           - to_signed(65536, 18);

	-- Gain Q8. Le produit est calcule en PLEINE largeur puis borne : borner
	-- apres l'addition seulement laisserait un gain eleve reboucler avant.
	produit <= speech_s18 * to_signed(SPCH_GAIN, 11);
	parole  <= borner(produit(28 downto 8));

	somme   <= resize(gos_s18, 19) + resize(parole, 19);
	melange <= borner(somme);

	process (clk)
	begin
		if rising_edge(clk) then
			-- signe -> binaire decale : inverser le bit de signe.
			dac_u16 <= (not melange(17)) & std_logic_vector(melange(16 downto 2));
		end if;
	end process;
end rtl;
