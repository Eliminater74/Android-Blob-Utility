
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

NAME   = android-blob-utility
SRC    = $(NAME).c
HDR    = $(NAME).h

# MODULE may be overridden by the caller (e.g. MODULE=android-blob-utility.exe)
# without affecting the header dependency, which is always $(HDR).
MODULE ?= $(NAME)

all: $(MODULE)

$(MODULE): $(SRC) $(HDR)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

# Cross-compile for Windows using MinGW (Linux host only)
windows:
	$(MAKE) CC=x86_64-w64-mingw32-gcc MODULE=$(NAME).exe

install: $(NAME)
	install -m 755 $(NAME) /usr/local/bin/

uninstall:
	rm -f /usr/local/bin/$(NAME)

clean:
	-rm -f $(NAME) $(NAME).exe

.PHONY: all windows install uninstall clean
