"""Render GHDL VCD output of tb_i2c to PNG waveforms and decode the I2C bus independently.

Usage:  python sim/render_waves.py sim/i2c.vcd docs/waveforms
Needs only matplotlib. The decoder re-derives START/STOP, bytes and ACK/NACK from SCL/SDA
alone, so it is an independent check of what the testbench assertions report.
"""
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = Path(sys.argv[1] if len(sys.argv) > 1 else "sim/i2c.vcd")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "docs/waveforms")
OUT.mkdir(parents=True, exist_ok=True)

WANT = ["scl", "sda", "tx_start", "tx_busy", "tx_done", "tx_ack_err", "rx_start", "rx_busy", "rx_valid",
        "rx_ack_err", "rx_data[7:0]", "slave_reg[7:0]", "slave_addr_ack"]


def parse_vcd(path):
    ids, scope, data, t = {}, [], {}, 0
    with open(path, encoding="ascii", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("$scope"):
                scope.append(line.split()[2])
            elif line.startswith("$upscope"):
                scope.pop()
            elif line.startswith("$var"):
                p = line.split()
                if scope == ["tb_i2c"] and p[4] in WANT:
                    ids[p[3]] = p[4]
                    data[p[4]] = []
            elif line[0] == "#":
                t = int(line[1:])
            elif line[0] == "b":
                val, ident = line[1:].split()
                if ident in ids:
                    data[ids[ident]].append((t, val))
            elif line[0] not in "$" and line[1:] in ids:
                v = line[0].upper()
                v = {"H": "1", "L": "0"}.get(v, v)
                data[ids[line[1:]]].append((t, v))
    return data


data = parse_vcd(VCD)
T_END = max(ch[-1][0] for ch in data.values() if ch)
FS_PER_US = 1e9  # GHDL VCD timescale is 1 fs


def steps(name, t0, t1):
    ch = data[name]
    xs, ys, last = [], [], None
    for t, v in ch:
        if t <= t0:
            last = v
            continue
        if t > t1:
            break
        xs.append(t); ys.append(v)
    return [(t0, last)] + list(zip(xs, ys))


def as_num(v):
    if v is None or any(c in "xXuUzZ" for c in v):
        return 0.5
    return int(v, 2) if len(v) > 1 else int(v)


def value_at(name, t):
    last = None
    for tt, v in data[name]:
        if tt > t:
            break
        last = v
    return last


# ---------------------------------------------------------------- independent I2C decoder
def decode():
    """Walk SCL/SDA edges: START/STOP and bits sampled on SCL rising edges."""
    ev = sorted([(t, "scl", v) for t, v in data["scl"]] + [(t, "sda", v) for t, v in data["sda"]])
    scl = sda = "1"
    frames, cur, bits = [], None, []
    for t, s, v in ev:
        if s == "sda":
            if scl == "1" and sda == "1" and v == "0":
                cur = {"t_start": t, "bytes": [], "acks": []}; bits = []
            elif scl == "1" and sda == "0" and v == "1" and cur is not None:
                cur["t_stop"] = t; frames.append(cur); cur = None
            sda = v
        else:
            if scl == "0" and v == "1" and cur is not None:
                bits.append(sda)
                if len(bits) == 9:
                    cur["bytes"].append(int("".join(bits[:8]), 2)); cur["acks"].append("ACK" if bits[8] == "0" else "NACK")
                    cur.setdefault("byte_t", []).append(t)
                    bits = []
            scl = v
    return frames


frames = decode()
lines = []
for i, fr in enumerate(frames, 1):
    a = fr["bytes"][0]
    desc = [f"addr 0x{a >> 1:02X} {'R' if a & 1 else 'W'} {fr['acks'][0]}"]
    desc += [f"data 0x{b:02X} {k}" for b, k in zip(fr["bytes"][1:], fr["acks"][1:])]
    lines.append(f"#{i}: START @{fr['t_start'] / FS_PER_US:8.2f} us | " + " | ".join(desc)
                 + f" | STOP @{fr['t_stop'] / FS_PER_US:8.2f} us")
period = []
r = [t for t, v in data["scl"] if v == "1"]
for a, b in zip(r, r[1:]):
    if (b - a) / FS_PER_US < 15:
        period.append((b - a) / FS_PER_US)
f_scl = 1000.0 / (sum(period) / len(period)) if period else 0
lines.append(f"SCL period (within bytes): {sum(period) / len(period):.2f} us -> f_SCL = {f_scl:.1f} kHz")
(OUT / "decoded_i2c.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("\n".join(lines))


# ---------------------------------------------------------------- plotting
def plot(rows, t0, t1, fname, title, annotate=None):
    fig, axes = plt.subplots(len(rows), 1, figsize=(13, 0.62 * len(rows) + 1.3), sharex=True)
    for ax, (name, label) in zip(axes, rows):
        st = steps(name, t0, t1)
        xs = [t / FS_PER_US for t, _ in st] + [t1 / FS_PER_US]
        if name.endswith("]"):  # bus: draw value boxes
            for (ta, va), tb in zip(st, xs[1:]):
                xa = ta / FS_PER_US
                ax.plot([xa, tb], [0.85, 0.85], "k", lw=1); ax.plot([xa, tb], [0.15, 0.15], "k", lw=1)
                ax.plot([xa, xa], [0.15, 0.85], "k", lw=1)
                if va and (tb - xa) > (t1 - t0) / FS_PER_US * 0.02:
                    txt = "X" if any(c in "xuXU" for c in va) else f"0x{int(va, 2):02X}"
                    ax.text((xa + tb) / 2, 0.5, txt, ha="center", va="center", fontsize=8)
        else:
            ys = [as_num(v) for _, v in st]
            color = "tab:blue" if name in ("scl", "sda") else "tab:green"
            ax.step(xs, ys + [ys[-1]], where="post", color=color, lw=1.3)
        ax.set_ylim(-0.2, 1.25); ax.set_yticks([])
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        for sp in ("top", "right", "left"):
            ax.spines[sp].set_visible(False)
        ax.grid(axis="x", alpha=0.3)
    if annotate:
        annotate(axes)
    axes[-1].set_xlabel("час, мкс")
    axes[-1].set_xlim(t0 / FS_PER_US, t1 / FS_PER_US)
    fig.suptitle(title, fontsize=11)
    fig.tight_layout()
    fig.savefig(OUT / fname, dpi=150)
    plt.close(fig)
    print("saved", OUT / fname)


def bit_labels(fr, ax_sda):
    """Label S, bits, A/N, P on the SDA axis for one frame."""
    t_rise = [t for t, v in data["scl"] if v == "1" and fr["t_start"] < t < fr["t_stop"]][: 9 * len(fr["bytes"])]
    ax_sda.text(fr["t_start"] / FS_PER_US, 1.12, "S", color="red", ha="center", fontsize=9, weight="bold")
    ax_sda.text(fr["t_stop"] / FS_PER_US, 1.12, "P", color="red", ha="center", fontsize=9, weight="bold")
    for i, t in enumerate(t_rise):
        pos = i % 9
        if pos == 8:
            lab, col = ("A" if value_at("sda", t) == "0" else "N"), "purple"
        else:
            lab, col = value_at("sda", t), "k"
        ax_sda.text(t / FS_PER_US, 1.12, lab, ha="center", fontsize=8, color=col)


overview = [("scl", "SCL"), ("sda", "SDA"), ("tx_start", "tx_start"), ("tx_busy", "tx_busy"),
            ("tx_done", "tx_done"), ("tx_ack_err", "tx_ack_err"), ("rx_start", "rx_start"),
            ("rx_busy", "rx_busy"), ("rx_valid", "rx_valid"), ("rx_data[7:0]", "rx_data"),
            ("slave_reg[7:0]", "slave_reg")]
plot(overview, 0, T_END, "wave_overview.png",
     "Симуляція GHDL: 4 транзакції I2C (запис 0x17, запис 0xA5, читання 0xC3, запис на відсутню адресу 0x51)")

detail = [("scl", "SCL"), ("sda", "SDA"), ("tx_busy", "tx_busy"), ("tx_done", "tx_done"),
          ("tx_ack_err", "tx_ack_err"), ("slave_addr_ack", "slave ACK"), ("slave_reg[7:0]", "slave_reg")]
titles = ["Передавач: START, адреса 0x50+W, ACK, дані 0x17, ACK, STOP",
          "Передавач: запис 0xA5 (чергування бітів)",
          "Приймач: START, адреса 0x50+R, ACK, дані від slave 0xC3, NACK майстра, STOP",
          "Передавач: адреса 0x51 відсутня — NACK, tx_ack_err = 1, STOP"]
for i, fr in enumerate(frames):
    rows = detail if i != 2 else [("scl", "SCL"), ("sda", "SDA"), ("rx_busy", "rx_busy"), ("rx_valid", "rx_valid"),
                                  ("rx_data[7:0]", "rx_data"), ("rx_ack_err", "rx_ack_err"),
                                  ("slave_addr_ack", "slave ACK")]
    t0 = max(0, fr["t_start"] - 8 * FS_PER_US)
    t1 = fr["t_stop"] + 6 * FS_PER_US
    plot(rows, t0, t1, f"wave_frame{i + 1}.png", titles[i] if i < len(titles) else f"frame {i + 1}",
         annotate=lambda axes, fr=fr: bit_labels(fr, axes[1]))
