# Makefile for sysstat (assembly mem/cpu/net monitor)

# Variables
ASM = nasm
LD = ld
ASMFLAGS = -f elf64
# sysstat is pure syscalls - no libc, no dynamic linker
LDFLAGS = -s --build-id=none

# Target executable
TARGET = sysstat

# Source files
SRC = sysstat.asm
OBJ = sysstat.o

# Default target
all: $(TARGET)

# Build the executable
$(TARGET): $(OBJ)
	$(LD) -o $@ $< $(LDFLAGS)

# Assemble the source
$(OBJ): $(SRC)
	$(ASM) $(ASMFLAGS) -o $@ $<

# Clean build artifacts
clean:
	rm -f $(OBJ) $(TARGET)

# Install the executable (optional)
install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/

# Uninstall
uninstall:
	rm -f /usr/local/bin/$(TARGET)

# Phony targets
.PHONY: all clean install uninstall
