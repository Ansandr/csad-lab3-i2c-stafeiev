--------------------------------------------------------------------------------
-- tb_i2c.vhd
-- Self-checking testbench for i2c_master_tx and i2c_master_rx (VHDL-2008).
--   * 50 MHz clock, synchronous reset
--   * open-drain bus: weak pull-ups 'H' on SCL/SDA, every driver uses '0'/'Z'
--   * behavioural I2C slave at address 0x50 (register write, constant read)
--   * protocol monitor: counts START/STOP conditions
--   * assertions: written bytes, read byte, NACK on a wrong address
-- Run: see sim/run_ghdl.sh  ->  "TB RESULT: PASS" and i2c.vcd
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_i2c is
end entity;

architecture sim of tb_i2c is
  constant CLK_PERIOD  : time := 20 ns;                 -- 50 MHz
  constant SLAVE_ADDR  : std_logic_vector(6 downto 0) := "1010000";  -- 0x50
  constant WRONG_ADDR  : std_logic_vector(6 downto 0) := "1010001";  -- 0x51 (no device)
  constant SLAVE_RDATA : std_logic_vector(7 downto 0) := x"C3";      -- byte returned on read

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- I2C bus with pull-up resistors (weak '1')
  signal scl : std_logic := 'H';
  signal sda : std_logic := 'H';

  -- transmitter interface
  signal tx_start, tx_busy, tx_done, tx_ack_err : std_logic := '0';
  signal tx_addr : std_logic_vector(6 downto 0) := (others => '0');
  signal tx_data : std_logic_vector(7 downto 0) := (others => '0');

  -- receiver interface
  signal rx_start, rx_busy, rx_done, rx_ack_err, rx_valid : std_logic := '0';
  signal rx_addr : std_logic_vector(6 downto 0) := (others => '0');
  signal rx_data : std_logic_vector(7 downto 0) := (others => '0');

  -- slave model observation
  signal slave_reg      : std_logic_vector(7 downto 0) := (others => '0');
  signal slave_addr_ack : std_logic := '0';
  signal starts, stops  : natural := 0;
begin
  -- pull-ups: resolved with the drivers of the DUTs and of the slave
  scl <= 'H';
  sda <= 'H';

  clk <= not clk after CLK_PERIOD / 2;

  ------------------------------------------------------------------------------
  -- Devices under test (both masters share the bus, used one at a time)
  ------------------------------------------------------------------------------
  u_tx : entity work.i2c_master_tx
    generic map (CLK_FREQ_HZ => 50_000_000, I2C_FREQ_HZ => 100_000)
    port map (clk => clk, rst => rst, start => tx_start, addr => tx_addr, data_in => tx_data,
              busy => tx_busy, done => tx_done, ack_error => tx_ack_err, scl => scl, sda => sda);

  u_rx : entity work.i2c_master_rx
    generic map (CLK_FREQ_HZ => 50_000_000, I2C_FREQ_HZ => 100_000)
    port map (clk => clk, rst => rst, start => rx_start, addr => rx_addr, data_out => rx_data,
              data_valid => rx_valid, busy => rx_busy, done => rx_done, ack_error => rx_ack_err,
              scl => scl, sda => sda);

  ------------------------------------------------------------------------------
  -- Behavioural I2C slave (external device). Samples SDA on SCL rising edges,
  -- changes SDA only after SCL falling edges, drives only '0' or 'Z'.
  ------------------------------------------------------------------------------
  slave : process
    variable sh : std_logic_vector(7 downto 0);
  begin
    sda <= 'Z';
    loop
      -- wait for START: SDA falls while SCL is high
      wait until falling_edge(sda) and to_x01(scl) = '1';
      slave_addr_ack <= '0';
      -- address byte
      for i in 7 downto 0 loop
        wait until rising_edge(scl);
        sh(i) := to_x01(sda);
      end loop;
      wait until falling_edge(scl);
      if sh(7 downto 1) = SLAVE_ADDR then
        slave_addr_ack <= '1';
        sda <= '0';                                  -- ACK (9th clock)
        wait until falling_edge(scl);
        if sh(0) = '0' then
          ---------------- master writes one byte ----------------
          sda <= 'Z';
          for i in 7 downto 0 loop
            wait until rising_edge(scl);
            sh(i) := to_x01(sda);
          end loop;
          wait until falling_edge(scl);
          slave_reg <= sh;
          sda <= '0';                                -- ACK for data
          wait until falling_edge(scl);
          sda <= 'Z';
        else
          ---------------- master reads one byte -----------------
          for i in 7 downto 0 loop
            if SLAVE_RDATA(i) = '0' then sda <= '0'; else sda <= 'Z'; end if;
            wait until falling_edge(scl);
          end loop;
          sda <= 'Z';                                -- release for master ACK/NACK
          wait until rising_edge(scl);
          assert to_x01(sda) = '1'
            report "slave: master should NACK the last byte" severity error;
        end if;
      end if;                                        -- wrong address: no ACK, SDA stays 'Z'
      -- wait for STOP: SDA rises while SCL is high
      wait until rising_edge(sda) and to_x01(scl) = '1';
    end loop;
  end process;

  ------------------------------------------------------------------------------
  -- Protocol monitor: SDA may change while SCL is high only for START/STOP.
  ------------------------------------------------------------------------------
  monitor : process (sda)
  begin
    if to_x01(scl) = '1' and rst = '0' then
      if falling_edge(sda) then
        starts <= starts + 1;
      elsif rising_edge(sda) then
        stops <= stops + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Stimulus and checks
  ------------------------------------------------------------------------------
  stim : process
    variable errors : natural := 0;

    procedure i2c_write(a : std_logic_vector(6 downto 0); d : std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk);
      tx_addr <= a; tx_data <= d; tx_start <= '1';
      wait until rising_edge(clk);
      tx_start <= '0';
      wait until rising_edge(clk) and tx_done = '1';
      wait for 5 us;                                 -- bus free time between transactions
    end procedure;

    procedure check(cond : boolean; msg : string) is
    begin
      if cond then
        report "PASS: " & msg;
      else
        report "FAIL: " & msg severity error;
        errors := errors + 1;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait for 200 ns;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 us;

    -- Test 1: write 0x17 (variant 23) to slave 0x50
    i2c_write(SLAVE_ADDR, x"17");
    check(tx_ack_err = '0', "TX write 0x17 to 0x50 acknowledged");
    check(slave_reg = x"17", "slave received 0x" & to_hstring(slave_reg) & " (expected 0x17)");

    -- Test 2: write 0xA5 (alternating bits)
    i2c_write(SLAVE_ADDR, x"A5");
    check(tx_ack_err = '0', "TX write 0xA5 to 0x50 acknowledged");
    check(slave_reg = x"A5", "slave received 0x" & to_hstring(slave_reg) & " (expected 0xA5)");

    -- Test 3: read one byte from slave 0x50 with the receiver
    wait until rising_edge(clk);
    rx_addr <= SLAVE_ADDR; rx_start <= '1';
    wait until rising_edge(clk);
    rx_start <= '0';
    wait until rising_edge(clk) and rx_valid = '1';
    check(rx_data = SLAVE_RDATA, "RX received 0x" & to_hstring(rx_data) & " (expected 0xC3)");
    wait until rising_edge(clk) and rx_done = '1';
    check(rx_ack_err = '0', "RX address 0x50 acknowledged");
    wait for 5 us;

    -- Test 4: write to a missing device -> NACK must be reported, register unchanged
    i2c_write(WRONG_ADDR, x"FF");
    check(tx_ack_err = '1', "TX reports NACK for missing address 0x51");
    check(slave_reg = x"A5", "slave register unchanged after NACK");

    -- Protocol monitor
    check(starts = 4 and stops = 4, "monitor: " & integer'image(starts) & " START and "
                                     & integer'image(stops) & " STOP conditions (expected 4/4)");
    check(to_x01(scl) = '1' and to_x01(sda) = '1', "bus idle (SCL=SDA=1) after STOP");

    if errors = 0 then
      report "TB RESULT: PASS (all checks passed)";
    else
      report "TB RESULT: FAIL (" & integer'image(errors) & " errors)" severity failure;
    end if;
    finish;
  end process;
end architecture;
