----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 11/20/2019 12:47:32 AM
-- Design Name: 
-- Module Name: ASCON128 - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use work.SomeFunction.all;

-- Entity
----------------------------------------------------------------------------------
entity ASCON128 is
    Port(
        clk             : in std_logic;
        rst             : in std_logic;
        -- Data Input
        key             : in std_logic_vector(31 downto 0); -- SW = 32
        bdi             : in std_logic_vector(31 downto 0); -- W = 32
        -- Key Control
        key_valid       : in std_logic;
        key_ready       : out std_logic;
        key_update      : in std_logic;
        -- BDI Control
        bdi_valid       : in std_logic;
        bdi_ready       : out std_logic;
        bdi_pad_loc     : in std_logic_vector(3 downto 0); -- W/8 = 4
        bdi_valid_bytes : in std_logic_vector(3 downto 0); -- W/8 = 4
        bdi_size        : in std_logic_vector(2 downto 0); -- W/(8+1) = 3
        bdi_eot         : in std_logic;
        bdi_eoi         : in std_logic;
        bdi_type        : in std_logic_vector(3 downto 0);
        hash_in         : in std_logic;
        decrypt_in      : in std_logic;
        -- Data Output
        bdo             : out std_logic_vector(31 downto 0); -- W = 32
        -- BDO Control
        bdo_valid       : out std_logic;
        bdo_ready       : in std_logic;
        bdo_valid_bytes : out std_logic_vector(3 downto 0); -- W/8 = 4
        end_of_block    : out std_logic;
        bdo_type        : out std_logic_vector(3 downto 0);
        -- Tag Verification
        msg_auth        : out std_logic;
        msg_auth_valid  : out std_logic;
        msg_auth_ready  : in std_logic    
    );
end ASCON128;

-- Architecture
----------------------------------------------------------------------------------
architecture Behavioral of ASCON128 is

    -- Constants -----------------------------------------------------------------
    --bdi_type and bdo_type encoding
    constant HDR_AD         : std_logic_vector(3 downto 0) := "0001";
    constant HDR_PT         : std_logic_vector(3 downto 0) := "0100";
    constant HDR_CT         : std_logic_vector(3 downto 0) := "0101";
    constant HDR_TAG        : std_logic_vector(3 downto 0) := "1000";
    constant HDR_KEY        : std_logic_vector(3 downto 0) := "1100";
    constant HDR_NPUB       : std_logic_vector(3 downto 0) := "1101";
    constant HDR_HASH_MSG   : std_logic_vector(3 downto 0) := "0111";
    constant HDR_HASH_VALUE : std_logic_vector(3 downto 0) := "1001";
    
    constant IV_hash        : std_logic_vector(63 downto 0)  := x"00400c0000000100"; -- 0*||r||a||0*||h
    
    -- Types ---------------------------------------------------------------------
    type fsm is (idle, Initialization, load_data, process_data,
                 output_tag, process_hash);

    -- Signals -------------------------------------------------------------------
    -- Permutation signals
    signal perm_start       : std_logic;
    signal a_rounds         : std_logic;
    signal Sr               : std_logic_vector(63 downto 0);
    signal Sc0, Sc1         : std_logic_vector(127 downto 0);
    signal perm_Sr          : std_logic_vector(63 downto 0); 
    signal perm_Sc0         : std_logic_vector(127 downto 0);
    signal perm_Sc1         : std_logic_vector(127 downto 0);
    signal perm_done        : std_logic;

    -- Data signals
    signal bdo_t            : std_logic_vector(31 downto 0);  

    -- Control Signals
    signal last_M_reg       : std_logic;
    signal last_M_rst       : std_logic;
    signal last_M_set       : std_logic;
    
    signal no_M_reg         : std_logic;
    signal no_M_rst         : std_logic;
    signal no_M_set         : std_logic;
    
    signal partial_M_reg    : std_logic;
    signal partial_M_rst    : std_logic;
    signal partial_M_set    : std_logic;
  
    -- Counter signals
    signal ctr_words_rst    : std_logic;
    signal ctr_words_inc    : std_logic;
    signal ctr_words        : std_logic_vector(1 downto 0);
    signal ctr_hash_rst     : std_logic;
    signal ctr_hash_inc     : std_logic;
    signal ctr_hash         : std_logic_vector(2 downto 0);
    
    -- State machine signals
    signal state            : fsm;
    signal next_state       : fsm;

------------------------------------------------------------------------------
begin
    
    P: entity work.Permutation -- The SPN permutation (pc . ps. pl)
        Port map(
            clk         => clk,
            rst         => rst,
            start       => perm_start,
            a_rounds    => a_rounds,
            Sr          => Sr,
            Sc0         => Sc0,
            Sc1         => Sc1,
            pSr         => perm_Sr,
            pSc0        => perm_Sc0,
            pSc1        => perm_Sc1,
            done        => perm_done
        );
   
    bdo <= bdo_t; 
    --bdo_type <= bdi_type xor "0001" when (bdi_type = HDR_MSG or bdi_type = HDR_CT) else HDR_TAG; -- HDR_CT = HDR_MSG xor "0001"
    bdo_valid_bytes <= bdi_valid_bytes when (bdi_type = HDR_PT or bdi_type = HDR_CT) else "1111";   

    ---------------------------------------------------------------------------------
    Sync: process(clk)
    begin
        if rising_edge(clk) then
            if (rst = '1') then
                state      <= idle;
            else
                state      <= next_state;
            end if;
            
            if (ctr_words_rst = '1') then
                ctr_words   <= "00";
            elsif (ctr_words_inc = '1') then
                ctr_words   <= ctr_words + 1;
            end if;
            
            if (ctr_hash_rst = '1') then
                ctr_hash   <= "000";
            elsif (ctr_hash_inc = '1') then
                ctr_hash   <= ctr_hash + 1;
            end if;

            if (last_M_rst = '1') then
                last_M_reg  <= '0';
            elsif (last_M_set = '1') then
                last_M_reg  <= '1';
            end if;
            
            if (no_M_rst = '1') then
                no_M_reg   <= '0';
            elsif (no_M_set = '1') then
                no_M_reg   <= '1';
            end if;
            
            if (partial_M_rst = '1') then
                partial_M_reg   <= '0';
            elsif (partial_M_set = '1') then
                partial_M_reg   <= '1';
            end if;

        end if;
    end process;
    
    ----------------------------------------------------------------------------------
    Controller: process(bdi, bdi_valid, bdi_eot, bdi_eoi, bdi_type,
                        bdo_ready, state, ctr_words, perm_done,
                        perm_Sr, perm_Sc0, perm_Sc1)
    begin
        -- Default values
        next_state          <= idle;
        perm_start          <= '0';
        a_rounds            <= '1'; -- pa = 12
        bdi_ready           <= '0';
        ctr_words_rst       <= '0';
        ctr_words_inc       <= '0';
        ctr_hash_rst        <= '0';
        ctr_hash_inc        <= '0';
        last_M_rst          <= '0';
        last_M_set          <= '0';
        no_M_rst            <= '0';
        no_M_set            <= '0';
        partial_M_rst       <= '0';
        partial_M_set       <= '0';
        bdo_valid           <= '0';           
        
        case state is
            when idle =>
                ctr_words_rst   <= '1';
                ctr_hash_rst    <= '1'; 
                last_M_rst      <= '1';
                no_M_rst        <= '1';
                partial_M_rst   <= '1'; 
                if (bdi_valid = '1' and hash_in = '1') then -- Initialize the state for hashing
                    perm_start      <= '1';
                    next_state      <= Initialization; 
                else
                    next_state      <= idle;
                end if;
 
            when Initialization =>
                if (perm_done = '1') then 
                    if (bdi_type = HDR_HASH_MSG) then -- Absorb message
                        next_state  <=  load_data;                
                    else
                        next_state  <= Initialization;
                    end if;
                else
                    next_state      <= Initialization;
                end if;                     

            when load_data =>
                bdi_ready       <= '1'; 
                ctr_words_inc   <= '1';
                if (bdi_eot = '1') then -- Last block of data
                    last_M_set  <= '1';
                else
                    last_M_rst  <= '1';
                end if;
                if (bdi_size = "000") then -- Empty message in hash
                    no_M_set    <= '1';
                else
                    no_M_rst    <= '1';
                end if;
                if (((ctr_words /= 1) or (bdi_size /= "100"))) then -- Partial last block 
                    partial_M_set   <= '1';
                else
                    partial_M_rst   <= '1';
                end if;                
                if (bdi_eot = '1' or ctr_words = 1) then -- A block of data is received
                    ctr_words_rst   <= '1';
                    perm_start      <= '1';
                    next_state      <= process_data; 
                else
                    next_state      <= load_data;
                end if;
                
            when process_data =>
                if (perm_done = '1') then
                    if (last_M_reg = '1') then -- Last block of message in hash
                        if (no_M_reg = '0' and partial_M_reg = '0') then -- Full block follows by a 10* block
                            partial_M_set  <= '1';
                            perm_start     <= '1';
                            next_state     <= process_data;
                        else                                             -- Partial or 10* block
                            next_state     <= output_tag;
                        end if;
                    else                       -- Still loading data
                        next_state  <= load_data;
                    end if;
                else
                    next_state      <= process_data;
                end if;
             
            when output_tag =>
                bdo_valid       <= '1';
                ctr_words_inc   <= '1';
                ctr_hash_inc    <= '1';
                if (ctr_words = 1) then
                    ctr_words_rst   <= '1';                   
                    if (ctr_hash = 7) then
                        ctr_hash_rst    <= '1';
                        next_state      <= idle;
                    else
                        perm_start  <= '1';
                        next_state  <= process_hash;
                    end if;
                else
                    next_state      <= output_tag;
                end if; 
  
            when process_hash =>
                if (perm_done = '1') then
                    next_state <= output_tag;
                else
                    next_state <= process_hash;
                end if;
                
            when others => null;
        end case;
    end process;
    
    -- Datapath
    -------------------------------------------------------------------------------- 
    Sr_fsm: process(state, perm_done, perm_Sr, ctr_words, bdi_eot, bdi)
    begin
        Sr <= perm_Sr;  -- Default value      
        case state is   -- Case statement
            when idle =>
                Sr <= IV_hash;         
            when load_data =>
                if (ctr_words = 0 and bdi_eot = '1') then -- Partial last block
                    Sr <= (perm_Sr(63 downto 32) xor pad(bdi, bdi_size)) & perm_Sr(31 downto 0); 
                    if (bdi_size = 4) then
                        Sr(31) <= perm_Sr(31) xor '1'; -------
                    else
                        Sr(31) <= perm_Sr(31);
                    end if;
                elsif (ctr_words = 0 and bdi_eot = '0') then -- Upper 32 bits
                    Sr <= (perm_Sr(63 downto 32) xor bdi) & perm_Sr(31 downto 0); 
                else                                         -- Lower 32 bits
                    Sr <= perm_Sr(63 downto 32) & (perm_Sr(31 downto 0) xor pad(bdi, bdi_size));
                end if;
            when process_data =>
                if (perm_done = '1' and last_M_reg = '1' and partial_M_reg = '0' and no_M_reg = '0') then
                    Sr <= perm_Sr xor x"8000000000000000"; -- In hash, last full block of message follows by a 10* block and then permutation
                end if;
            when others => null;
        end case;
    end process Sr_fsm;
    
    --------------------------------------------------------------------------------              
    Sc0_fsm: process(state, perm_Sc0)
    begin
        Sc0 <= perm_Sc0; -- Default value    
        case state is    -- Case statement
            when idle =>
                Sc0 <= (others => '0'); 
            when others => null;
        end case;
    end process Sc0_fsm;

    --------------------------------------------------------------------------------
    Sc1_fsm: process(state, perm_Sc1)
    begin        
        Sc1 <= perm_Sc1; -- Default value     
        case state is    -- Case statement
            when idle =>
                Sc1 <= (others => '0'); 
            when others => null;
        end case;
    end process Sc1_fsm;

    --------------------------------------------------------------------------------
    bdo_temp_fsm: process(state, Perm_Sr, ctr_words)
    begin
        bdo_t <= (others => '0'); -- Default value        
        case state is             -- Case statement
            when output_tag =>
                if (ctr_words = 0) then -- Upper 32 bits
                    bdo_t <= Perm_Sr(63 downto 32); 
                else                    -- Lower 32 bits
                    bdo_t <= Perm_Sr(31 downto 0);
                end if; 
            when others => null;
        end case;
    end process bdo_temp_fsm;
    
    --------------------------------------------------------------------------------
    end_of_block_fsm: process(state, ctr_hash)
    begin
        end_of_block <= '0'; -- Default value   
        case state is        -- Case statement
            when output_tag =>
                if (ctr_hash = 7) then -- Last word of hash
                    end_of_block <= '1'; 
                else
                    end_of_block <= '0';
                end if;                      
            when others => null;
        end case;
    end process;

end Behavioral;
