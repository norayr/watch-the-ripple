PROJECT  = wtrd.lpr
OUTFILE  = wtrd
FPC      = fpc
UNITS    = build/units
PREFIX   ?= /usr
DESTDIR  ?=
GCC_LIBDIR := $(dir $(shell $(CC) -print-file-name=crtbegin.o))
FPCFLAGS ?= -MObjFPC -Sc -O1 -gl -vewnhi -l
PARAMS   = $(PROJECT) -FU$(UNITS) $(FPCFLAGS) -Fl$(GCC_LIBDIR) \
           -Fu. -Fu./third_party/bluetoothlaz \
           -o$(OUTFILE)

all: $(OUTFILE)

$(OUTFILE): $(PROJECT) wtr.pas wtr_config.pas notification_filters.pas event_scanner.pas database_watch.pas mail_cache.pas pebble_protocol.pas third_party/bluetoothlaz/bluetooth.pas
	@mkdir -p $(UNITS)
	$(FPC) $(PARAMS)

clean:
	rm -f $(OUTFILE) $(OUTFILE).o wtr.o
	rm -rf $(UNITS)

test: $(OUTFILE)
	./$(OUTFILE) --test-sms "Alice" "Hello from the test mode"

check:
	FPC="$(FPC)" python3 tests/run.py
	FPC="$(FPC)" python3 tests/test_control.py

install: $(OUTFILE)
	install -D -m 0755 $(OUTFILE) $(DESTDIR)$(PREFIX)/bin/wtrd
	install -D -m 0755 scripts/wtr $(DESTDIR)$(PREFIX)/bin/wtr
	install -D -m 0644 wtr.conf $(DESTDIR)$(PREFIX)/share/ripple/wtr.conf
	install -D -m 0644 data/90ripple $(DESTDIR)/etc/X11/Xsession.d/90ripple

.PHONY: all clean test check install
