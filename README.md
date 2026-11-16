# Ripple — Watch the Ripple

Ripple is a Pebble watch companion for Maemo Leste, written in Free Pascal.
It forwards incoming rtcom messages and Modest IMAP email notifications over
Bluetooth Classic RFCOMM, supports notification filters, and handles watch
music controls through OSCP or MAFW.

The package is named `ripple`. Its executables are `wtrd`, the daemon, and
`wtr`, the user control command.

## Install and pair

With a Maemo Leste repository providing Ripple enabled, install it through
Application Manager or run as root:

```sh
apt install ripple
```

Pair the watch in Maemo's Bluetooth settings first. Confirm the pairing code
on both devices, and note the watch's Bluetooth address. Alternatively, use
`bluetoothctl` with a pairing agent. The watch should be nearby, with Bluetooth
enabled and no other companion holding its connection.

The transport requires Bluetooth Classic RFCOMM. Pebble 2 requires BLE and is
not supported by this transport. Other models and firmware versions need
testing; successful Bluetooth pairing alone does not establish compatibility.

## Configure as the desktop user

Run these commands as the normal desktop user, without `sudo`:

```sh
wtr init
```

This prints the configuration filename, normally `~/.config/wtr/wtr.conf`.
Edit it and set the paired watch's address:

```ini
[btservice]
address = AA:BB:CC:DD:EE:FF
connect_sleep = 30
```

The example installed at `/usr/share/ripple/wtr.conf` has an empty address.
`wtr init` preserves an existing configuration and imports
`~/.config/maebble/maebble.cfg` if the new file does not exist.
`XDG_CONFIG_HOME` is supported. Configuration changes take effect after restart.

Ripple reads the desktop user's message database, Modest cache, media files,
and session environment. It should run as that user, not as a root service.
Installation does not create or change files in the user's home directory.

## Start and stop

```sh
wtr start
wtr status
wtr log
wtr stop
wtr restart
```

The managed daemon logs to `~/.cache/ripple/wtrd.log`, respecting
`XDG_CACHE_HOME`. One previous log is retained when starting it again.
PID and control-lock files use `$XDG_RUNTIME_DIR/ripple` when available,
otherwise the cache directory. Controls operate only on the managed process;
do not run a second `wtrd` manually while it is active.

To start Ripple automatically at graphical login:

```sh
wtr enable
wtr start
```

The package's `/etc/X11/Xsession.d/90ripple` hook checks the user's opt-in
setting and launches Ripple in that user's session. A home-screen widget is
not required. To disable future automatic starts:

```sh
wtr disable
wtr stop
```

Disabling startup does not stop an already running daemon. Automatic startup
is disabled until the user enables it.

## Messages and email

Incoming messages are read from `$HOME/.rtcom-eventlogger/el-v1.db`. New incoming
events with nonempty text are forwarded; outgoing events are skipped. SMS
forwarding depends on the phone's messaging stack recording SMS in this database.

Email is detected from numbered Modest IMAP cache files under
`$HOME/.modest/cache/mail/imap/*/folders/INBOX/`. Accounts are discovered
automatically. Notifications contain sender and subject, including common MIME
encoded headers; email bodies are not forwarded. Lowercase inbox names are
also recognized.

Existing messages and cached mail are skipped at startup. Pending items are
retried after reconnect while they remain in the database or cache. Delivery
and filter state are kept in memory; a successful socket write does not
guarantee display on the watch. Cache resynchronization can introduce messages
that are new to the local cache but are not newly received on the server.

Optional email settings:

```ini
[email]
enabled = True
fallback_seconds = 300
```

`cache_directory` can override the IMAP cache root. Database and email watchers
use inotify with safety rescans; they do not continuously execute helper
processes. `[notifications] fallback_seconds` defaults to 30. Both fallback
intervals accept 1–86400 seconds.

## Notification filters

Each `[filter.NAME]` section defines a rule. Rules are checked in file order;
the first match decides the action. All supplied conditions must match:

- `body_contains`: a literal substring, ignoring ASCII letter case. For email,
  this matches the displayed subject, not the body.
- `sender`: an exact remote UID or email sender address, not a display name.
- `channel`: an exact event-log channel, or `email:ACCOUNT` for cached mail.

Specify at least one condition. `action = ignore` suppresses all matches.
`action = once_per_contact` shows the first match for each sender/channel.
`cooldown_seconds = 0` suppresses further matches until restart; a positive
value permits another notification after that many seconds. Different bodies
matching the same rule share its contact history. Unmatched messages pass through.

```ini
[filter.omemo]
body_contains = OMEMO encrypted
action = once_per_contact
cooldown_seconds = 0
```

Set `cooldown_seconds = 3600` for hourly reminders, or change the action to
`ignore` for complete suppression. Use a distinctive warning fragment to avoid
filtering ordinary conversations. `enabled = false` disables a rule.

## Music controls and time

`[media] use_oscp = True` uses OSCP's now-playing file and control FIFO.
`False` uses MAFW through `dbus-send`. The media player must support the selected
interface. OSCP is a separate application and is not installed by Ripple.

Watch time is set on connection. The legacy `process_sleep` and `time_sleep`
settings are accepted but do not schedule periodic updates. Incoming-call
notifications and full watch application management are not implemented.

## Diagnostics

Stop the managed daemon before running a foreground session or a smoke test:

```sh
wtr stop
wtrd --verbose
```

After stopping the foreground session with Ctrl+C:

```sh
wtrd --test-sms "Test sender" "Test message"
wtrd --test-email "Test sender" "Test subject" "Test body"
wtr start
```

These explicit tests bypass notification filters. Use normal incoming messages
after startup to test detection and filtering. Verbose output contains message
contents. A `btmon` capture can also contain Bluetooth pairing keys; keep it
private and redact secrets before sharing excerpts.

Connection errors may need controller-level diagnosis. HCI Page Timeout means
the radio connection could not be established; repeated local HCI command
timeouts can indicate a controller, firmware, or driver problem. Do not delete
pairing information solely because a connection attempt timed out.

## Build and package

On Debian/Devuan, build dependencies include `make`, `gcc`, `fp-compiler`,
`fp-units-base`, `fp-units-fcl`, `fp-units-db`, and `libbluetooth-dev`.
Tests additionally require Python 3. The required BluetoothLaz binding is
included under `third_party/`; no Lazarus IDE or submodule download is required.

```sh
make
make check
```

`make install DESTDIR=... PREFIX=/usr` stages the executables, example config,
and session hook. Debian packaging is under `debian/`; a local binary-package
build can use `dpkg-buildpackage -b -us -uc` once its build dependencies are
installed. `DEB_BUILD_OPTIONS=nocheck` skips tests in Debian builds.

The Forgejo workflow delegates to the shared Maemo Leste workflow. Packaging
targets the `maemo/excalibur` branch; `debian/gbp.conf` selects upstream tags
matching the upstream version, such as `0.1.0`.

## License and credits

Ripple is a Free Pascal reimplementation of Maebble by Par Olsson. Maebble
credits Liam McLoughlin's Libpebble work and SMS parsing by Thibault Cohen and
Stefan Siegl. Ripple is distributed under GPL-3.0-or-later; see `COPYING`.
The vendored BluetoothLaz binding by Mattias Gaertner is LGPL-2.0-or-later
with a linking exception; its licenses and source provenance are included
under `third_party/bluetoothlaz/`.
