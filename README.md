# csad-lab3-i2c-stafeiev — I2C master (Tx/Rx) на VHDL

| Поле | Значення |
|---|---|
| Студент | Стафеєв Андрій Андрійович, КІ-407 |
| Варіант | 23 → протокол **I2C**, мова **VHDL** (таблиця варіантів `task3.pdf`) |
| Дисципліна | Автоматизоване проєктування комп’ютерних систем, ЛР3 (нумерація за task3.pdf) |

## Структура

| Файл | Призначення |
|---|---|
| `rtl/i2c_master_tx.vhd` | передавач (master write): START, адреса+W, ACK, байт, ACK, STOP |
| `rtl/i2c_master_rx.vhd` | приймач (master read): START, адреса+R, ACK, прийом байта, NACK, STOP |
| `tb/tb_i2c.vhd` | самоперевірний тестбенч: такт 50 МГц, скидання, pull-up `'H'`, модель slave 0x50, монітор START/STOP, assertions |
| `sim/run_ghdl.sh` | аналіз, елаборація і запуск GHDL, запис `sim/i2c.vcd` |
| `sim/render_waves.py` | рендер осцилограм у PNG і незалежне декодування шини з VCD |
| `docs/waveforms/` | осцилограми для звіту та PR |

Параметри: `CLK_FREQ_HZ = 50 MHz`, `I2C_FREQ_HZ = 100 kHz` (standard mode), 7-бітна адреса.

## Запуск симуляції

```bash
# GHDL встановлено локально
sh sim/run_ghdl.sh
# або через Docker (Windows PowerShell: ${PWD} замість $PWD)
docker run --rm -v "$PWD":/src -w /src ghdl/ghdl:6.0.0-mcode-ubuntu-24.04 sh sim/run_ghdl.sh
python sim/render_waves.py sim/i2c.vcd docs/waveforms
```

Очікуваний останній рядок звіту симулятора: `TB RESULT: PASS (all checks passed)`.
