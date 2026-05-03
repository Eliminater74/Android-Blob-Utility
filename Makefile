
BUILD_WITH_READLINE := false
VARIABLES_PROVIDED := false

CC     ?= gcc
CFLAGS += -Wall -Wextra

ifeq ($(BUILD_WITH_READLINE), true)
	CFLAGS  += -DUSE_READLINE
	LDFLAGS += -lreadline
endif

ifeq ($(VARIABLES_PROVIDED), true)
	CFLAGS += -DVARIABLES_PROVIDED
endif

MODULE = android-blob-utility
SRC    = android-blob-utility.c

all: $(MODULE)

$(MODULE): $(SRC) $(MODULE).h
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

# Cross-compile for Windows using MinGW (Linux host only)
windows:
	$(MAKE) CC=x86_64-w64-mingw32-gcc MODULE=android-blob-utility.exe

install: $(MODULE)
	install -m 755 $(MODULE) /usr/local/bin/

uninstall:
	rm -f /usr/local/bin/$(MODULE)

clean:
	-rm -f $(MODULE) $(MODULE).exe

.PHONY: all windows install uninstall clean
