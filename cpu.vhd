-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2023 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Boris Vicena <xvicen10 AT stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (0) / zapis (1)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_WE   : out std_logic;                      -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

   -- stavove signaly
   READY    : out std_logic;                      -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
   DONE     : out std_logic                       -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is
   -- PC (ukazatel do pamate programu)
   signal pc_reg      : std_logic_vector(12 downto 0);
   signal pc_inc      : std_logic;
   signal pc_dec      : std_logic;
   -- PTR (ukazatel do pamate dat)
   signal ptr_reg     : std_logic_vector(12 downto 0);
   signal ptr_inc     : std_logic;
   signal ptr_dec     : std_logic;
   signal ptr_rst     : std_logic;
   -- CNT (Pocitadlo nested loops)
   signal cnt_reg     : std_logic_vector(7 downto 0);
   signal cnt_inc     : std_logic;
   signal cnt_dec     : std_logic;
   signal cnt_set     : std_logic;
   -- MX1 (Multiplexor 1)
   signal mux1_sel    : std_logic;
   -- MX2 (Multiplexor 2)
   signal mux2_sel    : std_logic_vector(1 downto 0);
   -- FSM (Konecny automat)
   type t_fsm_state is (
      fsm_reset,
      fsm_init,
      fsm_init_check,
      fsm_fetch,
      fsm_decode,
      fsm_ptr_val_inc_r,
      fsm_ptr_val_inc_w,
      fsm_ptr_val_dec_r,
      fsm_ptr_val_dec_w,
      fsm_print_r,
      fsm_print_w,
      fsm_input_r,
      fsm_input_w,
      fsm_while_start,
      fsm_while_stop,

      fsm_while_1,
      fsm_while_2,
      fsm_while_3,
      fsm_while_4,
      fsm_while_s1,
      fsm_while_s2,
      fsm_while_s3,
      fsm_while_s4,

      fsm_break,
      fsm_break_1,
      fsm_break_2,

      fsm_ptr_inc,
      fsm_ptr_dec,
      fsm_ignore,
      fsm_halt
   );
   signal curr_state : t_fsm_state;
   signal next_state : t_fsm_state;
begin
   -- PC process
   pc_counter : process (CLK, RESET, pc_reg, pc_inc, pc_dec) is
   begin
      if RESET = '1' then
         pc_reg <= (others => '0');
      elsif rising_edge(CLK) then
         if pc_inc = '1' then
            pc_reg <= pc_reg + 1;
         elsif pc_dec = '1' then
            pc_reg <= pc_reg - 1;
         end if;
      end if;
   end process;

   -- PTR process
   ptr_counter : process (CLK, RESET, ptr_reg, ptr_inc, ptr_dec) is
   begin
      if RESET = '1' then
         ptr_reg <= (others => '0');
      elsif rising_edge(CLK) then
         if ptr_inc = '1' then
            ptr_reg <= ptr_reg + 1;
         elsif ptr_dec = '1' then
            ptr_reg <= ptr_reg - 1;
         end if;
      end if;
   end process; 

   -- CNT process
   cnt_counter : process (CLK, RESET, cnt_reg, cnt_inc, cnt_dec, cnt_set) is
   begin
      if RESET = '1' then
        cnt_reg <= (others => '0');
      elsif rising_edge(CLK) then
         if cnt_inc = '1' then
            cnt_reg <= cnt_reg + 1;
         elsif cnt_dec = '1' then
            cnt_reg <= cnt_reg - 1;
         elsif cnt_set = '1' then
            cnt_reg <= x"01";
         end if;
      end if;
   end process; 

   -- MX1 process
   mux1 : process (pc_reg, ptr_reg, mux1_sel)
   begin
      case mux1_sel is
         when '0' => DATA_ADDR <= pc_reg;
         when '1' => DATA_ADDR <= ptr_reg;
         when others => null;
      end case;
   end process;

   -- MX2 process
   mux2 : process (IN_DATA, DATA_RDATA, mux2_sel)
   begin
      case mux2_sel is
         when "00" => DATA_WDATA <= IN_DATA;
         when "01" => DATA_WDATA <= DATA_RDATA;
         when "10" => DATA_WDATA <= DATA_RDATA - 1;
         when "11" => DATA_WDATA <= DATA_RDATA + 1;
         when others => null;
      end case;
   end process;

   -- FSM (terajsi stav)
   p_curr_state : process (RESET, CLK)
   begin
      if RESET = '1' then
         curr_state <= fsm_reset;
      elsif rising_edge(CLK) then
         if EN = '1' then
            curr_state <= next_state;
         end if;
      end if;
   end process;

   -- FSM (nasledujuci stav)
   p_next_state : process (curr_state, OUT_BUSY, IN_VLD, DATA_RDATA, EN)
   begin
      pc_inc <= '0';
      pc_dec <= '0';
      ptr_inc <= '0';
      ptr_dec <= '0';
      cnt_inc <= '0';
      cnt_dec <= '0';
      cnt_set <= '0';
      DATA_RDWR <= '0';

      case curr_state is
         -- RESET
         when fsm_reset =>
            READY <= '0';
            DONE <= '0';
            IN_REQ <= '0';
            DATA_EN <= '0';
            OUT_WE <= '0';
            next_state <= fsm_init;
         -- INIT
         when fsm_init =>
            mux1_sel <= '1';
            DATA_EN <= '1';
            next_state <= fsm_init_check;
         -- INIT_CHECK
         when fsm_init_check =>
            ptr_inc <= '1';
            if DATA_RDATA = x"40" then
               next_state <= fsm_fetch;
            else
               next_state <= fsm_init;
            end if;
         -- FETCH
         when fsm_fetch =>
            OUT_WE <= '0';
            READY <= '1';
            mux1_sel <= '0';
            DATA_RDWR <= '0';
            next_state <= fsm_decode;
         -- DECODE
         when fsm_decode =>
            case DATA_RDATA is
              when x"40"  => next_state <= fsm_halt;           -- '@'
              when x"2B"  => next_state <= fsm_ptr_val_inc_r;  -- '+'
              when x"2D"  => next_state <= fsm_ptr_val_dec_r;  -- '-'
              when x"3E"  => next_state <= fsm_ptr_inc;        -- '>'
              when x"3C"  => next_state <= fsm_ptr_dec;        -- '<'
              when x"2E"  => next_state <= fsm_print_r;        -- '.'
              when x"2C"  => next_state <= fsm_input_r;        -- ','
              when x"5B"  => next_state <= fsm_while_start;    -- '['
              when x"5D"  => next_state <= fsm_while_stop;     -- ']'
              when x"7E"  => next_state <= fsm_break;          -- '~'
              when others => next_state <= fsm_ignore;
            end case;
         -- PTR VALUE INC
         when fsm_ptr_val_inc_r =>
            mux1_sel <= '1';
            next_state <= fsm_ptr_val_inc_w;
 
         when fsm_ptr_val_inc_w =>
            mux2_sel <= "11";
            DATA_RDWR <= '1';
            pc_inc <= '1';
            next_state <= fsm_fetch;
         -- PTR VALUE DEC
         when fsm_ptr_val_dec_r =>
            mux1_sel <= '1';
            next_state <= fsm_ptr_val_dec_w;

         when fsm_ptr_val_dec_w =>
            mux2_sel <= "10";
            DATA_RDWR <= '1';
            pc_inc <= '1';
            next_state <= fsm_fetch;
         -- PTR INC
         when fsm_ptr_inc =>
            pc_inc <= '1';
            ptr_inc <= '1';
            next_state <= fsm_fetch;
         -- PTR DEC
         when fsm_ptr_dec =>
            pc_inc <= '1';
            ptr_dec <= '1';
            next_state <= fsm_fetch;
         -- PRINT
         when fsm_print_r =>
            mux1_sel <= '1';
            next_state <= fsm_print_w;

         when fsm_print_w =>
            if OUT_BUSY = '1' then
               next_state <= fsm_print_w;
            else
               OUT_WE <= '1';
               OUT_DATA <= DATA_RDATA;
               pc_inc <= '1';
               next_state <= fsm_fetch;
            end if;
         -- INPUT
         when fsm_input_r =>
            IN_REQ <= '1';
            if IN_VLD = '1' then
               IN_REQ <= '0'; 
               next_state <= fsm_input_w;
            else
               next_state <= fsm_input_r;
            end if;

         when fsm_input_w =>
            mux1_sel <= '1';
            mux2_sel <= "00";
            DATA_RDWR <= '1';
            pc_inc <= '1';
            next_state <= fsm_fetch;
         -- WHILE START
         when fsm_while_start =>
            pc_inc <= '1';
            mux1_sel <= '1';
            next_state <= fsm_while_1;

         when fsm_while_1 =>
           if DATA_RDATA = x"00" then
              cnt_set <= '1';
              mux1_sel <= '0';
              next_state <= fsm_while_2; 
           else
              next_state <= fsm_fetch;
           end if;

         when fsm_while_2 =>
            mux1_sel <= '0';
            next_state <= fsm_while_3;

         when fsm_while_3 =>
            if DATA_RDATA = x"5B" then
               cnt_inc <= '1';
            elsif DATA_RDATA = x"5D" then
               cnt_dec <= '1';
            end if;
            next_state <= fsm_while_4;

         when fsm_while_4 =>
            pc_inc <= '1';
            if cnt_reg = x"00" then
               next_state <= fsm_fetch;
            else
               next_state <= fsm_while_2;
            end if;
         -- WHILE STOP
         when fsm_while_stop =>
            mux1_sel <= '1';
            next_state <= fsm_while_s1;

         when fsm_while_s1 =>
            if DATA_RDATA = x"00" then
               pc_inc <= '1';
               next_state <= fsm_fetch;
            else
               cnt_set <= '1';
               pc_dec <= '1';
               next_state <= fsm_while_s2;
            end if;

         when fsm_while_s2 =>
            mux1_sel <= '0';
            next_state <= fsm_while_s3;

         when fsm_while_s3 =>
            if DATA_RDATA = x"5D" then
               cnt_inc <= '1';
            elsif DATA_RDATA = x"5B" then
               cnt_dec <= '1';
            end if;
            next_state <= fsm_while_s4;

         when fsm_while_s4 =>
            if cnt_reg = x"00" then
               pc_inc <= '1';
               next_state <= fsm_fetch;
            else
               pc_dec <= '1';
               next_state <= fsm_while_s2;
            end if;
         -- BREAK
         when fsm_break =>
            cnt_set <= '1';
            pc_inc <= '1';
            next_state <= fsm_break_1;

         when fsm_break_1 =>
            mux1_sel <= '0';
            next_state <= fsm_break_2;

         when fsm_break_2 =>
            if cnt_reg = x"00" then
               next_state <= fsm_fetch;
            else
               if DATA_RDATA = x"5B" then
                  cnt_inc <= '1';
               elsif DATA_RDATA = x"5D" then
                  cnt_dec <= '1';
               end if;
               pc_inc <= '1';
               next_state <= fsm_break_1;
            end if; 

         -- IGNORE
         when fsm_ignore =>
            pc_inc <= '1';
            next_state <= fsm_fetch;

         -- HALT
         when fsm_halt =>
            DONE <= '1';
            next_state <= fsm_halt;

         when others => null;
      end case;
   end process;
end behavioral;

