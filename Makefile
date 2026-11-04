PROJECT  = wtrd.lpr
OUTFILE  = wtrd
FPC      = fpc
UNITS    = units
PARAMS   = $(PROJECT) -FU$(UNITS) -MObjFPC -Sc -O1 -gl -vewnhi -l \
           -Fu. -Fu./bluetoothlaz/source/package \
           -o$(OUTFILE)

all: $(OUTFILE)

$(OUTFILE): $(PROJECT) wtr.pas wtr_config.pas notification_filters.pas event_scanner.pas database_watch.pas mail_cache.pas pebble_protocol.pas bluetoothlaz/source/package/bluetooth.pas
	@mkdir -p $(UNITS)
	$(FPC) $(PARAMS)

clean:
	rm -f $(OUTFILE) $(OUTFILE).o wtr.o
	rm -rf $(UNITS)

test: $(OUTFILE)
	./$(OUTFILE) --test-sms "Alice" "Hello from the test mode"

check:
	FPC="$(FPC)" python3 tests/run.py

.PHONY: all clean test check
