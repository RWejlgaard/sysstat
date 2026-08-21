; sysstat.asm - Memory, CPU and network monitor in x86-64 assembly
; Linux only, direct syscalls, no libc.

%define SYS_read       0
%define SYS_write      1
%define SYS_open       2
%define SYS_close      3
%define SYS_ioctl      16
%define SYS_exit       60
%define SYS_uname      63
%define SYS_nanosleep  35
%define SYS_statfs     137
%define SYS_getdents64 217

%define STDOUT 1
%define STDERR 2
%define TCGETS 0x5401
%define O_RDONLY_DIR 0x10000        ; O_RDONLY | O_DIRECTORY

%define BAR_WIDTH       20
%define DENTS_SZ        1024
%define INTERVAL_MS     150
%define CPUINFO_MAX     65535
%define MAX_NET         16
%define IFACE_NAME_MAX  16
%define STATE_MAX       16

section .rodata
    ; ANSI color codes
    red_color        db 27, '[31m', 0
    green_color      db 27, '[32m', 0
    yellow_color     db 27, '[33m', 0
    reset_color      db 27, '[0m', 0

    usage_msg        db 'Usage: sysstat [OPTIONS]', 10
                     db 'Show memory, CPU, disk and network statistics', 10, 10
                     db 'Options:', 10
                     db '  -m, --mem      Show only memory information', 10
                     db '  -c, --cpu      Show only CPU information', 10
                     db '  -n, --net      Show only network information', 10
                     db '  -a, --all      Show all information (default)', 10
                     db '  -v, --verbose  No-op; extra details are shown by default now', 10
                     db '  -h, --help     Show this help message', 10, 10
                     db 'Without any options, shows all information with full detail', 10
    usage_len        equ $ - usage_msg

    unknown_opt_msg  db 'Unknown option: ', 0
    use_help_msg     db 10, 'Use -h or --help for usage information', 10, 0

    ; Command line options
    help_short       db '-h', 0
    help_long        db '--help', 0
    mem_short        db '-m', 0
    mem_long         db '--mem', 0
    cpu_short        db '-c', 0
    cpu_long         db '--cpu', 0
    net_short        db '-n', 0
    net_long         db '--net', 0
    all_short        db '-a', 0
    all_long         db '--all', 0
    verbose_short    db '-v', 0
    verbose_long     db '--verbose', 0

    ; Data sources
    proc_stat_path    db '/proc/stat', 0
    proc_meminfo_path db '/proc/meminfo', 0
    proc_cpuinfo_path db '/proc/cpuinfo', 0
    proc_uptime_path  db '/proc/uptime', 0
    proc_loadavg_path db '/proc/loadavg', 0
    os_release_path   db '/etc/os-release', 0
    root_path         db '/', 0
    net_class_dir     db '/sys/class/net/', 0
    stats_subdir      db 'statistics/', 0
    rx_bytes_file     db 'rx_bytes', 0
    tx_bytes_file     db 'tx_bytes', 0
    operstate_file    db 'operstate', 0
    lo_name           db 'lo', 0

    key_memtotal  db 'MemTotal:', 0
    key_memavail  db 'MemAvailable:', 0
    key_memfree   db 'MemFree:', 0
    key_buffers   db 'Buffers:', 0
    key_cached    db 'Cached:', 0
    key_swaptotal db 'SwapTotal:', 0
    key_swapfree  db 'SwapFree:', 0

    key_modelname  db 'model name', 0
    key_cpumhz     db 'cpu MHz', 0
    key_processor  db 'processor', 0
    key_cachesize  db 'cache size', 0

    key_pretty_name db 'PRETTY_NAME=', 0

    ; Output fragments
    mem_label       db 'MEM  ', 0
    cpu_label       db 'CPU  ', 0
    disk_label      db 'DISK ', 0
    net_label       db 'NET  ', 0
    sys_label       db 'SYS  ', 0
    down_label      db ' down ', 0
    up_label        db ' up ', 0
    gb_suffix       db 'G', 0
    slash_sep       db '/', 0
    kbs_suffix      db 'KB/s', 0
    sep2            db '  ', 0
    detail_indent   db '     ', 0
    threads_suffix  db ' threads', 0
    at_freq         db '  @ ', 0
    mhz_suffix      db 'MHz', 0
    cache_prefix    db '  cache ', 0
    buffcache_label db 'buff/cache ', 0
    swap_label      db '  swap ', 0
    up_prefix       db 'up ', 0
    load_prefix     db '  load ', 0
    procs_prefix    db '  procs ', 0
    net_rx_label    db ' rx ', 0
    net_tx_label    db ' tx ', 0
    disk_root_label db '  /', 0
    sep_line         db '--------------------------------------------', 10, 0

    sleep_ts     dq 0, INTERVAL_MS * 1000000   ; timespec {0, ms in ns}

section .bss
    ; Command line flags
    show_mem     resb 1
    show_cpu     resb 1
    show_net     resb 1
    show_all     resb 1
    show_verbose resb 1
    use_color    resb 1

    need_mem   resb 1
    need_cpu   resb 1
    need_net   resb 1

    ; CPU samples (jiffies)
    cpu_total1  resq 1
    cpu_idle1   resq 1
    cpu_total2  resq 1
    cpu_idle2   resq 1
    cpu_percent resq 1

    ; Net samples (bytes)
    net_rx1        resq 1
    net_tx1        resq 1
    net_rx2        resq 1
    net_tx2        resq 1
    net_rx_rate    resq 1
    net_tx_rate    resq 1
    net_rx_scratch resq 1
    net_tx_scratch resq 1

    ; Memory (kB)
    mem_total_kb resq 1
    mem_avail_kb resq 1
    mem_used_kb  resq 1
    mem_percent  resq 1

    ; Disk (bytes, root filesystem)
    disk_total   resq 1
    disk_used    resq 1
    disk_percent resq 1
    statfs_buf   resb 128

    ; Directory scan (net interfaces)
    dirfd      resq 1
    dents_len  resq 1
    dents_off  resq 1
    dirent_buf resb DENTS_SZ

    ; Per-interface detail table (-v)
    cur_net_name resq 1
    net_count    resq 1
    net_names    resb MAX_NET * IFACE_NAME_MAX
    net_states   resb MAX_NET * STATE_MAX
    net_iface_rx resq MAX_NET
    net_iface_tx resq MAX_NET

    ; System block (-v)
    utsname_buf resb 390
    uptime_secs resq 1

    ; Path building
    path_buf     resb 256
    dev_path_len resq 1

    ; Scratch / file buffers
    stat_buf     resb 256
    meminfo_buf  resb 4096
    cpuinfo_buf  resb CPUINFO_MAX + 1
    uptime_buf   resb 64
    loadavg_buf  resb 128
    os_release_buf resb 2048
    num_buf      resb 40
    num_tmp      resb 32
    termios_buf  resb 64
    out_buf      resb 4096

section .text
    global _start

; Compare argv entry in r10 against a short and a long option
%macro CHECKOPT 3
    mov rdi, r10
    mov rsi, %1
    call str_eq
    test al, al
    jnz %3
    mov rdi, r10
    mov rsi, %2
    call str_eq
    test al, al
    jnz %3
%endmacro

_start:
    mov byte [show_all], 1
    mov byte [show_verbose], 1

    mov r12, [rsp]              ; argc
    lea r13, [rsp+8]            ; argv
    mov r14, 1

.arg_loop:
    cmp r14, r12
    jge .args_done
    mov r10, [r13 + r14*8]

    CHECKOPT help_short, help_long, show_help
    CHECKOPT mem_short, mem_long, .set_mem
    CHECKOPT cpu_short, cpu_long, .set_cpu
    CHECKOPT net_short, net_long, .set_net
    CHECKOPT all_short, all_long, .set_all
    CHECKOPT verbose_short, verbose_long, .set_verbose
    jmp unknown_option

.set_mem:
    mov byte [show_mem], 1
    mov byte [show_all], 0
    jmp .next
.set_cpu:
    mov byte [show_cpu], 1
    mov byte [show_all], 0
    jmp .next
.set_net:
    mov byte [show_net], 1
    mov byte [show_all], 0
    jmp .next
.set_all:
    mov byte [show_all], 1
    jmp .next
.set_verbose:
    mov byte [show_verbose], 1
.next:
    inc r14
    jmp .arg_loop

.args_done:
    call detect_tty

    mov al, [show_all]
    or al, [show_mem]
    mov [need_mem], al
    mov al, [show_all]
    or al, [show_cpu]
    mov [need_cpu], al
    mov al, [show_all]
    or al, [show_net]
    mov [need_net], al

    cmp byte [need_cpu], 0
    je .skip_cpu1
    call sample_cpu
    mov [cpu_total1], rax
    mov [cpu_idle1], rdx
.skip_cpu1:

    cmp byte [need_net], 0
    je .skip_net1
    call sample_net
    mov rax, [net_rx_scratch]
    mov [net_rx1], rax
    mov rax, [net_tx_scratch]
    mov [net_tx1], rax
.skip_net1:

    mov al, [need_cpu]
    or al, [need_net]
    jz .skip_sleep
    mov eax, SYS_nanosleep
    mov rdi, sleep_ts
    xor esi, esi
    syscall
.skip_sleep:

    cmp byte [need_cpu], 0
    je .skip_cpu2
    call sample_cpu
    mov [cpu_total2], rax
    mov [cpu_idle2], rdx
    call calc_cpu_percent
.skip_cpu2:

    cmp byte [need_net], 0
    je .skip_net2
    call sample_net
    mov rax, [net_rx_scratch]
    mov [net_rx2], rax
    mov rax, [net_tx_scratch]
    mov [net_tx2], rax
    call calc_net_rates
.skip_net2:

    cmp byte [need_mem], 0
    je .skip_mem
    call sample_mem
.skip_mem:

    call render

    xor edi, edi
    mov eax, SYS_exit
    syscall

show_help:
    mov eax, SYS_write
    mov edi, STDOUT
    mov rsi, usage_msg
    mov edx, usage_len
    syscall
    xor edi, edi
    mov eax, SYS_exit
    syscall

unknown_option:
    mov rbx, out_buf
    mov rsi, unknown_opt_msg
    call emit_str
    mov rsi, r10
    call emit_str
    mov rsi, use_help_msg
    call emit_str

    mov eax, SYS_write
    mov edi, STDERR
    mov rsi, out_buf
    mov rdx, rbx
    sub rdx, out_buf
    syscall

    mov edi, 1
    mov eax, SYS_exit
    syscall

; ---------------------------------------------------------------------------
; CPU sampling - /proc/stat aggregate line
; ---------------------------------------------------------------------------

; -> rax = total jiffies, rdx = idle jiffies (idle + iowait)
sample_cpu:
    mov rdi, proc_stat_path
    mov rsi, stat_buf
    mov edx, 255
    call read_whole_file
    test rax, rax
    jle .fail

    mov rdi, stat_buf
    add rdi, 3                  ; skip "cpu"
    call skip_spaces
    call parse_uint_adv
    mov r10, rax                 ; user
    call skip_spaces
    call parse_uint_adv
    add r10, rax                 ; + nice
    call skip_spaces
    call parse_uint_adv
    add r10, rax                 ; + system
    call skip_spaces
    call parse_uint_adv
    mov r11, rax                 ; idle
    add r10, rax
    call skip_spaces
    call parse_uint_adv
    add r10, rax                 ; + iowait
    add r11, rax                 ; idle_all += iowait
    call skip_spaces
    call parse_uint_adv
    add r10, rax                 ; + irq
    call skip_spaces
    call parse_uint_adv
    add r10, rax                 ; + softirq
    call skip_spaces
    call parse_uint_adv
    add r10, rax                 ; + steal

    mov rax, r10
    mov rdx, r11
    ret
.fail:
    xor eax, eax
    xor edx, edx
    ret

; delta_busy * 100 / delta_total -> [cpu_percent]
calc_cpu_percent:
    mov rax, [cpu_total2]
    sub rax, [cpu_total1]
    mov rcx, rax                 ; delta_total
    mov rdx, [cpu_idle2]
    sub rdx, [cpu_idle1]         ; delta_idle
    mov r8, rcx
    sub r8, rdx                  ; delta_busy

    test rcx, rcx
    jz .zero
    mov rax, r8
    mov r9, 100
    mul r9                        ; rdx:rax = delta_busy * 100
    div rcx
    mov [cpu_percent], rax
    ret
.zero:
    mov qword [cpu_percent], 0
    ret

; ---------------------------------------------------------------------------
; Network sampling - sum rx_bytes/tx_bytes over every non-loopback interface
; ---------------------------------------------------------------------------

sample_net:
    xor r14, r14                 ; rx sum
    xor r15, r15                 ; tx sum

    mov eax, SYS_open
    mov rdi, net_class_dir
    mov esi, O_RDONLY_DIR
    xor edx, edx
    syscall
    test eax, eax
    js .store
    mov [dirfd], rax

.next_block:
    mov eax, SYS_getdents64
    mov rdi, [dirfd]
    mov rsi, dirent_buf
    mov edx, DENTS_SZ
    syscall
    test rax, rax
    jle .close
    mov [dents_len], rax
    mov qword [dents_off], 0

.entry:
    mov rax, [dents_off]
    cmp rax, [dents_len]
    jae .next_block

    lea rsi, [dirent_buf + rax]
    movzx edx, word [rsi + 16]   ; d_reclen
    add [dents_off], rdx
    lea rdi, [rsi + 19]          ; d_name

    cmp byte [rdi], '.'
    je .entry

    push rdi
    mov rsi, lo_name
    call str_eq
    pop rdi
    test al, al
    jnz .entry                   ; skip loopback

    call set_net_path
    mov rdi, rx_bytes_file
    call read_number
    test rdx, rdx
    jz .entry
    add r14, rax

    mov rdi, tx_bytes_file
    call read_number
    test rdx, rdx
    jz .entry
    add r15, rax

    jmp .entry

.close:
    mov eax, SYS_close
    mov rdi, [dirfd]
    syscall
.store:
    mov [net_rx_scratch], r14
    mov [net_tx_scratch], r15
    ret

; rdi = interface name -> path_buf = "/sys/class/net/<name>/statistics/"
set_net_path:
    push rdi
    mov rdi, path_buf
    mov rsi, net_class_dir
    call strcpy_z
    pop rsi
    call strcpy_z
    mov byte [rdi], '/'
    inc rdi
    mov rsi, stats_subdir
    call strcpy_z
    sub rdi, path_buf
    mov [dev_path_len], rdi
    ret

; rdi = interface name -> path_buf = "/sys/class/net/<name>/"
set_iface_root_path:
    push rdi
    mov rdi, path_buf
    mov rsi, net_class_dir
    call strcpy_z
    pop rsi
    call strcpy_z
    mov byte [rdi], '/'
    inc rdi
    mov byte [rdi], 0
    sub rdi, path_buf
    mov [dev_path_len], rdi
    ret

; delta * 1000 / INTERVAL_MS -> bytes/sec, clamped to 0 on counter reset
calc_net_rates:
    mov rax, [net_rx2]
    sub rax, [net_rx1]
    jns .rxok
    xor eax, eax
.rxok:
    mov rcx, 1000
    mul rcx
    mov rcx, INTERVAL_MS
    div rcx
    mov [net_rx_rate], rax

    mov rax, [net_tx2]
    sub rax, [net_tx1]
    jns .txok
    xor eax, eax
.txok:
    mov rcx, 1000
    mul rcx
    mov rcx, INTERVAL_MS
    div rcx
    mov [net_tx_rate], rax
    ret

; Scan /sys/class/net once more, recording name/operstate/rx/tx per interface
; for the -v detail listing (independent of the rate sampling above).
list_net_ifaces:
    mov qword [net_count], 0

    mov eax, SYS_open
    mov rdi, net_class_dir
    mov esi, O_RDONLY_DIR
    xor edx, edx
    syscall
    test eax, eax
    js .ret
    mov [dirfd], rax

.next_block:
    mov eax, SYS_getdents64
    mov rdi, [dirfd]
    mov rsi, dirent_buf
    mov edx, DENTS_SZ
    syscall
    test rax, rax
    jle .close
    mov [dents_len], rax
    mov qword [dents_off], 0

.entry:
    mov rax, [dents_off]
    cmp rax, [dents_len]
    jae .next_block

    lea rsi, [dirent_buf + rax]
    movzx edx, word [rsi + 16]
    add [dents_off], rdx
    lea rdi, [rsi + 19]
    mov [cur_net_name], rdi

    cmp byte [rdi], '.'
    je .entry

    mov rsi, lo_name
    call str_eq
    test al, al
    jnz .entry

    call add_net_iface
    jmp .entry

.close:
    mov eax, SYS_close
    mov rdi, [dirfd]
    syscall
.ret:
    ret

add_net_iface:
    mov rax, [net_count]
    cmp rax, MAX_NET
    jae .ret

    mov rcx, IFACE_NAME_MAX
    mul rcx
    lea rdi, [net_names + rax]
    mov rsi, [cur_net_name]
    call copy_name

    mov rdi, [cur_net_name]
    call set_net_path
    mov rdi, rx_bytes_file
    call read_number
    mov r8, [net_count]
    lea r9, [net_iface_rx + r8*8]
    mov [r9], rax

    mov rdi, tx_bytes_file
    call read_number
    mov r8, [net_count]
    lea r9, [net_iface_tx + r8*8]
    mov [r9], rax

    mov rdi, [cur_net_name]
    call set_iface_root_path

    mov rax, [net_count]
    mov rcx, STATE_MAX
    mul rcx
    lea rsi, [net_states + rax]
    mov rdi, operstate_file
    mov edx, STATE_MAX - 1
    call read_str_attr

    inc qword [net_count]
.ret:
    ret

; ---------------------------------------------------------------------------
; Memory sampling - /proc/meminfo
; ---------------------------------------------------------------------------

sample_mem:
    mov rdi, proc_meminfo_path
    mov rsi, meminfo_buf
    mov edx, 4095
    call read_whole_file
    test rax, rax
    jle .fail

    mov rdi, meminfo_buf
    mov rsi, key_memtotal
    call find_field
    mov [mem_total_kb], rax

    mov rdi, meminfo_buf
    mov rsi, key_memavail
    call find_field
    test rdx, rdx
    jnz .have_avail
    mov rdi, meminfo_buf
    mov rsi, key_memfree
    call find_field
.have_avail:
    mov [mem_avail_kb], rax

    mov rax, [mem_total_kb]
    sub rax, [mem_avail_kb]
    mov [mem_used_kb], rax

    mov rcx, [mem_total_kb]
    test rcx, rcx
    jz .zero
    mov rax, [mem_used_kb]
    mov r9, 100
    mul r9
    div rcx
    mov [mem_percent], rax
    ret
.zero:
    mov qword [mem_percent], 0
    ret
.fail:
    xor eax, eax
    mov [mem_total_kb], rax
    mov [mem_avail_kb], rax
    mov [mem_used_kb], rax
    mov [mem_percent], rax
    ret

; ---------------------------------------------------------------------------
; Disk sampling - statfs("/") for root filesystem usage
; ---------------------------------------------------------------------------

sample_disk:
    mov eax, SYS_statfs
    mov rdi, root_path
    mov rsi, statfs_buf
    syscall
    test rax, rax
    js .fail

    mov rax, [statfs_buf + 16]   ; f_blocks
    mov rcx, [statfs_buf + 72]   ; f_frsize
    mul rcx                       ; total bytes
    mov [disk_total], rax

    mov rax, [statfs_buf + 16]   ; f_blocks
    sub rax, [statfs_buf + 24]   ; - f_bfree = used blocks
    mov rcx, [statfs_buf + 72]
    mul rcx                       ; used bytes
    mov [disk_used], rax

    mov rcx, [disk_total]
    test rcx, rcx
    jz .zero
    mov rax, [disk_used]
    mov r9, 100
    mul r9
    div rcx
    mov [disk_percent], rax
    ret
.zero:
    mov qword [disk_percent], 0
    ret
.fail:
    xor eax, eax
    mov [disk_total], rax
    mov [disk_used], rax
    mov [disk_percent], rax
    ret

; rdi = buffer start, rsi = key (e.g. "MemTotal:") -> rax = value, rdx = 1 if found
find_field:
.line:
    cmp byte [rdi], 0
    je .fail
    mov r8, rdi
    mov r9, rsi
.match:
    mov al, [r9]
    test al, al
    jz .found
    cmp al, [r8]
    jne .next_line
    inc r9
    inc r8
    jmp .match
.found:
    mov rdi, r8
.skip_sp:
    cmp byte [rdi], ' '
    jne .parse
    inc rdi
    jmp .skip_sp
.parse:
    call atou
    mov edx, 1
    ret
.next_line:
    cmp byte [rdi], 0
    je .fail
    cmp byte [rdi], 10
    je .adv
    inc rdi
    jmp .next_line
.adv:
    inc rdi
    jmp .line
.fail:
    xor eax, eax
    xor edx, edx
    ret

; rdi = buffer start, rsi = key -> rax = pointer to the value's first char, rdx = 1 if found
find_text_field:
.line:
    cmp byte [rdi], 0
    je .fail
    mov r8, rdi
    mov r9, rsi
.match:
    mov al, [r9]
    test al, al
    jz .found
    cmp al, [r8]
    jne .next_line
    inc r9
    inc r8
    jmp .match
.found:
    mov rdi, r8
.find_colon:
    cmp byte [rdi], ':'
    je .colon
    cmp byte [rdi], 10
    je .fail
    cmp byte [rdi], 0
    je .fail
    inc rdi
    jmp .find_colon
.colon:
    inc rdi
.skip_sp:
    cmp byte [rdi], ' '
    jne .value
    inc rdi
    jmp .skip_sp
.value:
    mov rax, rdi
    mov edx, 1
    ret
.next_line:
    cmp byte [rdi], 0
    je .fail
    cmp byte [rdi], 10
    je .adv
    inc rdi
    jmp .next_line
.adv:
    inc rdi
    jmp .line
.fail:
    xor eax, eax
    xor edx, edx
    ret

; rdi = buffer start, rsi = key ending in '=' (e.g. "PRETTY_NAME=")
; -> rax = pointer to the value (leading quote stripped), rdx = 1 if found
find_env_field:
.line:
    cmp byte [rdi], 0
    je .fail
    mov r8, rdi
    mov r9, rsi
.match:
    mov al, [r9]
    test al, al
    jz .found
    cmp al, [r8]
    jne .next_line
    inc r9
    inc r8
    jmp .match
.found:
    mov rdi, r8
    cmp byte [rdi], '"'
    jne .value
    inc rdi
.value:
    mov rax, rdi
    mov edx, 1
    ret
.next_line:
    cmp byte [rdi], 0
    je .fail
    cmp byte [rdi], 10
    je .adv
    inc rdi
    jmp .next_line
.adv:
    inc rdi
    jmp .line
.fail:
    xor eax, eax
    xor edx, edx
    ret

; rdi = buffer start, rsi = key -> rax = number of lines starting with key
count_prefix_lines:
    xor r10, r10
.line:
    cmp byte [rdi], 0
    je .done
    mov r8, rdi
    mov r9, rsi
.match:
    mov al, [r9]
    test al, al
    jz .matched
    cmp al, [r8]
    jne .next_line
    inc r9
    inc r8
    jmp .match
.matched:
    inc r10
.next_line:
    cmp byte [rdi], 0
    je .done
    cmp byte [rdi], 10
    je .adv
    inc rdi
    jmp .next_line
.adv:
    inc rdi
    jmp .line
.done:
    mov rax, r10
    ret

; ---------------------------------------------------------------------------
; sysfs / procfs helpers
; ---------------------------------------------------------------------------

; rdi = path, rsi = dest buffer, edx = max bytes -> rax = bytes read (0 on failure)
; Null-terminates the buffer at the read length. Loops until EOF or the
; buffer fills - procfs/sysfs files (notably /proc/cpuinfo) routinely need
; more than one read() call to hand back their whole content.
; Note: max bytes is kept in r13, not r11 - the syscall instruction itself
; clobbers rcx/r11, so anything that must survive a syscall can't live there.
read_whole_file:
    mov r10, rsi                 ; dest base
    mov r13d, edx                ; max bytes

    mov eax, SYS_open
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .fail

    mov r8d, eax                 ; fd
    xor r12, r12                 ; total read so far

.read_loop:
    mov eax, SYS_read
    mov edi, r8d
    lea rsi, [r10 + r12]
    mov edx, r13d
    sub edx, r12d
    jle .done                    ; buffer full
    syscall
    test rax, rax
    jle .done                    ; 0 = EOF, negative = error
    add r12, rax
    jmp .read_loop

.done:
    mov eax, SYS_close
    mov edi, r8d
    syscall

    test r12, r12
    jle .fail
    mov byte [r10 + r12], 0
    mov rax, r12
    ret
.fail:
    xor eax, eax
    ret

; rdi = attribute name -> rax = fd (negative on error)
open_attr:
    mov rsi, rdi
    mov rdi, path_buf
    add rdi, [dev_path_len]
    call strcpy_z

    mov eax, SYS_open
    mov rdi, path_buf
    xor esi, esi                ; O_RDONLY
    xor edx, edx
    syscall
    ret

; rdi = attribute name -> rax = value, rdx = 1 if the file was readable
read_number:
    call open_attr
    test eax, eax
    js .missing

    mov r8d, eax
    xor eax, eax                ; SYS_read
    mov edi, r8d
    mov rsi, num_buf
    mov edx, 31
    syscall
    mov r9, rax

    mov eax, SYS_close
    mov edi, r8d
    syscall

    test r9, r9
    jle .missing
    mov byte [num_buf + r9], 0

    mov rdi, num_buf
    call atou
    mov edx, 1
    ret
.missing:
    xor eax, eax
    xor edx, edx
    ret

; rdi = attribute name, rsi = dest, edx = max bytes -> rax = length (0 on failure)
; Trims trailing whitespace/newline.
; Note: max bytes is kept in r13, not r11 - open_attr issues its own syscall
; (SYS_open), which would clobber r11 before we get to use it below.
read_str_attr:
    mov r10, rsi
    mov r13d, edx
    call open_attr
    test eax, eax
    js .fail

    mov r8d, eax
    xor eax, eax                ; SYS_read
    mov edi, r8d
    mov rsi, r10
    mov edx, r13d
    syscall
    mov r9, rax

    mov eax, SYS_close
    mov edi, r8d
    syscall

    test r9, r9
    jle .fail
    mov byte [r10 + r9], 0
.trim:
    test r9, r9
    jz .done
    dec r9
    cmp byte [r10 + r9], ' '
    ja .done
    mov byte [r10 + r9], 0
    jmp .trim
.done:
    mov rax, r9
    ret
.fail:
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
; Output
; ---------------------------------------------------------------------------

; Colors only make sense on a terminal
detect_tty:
    mov eax, SYS_ioctl
    mov edi, STDOUT
    mov esi, TCGETS
    mov rdx, termios_buf
    syscall
    test eax, eax
    jnz .ret
    mov byte [use_color], 1
.ret:
    ret

render:
    mov rbx, out_buf

    cmp byte [show_all], 1
    je .all

    cmp byte [show_mem], 1
    jne .no_mem
    call emit_mem_line
.no_mem:
    cmp byte [show_cpu], 1
    jne .no_cpu
    call emit_cpu_line
.no_cpu:
    cmp byte [show_net], 1
    jne .sys_check
    call emit_net_line
    jmp .sys_check

.all:
    call emit_mem_line
    call emit_cpu_line
    call emit_net_line

.sys_check:
    cmp byte [show_verbose], 1
    jne .flush
    call emit_disk_line
    call emit_sys_block

.flush:
    mov rdx, rbx
    sub rdx, out_buf
    jz .ret
    mov eax, SYS_write
    mov edi, STDOUT
    mov rsi, out_buf
    syscall
.ret:
    ret

; Dashed divider before a section, but only if something was already
; written - keeps sections apart without a leading or trailing divider.
emit_sep_if_needed:
    cmp rbx, out_buf
    je .ret
    mov rsi, sep_line
    call emit_str
.ret:
    ret

emit_mem_line:
    call emit_sep_if_needed
    mov rsi, mem_label
    call emit_str

    mov rdi, [mem_percent]
    call emit_bar
    mov al, ' '
    call emit_char

    mov rdi, [mem_percent]
    call emit_percent_colored
    mov al, ' '
    call emit_char

    mov rax, [mem_used_kb]
    mov rcx, 1024 * 1024
    call emit_fixed1
    mov rsi, slash_sep
    call emit_str
    mov rax, [mem_total_kb]
    mov rcx, 1024 * 1024
    call emit_fixed1
    mov rsi, gb_suffix
    call emit_str

    call emit_nl

    cmp byte [show_verbose], 1
    jne .ret
    call emit_mem_details
.ret:
    ret

emit_cpu_line:
    call emit_sep_if_needed
    mov rsi, cpu_label
    call emit_str

    mov rdi, [cpu_percent]
    call emit_bar
    mov al, ' '
    call emit_char

    mov rdi, [cpu_percent]
    call emit_percent_colored

    call emit_nl

    cmp byte [show_verbose], 1
    jne .ret
    call emit_cpu_details
.ret:
    ret

emit_net_line:
    call emit_sep_if_needed
    mov rsi, net_label
    call emit_str

    mov rsi, down_label
    call emit_str
    mov rax, [net_rx_rate]
    mov rcx, 1024
    call emit_fixed1
    mov rsi, kbs_suffix
    call emit_str

    mov rsi, up_label
    call emit_str
    mov rax, [net_tx_rate]
    mov rcx, 1024
    call emit_fixed1
    mov rsi, kbs_suffix
    call emit_str

    call emit_nl

    cmp byte [show_verbose], 1
    jne .ret
    call emit_net_details
.ret:
    ret

; buff/cache and swap usage, read from the meminfo_buf sample_mem already populated
emit_mem_details:
    mov rdi, meminfo_buf
    mov rsi, key_buffers
    call find_field
    mov r10, rax

    mov rdi, meminfo_buf
    mov rsi, key_cached
    call find_field
    add r10, rax                 ; buffers + cached

    mov rdi, meminfo_buf
    mov rsi, key_swaptotal
    call find_field
    mov r11, rax                 ; swap total

    mov rdi, meminfo_buf
    mov rsi, key_swapfree
    call find_field
    mov r12, r11
    sub r12, rax                 ; swap used

    mov rsi, detail_indent
    call emit_str

    mov rsi, buffcache_label
    call emit_str
    mov rax, r10
    mov rcx, 1024 * 1024
    call emit_fixed1
    mov rsi, gb_suffix
    call emit_str

    mov rsi, swap_label
    call emit_str
    mov rax, r12
    mov rcx, 1024 * 1024
    call emit_fixed1
    mov rsi, slash_sep
    call emit_str
    mov rax, r11
    mov rcx, 1024 * 1024
    call emit_fixed1
    mov rsi, gb_suffix
    call emit_str

    call emit_nl
    ret

; Model name, thread count and current clock speed from /proc/cpuinfo
emit_cpu_details:
    mov rdi, proc_cpuinfo_path
    mov rsi, cpuinfo_buf
    mov edx, CPUINFO_MAX
    call read_whole_file
    test rax, rax
    jle .ret

    mov rsi, detail_indent
    call emit_str

    mov rdi, cpuinfo_buf
    mov rsi, key_modelname
    call find_text_field
    test rdx, rdx
    jz .no_model
    mov rsi, rax
    xor edx, edx
    mov dl, 0
    call emit_field_until
.no_model:

    mov rdi, cpuinfo_buf
    mov rsi, key_processor
    call count_prefix_lines
    mov rsi, sep2
    call emit_str
    call emit_num
    mov rsi, threads_suffix
    call emit_str

    mov rdi, cpuinfo_buf
    mov rsi, key_cpumhz
    call find_text_field
    test rdx, rdx
    jz .no_mhz
    mov rsi, at_freq
    call emit_str
    mov rsi, rax
    mov dl, '.'
    call emit_field_until
    mov rsi, mhz_suffix
    call emit_str
.no_mhz:

    mov rdi, cpuinfo_buf
    mov rsi, key_cachesize
    call find_text_field
    test rdx, rdx
    jz .no_cache
    mov rsi, cache_prefix
    call emit_str
    mov rsi, rax
    xor edx, edx
    mov dl, 0
    call emit_field_until
.no_cache:

    call emit_nl
.ret:
    ret

; Per-interface name, link state and all-time rx/tx totals
emit_net_details:
    call list_net_ifaces

    xor r12, r12
.loop:
    cmp r12, [net_count]
    jge .ret

    mov rsi, detail_indent
    call emit_str

    mov rax, r12
    mov rcx, IFACE_NAME_MAX
    mul rcx
    lea rsi, [net_names + rax]
    call emit_str
    mov al, ' '
    call emit_char

    mov rax, r12
    mov rcx, STATE_MAX
    mul rcx
    lea rsi, [net_states + rax]
    call emit_str

    mov rsi, net_rx_label
    call emit_str
    mov rax, [net_iface_rx + r12*8]
    mov rcx, 1024 * 1024 * 1024
    call emit_fixed1
    mov rsi, gb_suffix
    call emit_str

    mov rsi, net_tx_label
    call emit_str
    mov rax, [net_iface_tx + r12*8]
    mov rcx, 1024 * 1024 * 1024
    call emit_fixed1
    mov rsi, gb_suffix
    call emit_str

    call emit_nl

    inc r12
    jmp .loop
.ret:
    ret

; Root filesystem usage bar, from statfs("/")
emit_disk_line:
    call sample_disk
    call emit_sep_if_needed

    mov rsi, disk_label
    call emit_str

    mov rdi, [disk_percent]
    call emit_bar
    mov al, ' '
    call emit_char

    mov rdi, [disk_percent]
    call emit_percent_colored
    mov al, ' '
    call emit_char

    mov rax, [disk_used]
    mov rcx, 1024 * 1024 * 1024
    call emit_fixed1
    mov rsi, slash_sep
    call emit_str
    mov rax, [disk_total]
    mov rcx, 1024 * 1024 * 1024
    call emit_fixed1
    mov rsi, gb_suffix
    call emit_str
    mov rsi, disk_root_label
    call emit_str

    call emit_nl
    ret

; Hostname, kernel version, uptime and load average
emit_sys_block:
    mov eax, SYS_uname
    mov rdi, utsname_buf
    syscall

    call emit_sep_if_needed
    mov rsi, sys_label
    call emit_str

    lea rsi, [utsname_buf + 65]  ; nodename
    xor edx, edx
    mov dl, 0
    call emit_field_until
    mov rsi, sep2
    call emit_str

    ; OS pretty name from /etc/os-release, if present
    mov rdi, os_release_path
    mov rsi, os_release_buf
    mov edx, 2047
    call read_whole_file
    test rax, rax
    jle .no_os_release
    mov rdi, os_release_buf
    mov rsi, key_pretty_name
    call find_env_field
    test rdx, rdx
    jz .no_os_release
    mov rsi, rax
    mov dl, '"'
    call emit_field_until
    mov rsi, sep2
    call emit_str
.no_os_release:

    lea rsi, [utsname_buf]       ; sysname
    mov dl, 0
    call emit_field_until
    mov al, ' '
    call emit_char
    lea rsi, [utsname_buf + 130] ; release
    mov dl, 0
    call emit_field_until
    mov al, ' '
    call emit_char
    lea rsi, [utsname_buf + 260] ; machine
    mov dl, 0
    call emit_field_until
    call emit_nl

    mov rsi, detail_indent
    call emit_str

    mov rdi, proc_uptime_path
    mov rsi, uptime_buf
    mov edx, 63
    call read_whole_file
    test rax, rax
    jle .no_uptime

    mov rdi, uptime_buf
    call parse_uint_adv
    mov [uptime_secs], rax

    mov rsi, up_prefix
    call emit_str

    mov rax, [uptime_secs]
    mov rcx, 86400
    xor edx, edx
    div rcx
    mov r10, rax                 ; days
    mov r11, rdx                 ; remainder

    test r10, r10
    jz .no_days
    mov rax, r10
    call emit_num
    mov al, 'd'
    call emit_char
    mov al, ' '
    call emit_char
.no_days:
    mov rax, r11
    mov rcx, 3600
    xor edx, edx
    div rcx
    mov r10, rax                 ; hours
    mov r11, rdx

    mov rax, r10
    call emit_num
    mov al, 'h'
    call emit_char
    mov al, ' '
    call emit_char

    mov rax, r11
    mov rcx, 60
    xor edx, edx
    div rcx                      ; minutes
    call emit_num
    mov al, 'm'
    call emit_char
.no_uptime:

    mov rsi, load_prefix
    call emit_str

    mov rdi, proc_loadavg_path
    mov rsi, loadavg_buf
    mov edx, 127
    call read_whole_file
    test rax, rax
    jle .no_load

    mov rsi, loadavg_buf
    mov dl, ' '
    call emit_field_until
    mov al, ' '
    call emit_char
    inc rsi
    call emit_field_until
    mov al, ' '
    call emit_char
    inc rsi
    call emit_field_until
    call emit_procs_count
.no_load:

    call emit_nl
    ret

; rsi = pointer at/after the third loadavg field (e.g. " 1/234 5678")
; Emits "  procs N" using the total-processes half of the "running/total" field.
emit_procs_count:
    push rax
    push rcx
    push rdx
.find_slash:
    cmp byte [rsi], 0
    je .done
    cmp byte [rsi], 10
    je .done
    cmp byte [rsi], '/'
    je .got
    inc rsi
    jmp .find_slash
.got:
    inc rsi
    mov rdi, rsi
    call parse_uint_adv
    mov rsi, procs_prefix
    call emit_str
    call emit_num
.done:
    pop rdx
    pop rcx
    pop rax
    ret

; rdi = percentage (0-100+, capped at 100 for the bar)
emit_bar:
    mov al, '['
    call emit_char

    push rdi
    call usage_color
    mov rsi, rax
    call emit_color
    pop rdi

    mov rax, rdi
    cmp rax, 100
    jbe .capped
    mov eax, 100
.capped:
    mov rcx, 100 / BAR_WIDTH
    xor edx, edx
    div rcx
    mov r8, rax                  ; filled
    mov rcx, rax

    mov al, '#'
.fill:
    test rcx, rcx
    jz .empty
    call emit_char
    dec rcx
    jmp .fill

.empty:
    mov rsi, reset_color
    call emit_color

    mov rcx, BAR_WIDTH
    sub rcx, r8

    mov al, '-'
.dash:
    test rcx, rcx
    jz .close
    call emit_char
    dec rcx
    jmp .dash

.close:
    mov al, ']'
    call emit_char
    ret

; rdi = percentage -> " NN%" colored, then reset
emit_percent_colored:
    push rdi
    call usage_color
    mov rsi, rax
    call emit_color
    pop rdi

    mov rax, rdi
    call emit_num_pad3
    mov al, '%'
    call emit_char

    mov rsi, reset_color
    call emit_color
    ret

; rdi = percentage -> rax = color string (high usage is bad, unlike battery level)
usage_color:
    mov rax, green_color
    cmp rdi, 50
    jbe .ret
    mov rax, yellow_color
    cmp rdi, 75
    jbe .ret
    mov rax, red_color
.ret:
    ret

; rax = value, rcx = divisor -> emits "W.D" (one decimal digit)
emit_fixed1:
    xor edx, edx
    div rcx
    push rdx
    push rcx
    call emit_num
    mov al, '.'
    call emit_char
    pop rcx
    pop rax                      ; remainder
    imul rax, 10
    xor edx, edx
    div rcx
    add al, '0'
    call emit_char
    ret

; ---------------------------------------------------------------------------
; Emit primitives - rbx is the output cursor, everything else is preserved
; ---------------------------------------------------------------------------

; al = character
emit_char:
    mov [rbx], al
    inc rbx
    ret

emit_nl:
    push rax
    mov al, 10
    call emit_char
    pop rax
    ret

; rsi = null-terminated string
emit_str:
    push rax
    push rsi
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    mov [rbx], al
    inc rbx
    inc rsi
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; rsi = null-terminated string, emitted only when stdout is a terminal
emit_color:
    cmp byte [use_color], 0
    je .ret
    jmp emit_str
.ret:
    ret

; rsi = pointer into a buffer (advances, left pointing at the stop byte)
; dl  = an extra stop byte, in addition to the mandatory null/newline stop
emit_field_until:
    push rax
.loop:
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, 10
    je .done
    cmp al, dl
    je .done
    mov [rbx], al
    inc rbx
    inc rsi
    jmp .loop
.done:
    pop rax
    ret

; rax = value
emit_num:
    push rax
    push rcx
    push rdx
    push rsi

    mov rsi, num_tmp + 31
    mov byte [rsi], 0
    mov rcx, 10
.digit:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .digit
    call emit_str

    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; rax = value, right-aligned in three columns
emit_num_pad3:
    push rax
    cmp rax, 100
    jae .num
    mov al, ' '
    call emit_char
    cmp qword [rsp], 10
    jae .num
    call emit_char
.num:
    pop rax
    jmp emit_num

; ---------------------------------------------------------------------------
; String / number helpers
; ---------------------------------------------------------------------------

; rdi advances past spaces
skip_spaces:
.loop:
    cmp byte [rdi], ' '
    jne .done
    inc rdi
    jmp .loop
.done:
    ret

; rdi = digit string, advanced past the digits -> rax = value
parse_uint_adv:
    xor eax, eax
    xor ecx, ecx
.loop:
    mov cl, [rdi]
    sub cl, '0'
    cmp cl, 9
    ja .done
    lea rax, [rax + rax*4]      ; rax *= 5
    lea rax, [rcx + rax*2]      ; rax = rax*10 + digit
    inc rdi
    jmp .loop
.done:
    ret

; rdi = null-terminated digits -> rax = value
atou:
    xor eax, eax
    xor ecx, ecx
.loop:
    mov cl, [rdi]
    sub cl, '0'
    cmp cl, 9
    ja .done
    lea rax, [rax + rax*4]
    lea rax, [rcx + rax*2]
    inc rdi
    jmp .loop
.done:
    ret

; rdi = dst, rsi = src -> rdi points at the terminating null
strcpy_z:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rdi
    inc rsi
    jmp strcpy_z
.done:
    ret

; rdi = dst, rsi = src, truncated to IFACE_NAME_MAX
copy_name:
    mov ecx, IFACE_NAME_MAX - 1
.copy:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rdi
    inc rsi
    dec ecx
    jnz .copy
    mov byte [rdi], 0
.done:
    ret

; rdi = str1, rsi = str2 -> al = 1 when equal
str_eq:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .differ
    test al, al
    jz .equal
    inc rdi
    inc rsi
    jmp str_eq
.equal:
    mov eax, 1
    ret
.differ:
    xor eax, eax
    ret
