--------------------------------------------------------------------------------
-- i2c_master_rx.vhd
-- I2C master RECEIVER (read transaction), VHDL-2008, synthesizable.
--   ADCS lab "Serial protocols on FPGA", variant 23: I2C + VHDL.
--   Author: Stafeiev Andrii (KI-407).
--
-- One transaction:  START | ADDR[6:0] + R(1) | ACK(slave) | DATA[7:0] from slave | NACK(master) | STOP
--
-- The master generates SCL and controls the transfer; during the data byte it
-- releases SDA and samples the bits the slave puts on the bus. After the last
-- (here: only) byte the master answers NACK, then generates STOP.
-- SCL/SDA are open drain ('0' or 'Z'), the pull-up is external.
-- Quarter-phase timing is identical to i2c_master_tx (see that file):
--   phase 0 SCL low (SDA may change) | 1 release SCL | 2 SCL high: sample | 3 SCL low
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master_rx is
  generic (
    CLK_FREQ_HZ : positive := 50_000_000;  -- system clock frequency
    I2C_FREQ_HZ : positive := 100_000      -- SCL frequency
  );
  port (
    clk       : in    std_logic;                     -- system clock
    rst       : in    std_logic;                     -- synchronous reset, active high
    start     : in    std_logic;                     -- 1-clk pulse: begin a read transaction
    addr      : in    std_logic_vector(6 downto 0);  -- 7-bit slave address
    data_out  : out   std_logic_vector(7 downto 0);  -- received byte (valid with data_valid)
    data_valid: out   std_logic;                     -- 1-clk pulse: data_out holds a new byte
    busy      : out   std_logic;                     -- '1' while a transaction is running
    done      : out   std_logic;                     -- 1-clk pulse at the end of STOP
    ack_error : out   std_logic;                     -- '1' if the address was not acknowledged
    scl       : inout std_logic;                     -- I2C clock line (open drain)
    sda       : inout std_logic                      -- I2C data line  (open drain)
  );
end entity;

architecture rtl of i2c_master_rx is
  constant QUARTER : positive := CLK_FREQ_HZ / (4 * I2C_FREQ_HZ);

  -- Receiver FSM states
  type state_t is (S_IDLE, S_START, S_SEND_ADDR, S_ADDR_ACK, S_READ_BIT, S_MASTER_NACK, S_STOP);
  signal state     : state_t := S_IDLE;

  signal div_cnt   : natural range 0 to QUARTER - 1 := 0;  -- clock divider counter
  signal tick      : std_logic := '0';                    -- quarter-period strobe
  signal phase     : natural range 0 to 3 := 0;           -- quarter phase inside one bit
  signal bit_cnt   : natural range 0 to 7 := 7;           -- bit index
  signal shreg     : std_logic_vector(7 downto 0) := (others => '0');  -- address out / data in
  signal nack_seen : std_logic := '0';                    -- address NACK flag

  signal scl_oe    : std_logic := '0';  -- '1' = pull SCL low
  signal sda_oe    : std_logic := '0';  -- '1' = pull SDA low
begin
  scl <= '0' when scl_oe = '1' else 'Z';
  sda <= '0' when sda_oe = '1' else 'Z';

  busy <= '0' when state = S_IDLE else '1';

  -- Clock divider (4 ticks per SCL period)
  divider : process (clk)
  begin
    if rising_edge(clk) then
      tick <= '0';
      if rst = '1' or state = S_IDLE then
        div_cnt <= 0;
      elsif div_cnt = QUARTER - 1 then
        div_cnt <= 0;
        tick    <= '1';
      else
        div_cnt <= div_cnt + 1;
      end if;
    end if;
  end process;

  -- Receiver FSM
  fsm : process (clk)
    variable stretched : boolean;
  begin
    if rising_edge(clk) then
      done       <= '0';
      data_valid <= '0';
      if rst = '1' then
        state     <= S_IDLE;
        scl_oe    <= '0';
        sda_oe    <= '0';
        phase     <= 0;
        ack_error <= '0';
        nack_seen <= '0';
        data_out  <= (others => '0');
      else
        stretched := (scl_oe = '0') and (to_x01(scl) = '0') and (state /= S_IDLE);
        if state = S_IDLE then
          scl_oe <= '0';
          sda_oe <= '0';
          if start = '1' then
            shreg     <= addr & '1';             -- R/W = 1 : read
            bit_cnt   <= 7;
            phase     <= 0;
            nack_seen <= '0';
            ack_error <= '0';
            state     <= S_START;
          end if;
        elsif tick = '1' and not stretched then
          phase <= (phase + 1) mod 4;
          case state is
            when S_START =>                      -- SDA falls while SCL high
              case phase is
                when 0 => sda_oe <= '0'; scl_oe <= '0';
                when 1 => sda_oe <= '1';
                when 2 => null;
                when 3 => scl_oe <= '1'; state <= S_SEND_ADDR;
              end case;

            when S_SEND_ADDR =>                  -- address + R bit, MSB first
              case phase is
                when 0 => sda_oe <= not shreg(7);
                when 1 => scl_oe <= '0';
                when 2 => null;
                when 3 =>
                  scl_oe <= '1';
                  shreg  <= shreg(6 downto 0) & '0';
                  if bit_cnt = 0 then
                    state <= S_ADDR_ACK;
                  else
                    bit_cnt <= bit_cnt - 1;
                  end if;
              end case;

            when S_ADDR_ACK =>                   -- slave ACK for the address
              case phase is
                when 0 => sda_oe <= '0';
                when 1 => scl_oe <= '0';
                when 2 =>
                  if to_x01(sda) /= '0' then
                    nack_seen <= '1';
                  end if;
                when 3 =>
                  scl_oe  <= '1';
                  bit_cnt <= 7;
                  if nack_seen = '1' then
                    state <= S_STOP;
                  else
                    state <= S_READ_BIT;
                  end if;
              end case;

            when S_READ_BIT =>                   -- SDA released, sample on SCL high
              case phase is
                when 0 => sda_oe <= '0';
                when 1 => scl_oe <= '0';
                when 2 => shreg <= shreg(6 downto 0) & to_x01(sda);
                when 3 =>
                  scl_oe <= '1';
                  if bit_cnt = 0 then
                    state <= S_MASTER_NACK;
                  else
                    bit_cnt <= bit_cnt - 1;
                  end if;
              end case;

            when S_MASTER_NACK =>                -- last byte: master leaves SDA high (NACK)
              case phase is
                when 0 =>
                  sda_oe     <= '0';
                  data_out   <= shreg;
                  data_valid <= '1';
                when 1 => scl_oe <= '0';
                when 2 => null;
                when 3 => scl_oe <= '1'; state <= S_STOP;
              end case;

            when S_STOP =>                       -- SDA rises while SCL high
              case phase is
                when 0 => sda_oe <= '1';
                when 1 => scl_oe <= '0';
                when 2 => sda_oe <= '0';
                when 3 =>
                  done      <= '1';
                  ack_error <= nack_seen;
                  state     <= S_IDLE;
              end case;

            when S_IDLE => null;
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
