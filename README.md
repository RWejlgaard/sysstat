# sysstat

A lightweight memory, CPU, disk and network monitor written in pure x86-64
assembly for Linux systems. Runs entirely on raw syscalls, no libc. Detailed
output is always on, closer in spirit to `neofetch`/`screenfetch` than a
one-line stat summary.

## Features

- **Memory**: usage bar, percentage and used/total in GB, from `/proc/meminfo`
- **CPU**: usage bar and percentage, sampled over a 150ms window from `/proc/stat`
- **Disk**: usage bar for the root filesystem, from `statfs("/")`
- **Network**: download/upload rate in KB/s, summed across every non-loopback
  interface, sampled over the same 150ms window
- **Color-coded Output**: Green (≤50%), Yellow (≤75%), Red (>75%) — only when
  writing to a terminal
- **Selective Output**: Show everything, or any combination of mem/cpu/net
- **Detailed by default**: CPU model/threads/clock/cache, memory buff/cache
  and swap, per-interface network breakdown, disk usage, and a system block
  with OS name, hostname, kernel, architecture, uptime, load average and
  process count

## Installation

### Prerequisites
- Linux system
- NASM assembler
- GNU linker (ld)

### Build from Source
```bash
make
```

### Install System-wide (Optional)
```bash
sudo make install
```

### Clean Build Files
```bash
make clean
```

## Usage

### Basic Usage
Display everything, with full detail:
```bash
./sysstat
```

Example output:
```
MEM  [######--------------]  30%  9.7/32.1G
     buff/cache 4.3G  swap 0.0/3.9G
--------------------------------------------
CPU  [###-----------------]  14%
     AMD Ryzen 7 5800X 8-Core Processor  16 threads  @ 3800MHz  cache 512 KB
--------------------------------------------
NET   down 120.5KB/s up 8.2KB/s
     wlp3s0 up rx 12.4G tx 2.1G
     docker0 down rx 0.0G tx 0.0G
--------------------------------------------
DISK [####----------------]  22%  105.3/512.0G  /
--------------------------------------------
SYS  myhost  Arch Linux  Linux 6.11.5-arch1-1 x86_64
     up 3d 4h 12m  load 0.39 0.50 0.38  procs 234
```

`-m`/`-c`/`-n` scope the output to just one section (DISK and SYS still
print, since neither is tied to a single section). `-v`/`--verbose` is kept
for compatibility but is a no-op — this detail level is always on now.

### Command Line Options

```bash
./sysstat [OPTIONS]
```

| Option | Description |
|--------|-------------|
| `-m, --mem` | Show only memory information |
| `-c, --cpu` | Show only CPU information |
| `-n, --net` | Show only network information |
| `-a, --all` | Show all information (default) |
| `-v, --verbose` | No-op; extra details are shown by default now |
| `-h, --help` | Show help message |

## How It Works

### Memory

Reads `MemTotal` and `MemAvailable` from `/proc/meminfo` (falling back to
`MemFree` on kernels without `MemAvailable`). Used = Total − Available.

### CPU

Reads the aggregate `cpu` line of `/proc/stat`, sleeps 150ms
(`nanosleep`), then reads it again. Usage is the delta of non-idle jiffies
over the delta of total jiffies — already normalized across all cores, so it
reads 0-100% regardless of core count.

### Network

Sums `rx_bytes`/`tx_bytes` across every interface under
`/sys/class/net/` except `lo`, sampled before and after the same 150ms sleep
used for the CPU measurement. Rate = byte delta × 1000 ÷ interval_ms.

### Disk

`statfs("/")` on the root filesystem. Used = `(f_blocks − f_bfree) ×
f_frsize`, total = `f_blocks × f_frsize` — no sampling window needed, it's a
single syscall.

### Detail lines (always on)

- **MEM**: `Buffers:` + `Cached:` for buff/cache, `SwapTotal:`/`SwapFree:`
  for swap used/total — parsed from the same `/proc/meminfo` read used for
  the overview line.
- **CPU**: `model name`, a count of `processor` lines, the first core's
  `cpu MHz`, and `cache size`, all from `/proc/cpuinfo`. The MHz figure is
  one core's current frequency at sample time, not an average across cores.
- **NET**: a second, independent scan of `/sys/class/net/` recording each
  non-loopback interface's name, `operstate`, and all-time `rx_bytes`/
  `tx_bytes` totals (separate from the rate sampled for the overview line).
- **DISK**: root filesystem usage bar, as above.
- **SYS**: `PRETTY_NAME` from `/etc/os-release` (skipped if the file or key
  is missing), hostname/kernel/architecture from `uname()`, uptime from
  `/proc/uptime`, load average and the running/total process count from
  `/proc/loadavg`.

### Assembly Implementation Details

- **System Calls**: Direct Linux syscalls only (`open`, `read`, `write`,
  `close`, `getdents64`, `ioctl`, `nanosleep`, `uname`, `statfs`)
- **No libc**: Statically linked, no dynamic loader at startup
- **Memory Management**: Static buffers for file operations and string
  processing
- **Color Output**: ANSI escape sequences, suppressed when stdout is not a
  terminal
- **Multi-call file reads**: `/proc/cpuinfo` and other procfs files can span
  more than one `read()` before returning their full content, so the file
  reader loops until EOF or its buffer fills rather than trusting a single
  `read()` to return everything.
- **Registers around `syscall`**: the `syscall` instruction itself clobbers
  `rcx` and `r11`, so nothing that needs to survive a syscall (like a
  saved read length used again on the next loop iteration) is kept in
  either of those two.

## Technical Specifications

- **Language**: x86-64 Assembly (Intel syntax)
- **Assembler**: NASM
- **Target**: Linux ELF64
- **Dependencies**: None (uses only Linux syscalls)
- **Runtime**: ~150ms (dominated by the sampling sleep; instant with `-m` alone)

## License

This project is open source. See the source code for implementation details.
