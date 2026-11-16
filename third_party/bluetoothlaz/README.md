# BluetoothLaz binding

`bluetooth.pas` is copied without modification from BluetoothLaz:

- Upstream: https://github.com/afriess/bluetoothlaz
- Commit: `882d16ded7be9604ced1765c7380f6d1e2cea590`
- Original path: `source/package/bluetooth.pas`
- Author: Mattias Gaertner
- License: LGPL version 2 or later, with the linking exception in the source
  header and `COPYING.modifiedLGPL.txt`

Ripple uses this binding for its existing BlueZ RFCOMM transport. Both upstream
license files are included. Debian source packages contain the binding and do
not need to fetch a submodule during compilation.
