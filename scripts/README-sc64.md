# ares SC64 fork

This is an unofficial ares fork with experimental SummerCart64 emulation.
It contains emulator changes only. Supply your own ROM and, if needed, a
separate local bridge. The emulator does not know a game server address.
SC64 is disabled by default; its TCP port defaults to zero (disabled).

## Source provenance

- Fork base: ares `4cb8d92b441557cb6bcaf133c4cbc7f6819b1122`.
- SC64 core/UI integration: Christopher Bonhage (meeq),
  [upstream proposal #2601](https://github.com/ares-emulator/ares/pull/2601),
  pinned [source `cc89b1c88e22b0f5696ce1f4bb2f1754780b9891`](https://github.com/meeq/ares/tree/cc89b1c88e22b0f5696ce1f4bb2f1754780b9891).
  Imported the proposal delta from common base
  `b80f67d38312648d197762121c3a27b02c0887db`; newer fork-base core fixes remain.
  The proposal's changes to shared nall TCP sockets were intentionally excluded.
- Fork additions: an SC64-only loopback transport, bounded queues and command
  dispatch, memory-read validation before allocation, tests, isolated launcher,
  and Windows build instructions. Shared GDB/debugger socket behavior is unchanged.
- Protocol references: SummerCart64
  [v2.20.2 USB interface](https://github.com/Polprzewodnikowy/SummerCart64/blob/v2.20.2/docs/03_usb_interface.md)
  and its [remote TCP framing](https://github.com/Polprzewodnikowy/SummerCart64/blob/v2.20.2/sw/deployer/src/sc64/link.rs).

The previously tested build came from that pinned source archive; no later
emulator FIFO patch was evidenced. This fork preserves the proposal's FIFO
command ordering while bounding storage and work. Protocol behavior must be
validated separately from any particular game's performance.

## Windows build

Requires Git, CMake 3.28+, Visual Studio 2022 with the C++ desktop workload and
Windows SDK. From a checked-out commit:

```powershell
./scripts/build-sc64.ps1 -BuildDirectory C:/build/ares-sc64 -Jobs 4
```

The script uses Release x64, `ARES_CORES=n64`, `ARES_BUILD_LOCAL=OFF`
(the upstream generic CPU baseline check), `ARES_BUILD_OFFICIAL=OFF`, static
MSVC CRT (`MultiThreaded`, as in upstream CI), unity core compilation, and no
optional emulator targets. It builds and runs
the standalone SC64 transport tests. At most four parallel build jobs are
accepted. `-SkipTests` is for repeat packaging after tests have already run.
CMake downloads dependencies pinned by version and SHA-256 in `deps.json`.
Keep that manifest and record the compiler/SDK when reproducing a build; these
steps do not promise identical binary hashes across different toolchains.

The runtime is `C:/build/ares-sc64/desktop-ui/rundir`. Distribute the whole runtime,
including its DLLs, `LICENSE`, dependency `licenses/`, `deps.json`, existing
shader notices/source, launcher, this document and `sc64-build.json`. The manifest records the checkout state, compiler, SDK and executable hash.
Do not distribute a dirty build as though it came only from its recorded commit.
The source tree retains upstream license notices, third-party licenses and
source. Matching prebuilt dependencies are `2026-05-30`, Windows x64, SHA-256
`e14e3d44909194cf7aa0a9dbf9693b5f74b34162b15d69c34ed05d709808c6a8`.
Their corresponding source is available from the upstream release:
[ares-deps-windows-x64-source.tar.xz](https://github.com/ares-emulator/ares-deps/releases/download/2026-05-30/ares-deps-windows-x64-source.tar.xz),
SHA-256 `8082df53fd6f062829cb0038cfb6773df30094fa591e286b2c00aab344a9b480`.
The unmodified librashader library uses MPL-2.0; see `LICENSE` and that matching
source archive. Keep notices and these source references with redistributions;
retain corresponding source when publishing your own modified dependencies. This build script does
not grant a license to ROMs, firmware, or game assets.

## Isolated local use

From the runtime directory:

```powershell
./Run-SC64.ps1 -Rom C:/games/example.z64 -UserDirectory ./SC64-user -UsbPort 9064
```

This launcher explicitly opts into SC64 on **127.0.0.1 only**. It creates private
settings, Systems, Firmware, Saves, Screenshots and Debugging directories. It
sets each corresponding `Paths/...` override, so a different ares installation's
settings/saves are not selected by default. `--settings-file` alone would not
isolate those other locations. The launcher also clears the SD image setting;
it does not mount a prior image from saved settings. `-Check` prints arguments
without launching or creating directories. For a second instance, use a different
user directory and port. Choose writable user directories that you own.

A bridge connects to `127.0.0.1:9064`; do not expose or forward this port through
a firewall/router. The local endpoint permits emulator memory/configuration
commands and is not authenticated. Network access to a game server belongs in
a separate bridge. A normal direct launch of `ares.exe` retains upstream
behavior with SC64 disabled unless you explicitly enable it.

Supported transport framing is both direct `CMD`/`CMP`/`ERR`/`PKT` and SC64
remote TCP envelopes. Transport errors and overflow close the client and clear
its framing/USB queues; reconnect starts a fresh stream. There is one active
client. Receive/send work is capped at 64 KiB per emulator poll, at most 64
commands per poll, outgoing and pre-handshake queues at 64 frames and
16 MiB + 32 KiB, and input at 16 MiB + 17 + 64 KiB. Memory transfers are capped
at 16 MiB per command; larger operations need multiple commands. Complete
outgoing frames are retained through partial writes. Command dispatch waits
for response byte/frame capacity before consuming input; it resumes when the
peer drains output. No transport worker thread
survives close/reopen. Polling pauses when the emulator itself is paused.

Save-state identifier `sc64-akina-1` deliberately rejects upstream and older
experimental save states. SC64 SDRAM and USB session state are not fully
serialized, so do not use save states as transport/session recovery. Ordinary
cartridge save files remain the existing format. USB save writeback and 64DD
disk mapping are not implemented, although the inherited protocol acknowledges
the corresponding commands. Do not treat an acknowledgment as saved data.

## Tests

The native regression executable tests the actual socket implementation:
loopback bind, occupied-port rejection, byte-exact partial delivery/backpressure,
bounded queues, per-poll work, disconnect/reconnect and immediate close/reopen.
It needs no ROM. Run independently with:

```powershell
cmake -S tests/sc64 -B C:/build/sc64-tests -G 'Visual Studio 17 2022' -A x64
cmake --build C:/build/sc64-tests --config Release --parallel 4
ctest --test-dir C:/build/sc64-tests -C Release --output-on-failure
```

For parser/memory regressions against a running, unpaused emulator with SC64
enabled, use `python tests/sc64/protocol.py --port PORT`. Use a disposable ROM
session and no competing bridge: the tests deliberately disconnect clients,
write the cartridge's temporary MCU buffer, and send malformed requests.
These checks do not establish real-console compatibility or game performance.
