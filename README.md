# Ripple — Watch the Ripple

Ripple is a Pebble watch companion for Maemo Leste, written in Free Pascal.
It forwards incoming rtcom messages and Modest IMAP email notifications over
Bluetooth Classic RFCOMM, supports notification filters, and handles watch
music controls through OSCP or MAFW.

The package is named `ripple`. Its executables are `ripple`, the graphical
watch-app manager, `wtrd`, the notification daemon, and `wtr`, the user
control command.

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

## Watchfaces and watch apps

Open **Ripple** from the application menu, or run `ripple` as the desktop user.
Controls are created at runtime with Lazarus LCL/GTK2, including Hildon portrait
mode support.

1. Set the Bluetooth address in `wtr.conf` using the setup instructions above.
2. Select **Detect watch** to read its firmware and hardware platform.
3. Select **Watchfaces** or **Watch apps** to browse Rebble's featured catalog.
   The **Gallery** shows nine screenshot cards per page, arranged in one to three
   columns according to the window width. Use **Previous** and **Next** to change
   pages, or **List** for a compact view. Enter a name and press **Search** to find
   older entries; clear the search field and search again to return to featured
   items. Featured hardware filtering uses the last detected platform; until
   detection, the catalog is unfiltered. Search can show incompatible apps,
   which are marked and cannot be installed for the detected watch.
4. Choose **Details** on a card or select a list entry to read its description,
   version, capabilities, and configuration/location warnings. Use **<** and **>**
   to browse its screenshots. Choose **Install** to download the PBW, check its
   platform, sizes, and CRCs, and transfer it to the watch. On firmware 3 and
   later, Ripple queries the watch's app-run state and reports success only after
   confirming that the selected app or watchface has launched.
5. Select **Installed / Ripple records** to view app entries and select **Remove**
   to remove one from the watch.

To remove an app installed by another companion, find the same app in the catalog,
open its details, and select **Remove**. Ripple sends its UUID to the watch after
confirmation, even without a saved registration. Catalog details do not indicate
whether an app is currently installed.

Network and watch operations run in a worker thread. Watch access temporarily
stops the managed `wtrd` and restarts it afterwards only if it was running before.
Notifications pause during that interval. Close any manually started companion
before using watch controls, and avoid running `wtr start` during a transfer.
Ripple confirms that the daemon has stopped before connecting and retries a
busy RFCOMM channel briefly while the previous connection is being released.
Catalog searches, app details, and screenshot downloads leave the notification
daemon running. Screenshots load in the background with a bounded in-memory
cache; changing pages discards obsolete preview requests.

Firmware 2 uses a live app-bank inventory. With firmware 3 and later, Ripple uses
BlobDB app registration and AppFetch transfers. Its app list shows saved
registration records for the configured Bluetooth address. Apps installed by another companion are
absent; records can become stale after a watch reset or removal elsewhere.
A failed transfer can leave an app registration, which can be removed from the
records view and then installed again. Each record's details distinguish a
confirmed launch from an unconfirmed registration. Launch confirmation is
recorded at installation time and does not establish the app's current state.

Ripple transfers app binaries, resources, and optional workers. Phone-side
PebbleKit JavaScript and app configuration pages are unsupported, so apps needing
them may have limited functionality. Weather faces may need JavaScript for
ongoing updates as well as API-key configuration. The daemon does not currently
serve later AppFetch requests after firmware evicts an app binary from its cache;
reinstall the app through Ripple if it needs fetching again. Watch operations require
device testing for each supported model and firmware.

UI settings are stored beside `wtr.conf` in `ripple.ini`; registration records
are stored in `apps-<Bluetooth-address-without-colons>.ini`.

## Music controls and time

`[media] use_oscp = True` uses OSCP's now-playing file and control FIFO.
`False` uses MAFW through `dbus-send`. The media player must support the selected
interface. OSCP is a separate application and is not installed by Ripple.

Watch time is set on connection. The legacy `process_sleep` and `time_sleep`
settings are accepted but do not schedule periodic updates. Incoming-call
notifications are not implemented.

## Diagnostics

`wtr status` reports whether the managed daemon process is running. Watch
connection attempts and errors appear in `wtr log`. After a graphical watch
operation, the daemon may already have reconnected, even if that operation failed.
When launched from a terminal, the graphical `ripple` application prints its
transfer phases, app IDs, and results there; these messages are separate from
the daemon's log.

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
`fp-units-base`, `fp-units-fcl`, `fp-units-db`, `fp-units-net`, `fp-units-gtk2`,
`lcl-gtk2`, `lcl-units`, and `libbluetooth-dev`. The LCL packages provide the
compiled GTK2 and LazUtils units. Tests additionally require Python 3. The
required BluetoothLaz binding is included under `third_party/`.
HTTPS uses FPC's `TFPHTTPClient` and `gnutlssockets`, with the system CA bundle
and GnuTLS certificate/hostname verification; runtime packages include
`ca-certificates` and `libgnutls30`.

```sh
make
make check
```

`make ripple` builds just the graphical app; `make wtrd` builds just the daemon.
The Makefile detects Lazarus under `/usr/lib/lazarus/<version>` or
`/usr/share/lazarus`; use `make LAZARUS=/path/to/lazarus` for another location.
Unit output is separated into `build/ui-units` and `build/units`.

`make install DESTDIR=... PREFIX=/usr` stages the executables, example config,
session hook, Hildon desktop entry, and icon. Debian packaging is under `debian/`;
a local binary-package build can use `dpkg-buildpackage -b -us -uc` once its build dependencies are
installed. `DEB_BUILD_OPTIONS=nocheck` skips tests in Debian builds.

Development sources use the `main` branch. The Forgejo package workflow runs
on pushes to `maemo/**` branches and pull requests targeting those branches,
delegating to the shared Maemo Leste workflow. Packaging targets
`maemo/excalibur`; `debian/gbp.conf` selects upstream tags matching the upstream
version, such as `0.1.0`. The package version comes from `debian/changelog`;
changing the changelog is separate from triggering the workflow.

## License and credits

Ripple is a Free Pascal reimplementation of Maebble by Par Olsson. Maebble
credits Liam McLoughlin's Libpebble work and SMS parsing by Thibault Cohen and
Stefan Siegl. Ripple is distributed under GPL-3.0-or-later; see `COPYING`.
The vendored BluetoothLaz binding by Mattias Gaertner is LGPL-2.0-or-later
with a linking exception; its licenses and source provenance are included
under `third_party/bluetoothlaz/`.
