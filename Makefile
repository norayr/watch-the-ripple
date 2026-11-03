

all:
		fpc -FUunits -Fu./bluetoothlaz/source/package maebbled.lpr

test:
		./maebbled --test-sms "Alice" "Hello from the test mode"
