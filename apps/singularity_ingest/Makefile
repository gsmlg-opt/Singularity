CC ?= cc
CFLAGS ?= -O2

PRIV_DIR := $(MIX_APP_PATH)/priv
GUARDIAN := $(PRIV_DIR)/poppler_guardian
SOURCE := c_src/poppler_guardian.c

.PHONY: all clean

all: $(GUARDIAN)

$(GUARDIAN): $(SOURCE)
	mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -std=c11 -Wall -Wextra -Werror -o $@ $<

clean:
	rm -f $(GUARDIAN)
