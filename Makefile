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

ARCH     ?= $(shell $(FPC) -iTP)-$(shell $(FPC) -iTO)
LAZARUS  ?= $(firstword $(wildcard /usr/lib/lazarus/* /usr/share/lazarus))
UI_UNITS = build/ui-units
UI_PARAMS = ripple.lpr -FU$(UI_UNITS) $(FPCFLAGS) -Fl$(GCC_LIBDIR) \
            -Fu. -Fuui -Futhird_party/bluetoothlaz \
            -Fu$(LAZARUS)/components/lazutils/lib/$(ARCH) \
            -Fu$(LAZARUS)/lcl/units/$(ARCH) \
            -Fu$(LAZARUS)/lcl/units/$(ARCH)/gtk2 \
            -Fu$(LAZARUS)/packager/units/$(ARCH) -dLCL -dLCLGTK2 -oripple

all: $(OUTFILE) ripple

ripple: ripple.lpr MainForm.pas $(wildcard ui/*.pas) wtr_config.pas Makefile
	@mkdir -p $(UI_UNITS)
	$(FPC) $(UI_PARAMS)

$(OUTFILE): $(PROJECT) wtr.pas wtr_config.pas notification_filters.pas event_scanner.pas database_watch.pas mail_cache.pas pebble_protocol.pas third_party/bluetoothlaz/bluetooth.pas
	@mkdir -p $(UNITS)
	$(FPC) $(PARAMS)

clean:
	rm -f $(OUTFILE) $(OUTFILE).o wtr.o
	rm -rf $(UNITS)
	rm -f ripple
	rm -rf $(UI_UNITS)

test: $(OUTFILE)
	./$(OUTFILE) --test-sms "Alice" "Hello from the test mode"

check:
	FPC="$(FPC)" python3 tests/run.py
	FPC="$(FPC)" python3 tests/test_control.py
	LAZARUS="$(LAZARUS)" FPC="$(FPC)" python3 tests/test_ui.py

install: $(OUTFILE) ripple
	install -D -m 0755 $(OUTFILE) $(DESTDIR)$(PREFIX)/bin/wtrd
	install -D -m 0755 scripts/wtr $(DESTDIR)$(PREFIX)/bin/wtr
	install -D -m 0755 ripple $(DESTDIR)$(PREFIX)/bin/ripple
	install -D -m 0644 data/ripple.desktop $(DESTDIR)$(PREFIX)/share/applications/hildon/ripple.desktop
	install -D -m 0644 pebble.png $(DESTDIR)$(PREFIX)/share/pixmaps/ripple.png
	install -D -m 0644 wtr.conf $(DESTDIR)$(PREFIX)/share/ripple/wtr.conf
	install -D -m 0644 data/90ripple $(DESTDIR)/etc/X11/Xsession.d/90ripple

.PHONY: all clean test check install
