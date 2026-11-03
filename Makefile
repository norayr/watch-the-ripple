PROJECT  = maebbled.lpr
OUTFILE  = maebbled
FPC      = fpc
UNITS    = units
PARAMS   = $(PROJECT) -FU$(UNITS) -MObjFPC -Sc -O1 -gl -vewnhi -l \
           -Fu. -Fu./bluetoothlaz/source/package \
           -o$(OUTFILE)

all: $(OUTFILE)

$(OUTFILE): $(PROJECT) maebble.pas bluetoothlaz/source/package/bluetooth.pas
	@mkdir -p $(UNITS)
	$(FPC) $(PARAMS)

clean:
	rm -f $(OUTFILE) $(OUTFILE).o maebble.o
	rm -rf $(UNITS)

test: $(OUTFILE)
	./$(OUTFILE) --test-sms "Alice" "Hello from the test mode"

.PHONY: all clean test

