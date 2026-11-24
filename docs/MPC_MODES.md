# MPC modes: the `ModeID` table and the "empty mode slots" 0x2090, 0x2092, 0x2099

**[F, 2026-11-21, offline, from the binary, not run on a device.]** Everything here was read from Akai's stock `MPC` binaries by
static analysis (scripts outside the repo, below). Nothing was run on a device. Addresses are virtual addresses in the stated build.
"Confirmed" means read from the code or data; "guess" is marked.

Background: a post in the Hakai custom-firmware group lists "Empty MPC Mode Slots: 0x2090, 0x2092, 0x2099" with the caption "Add new
Modes to your MPCs". This page explains what those numbers are and what it would take to use them.

## Builds checked

| Build | Arch | `/usr/bin/MPC` md5 | Mode-name switch | Mode range |
|---|---|---|---|---|
| Gen2 official 3.10.1 (Live III) | aarch64 | `b24b7955d904a5779059287e4793ea0f` | `0x1bed7c0` (table `0x5386fa0`) | 0x2080..0x20a4 |
| Gen2 3.10.1.8 (`38fdde70994`) | aarch64 | `4280be032878fc321b7f58a6801cb1ea` | `0x1bed83c` (table `0x5386f60`) | 0x2080..0x20a4 |
| Gen2 3.10.0 | aarch64 | `15a664f6b6ae591c8b78baae8b376f02` | switch at `0x1bd099c` | 0x2080..0x20a3 |
| Gen2 3.9.1 | aarch64 | `a7ace6a9993df33afeae50571755bbf9` | switch at `0x1b0be1c` | 0x2080..0x20a2 |
| Gen1 3.10.0 | armv7 | `b6cc8e7a398bdf6c3fd8f7176eecd3ee` | `addls pc` at `0x165d770` | 0x2080..0x20a3 |
| Force 3.9.1.2 | armv7 | `592eebc8e1ce0797dc8c98e7002143b8` | `addls pc` at `0x1574c44` | 0x2080..0x20a2 |

Only the official 3.10.1 build was analysed in depth (all four layers below). The other builds were checked for the name table only.
UI resources: Gen2 3.10.0.23 (`/usr/share/Akai/SME0`) and the Force 3.10.1.8 update image. No Gen2 3.10.1 resource tree was available.

## What the numbers are (confirmed)

The engine has a C++ enum, **`ModeID`** (the type name appears in RTTI, e.g. `std::function<std::vector<ModeID>()>` in the
`MpcEnhancements` constructor). It has three ranges:
- `0` = "No Mode"
- **`0x2080..0x20a4`: screen modes** (37 values in 3.10.1)
- `0x3080..0x3112`: popups and windows (147 values, 0x3080 = "No Popup")

`getModeName(ModeID)` (3.10.1: `0x1bed7c0`) is a jump-table switch returning the display name. **0x2090, 0x2092 and 0x2099 are the
only values in the mode range with no case**: they fall through to the default, an empty string. The same holes are in every build
above, including the Force and Gen1 armv7 builds, so they are **not Force-only or Gen2-only modes**. New modes are appended at the end
of the range: 0x20a3 "Activation" was added in 3.10.0 and 0x20a4 "Developer" in 3.10.1. The only rename is 0x2083, "Channel
Mixer" (3.9.1) → "Track Mixer". The holes are most likely **retired IDs** that keep the numbering stable (guess: modes that were
removed or merged in 2.x/3.x), not slots reserved for extensions.

| ID | Name | Controller `Mode` object | Touch page |
|---|---|---|---|
| 0x2080 | Main Mode | yes | own slot |
| 0x2081 | Track Edit | yes | own slot |
| 0x2082 | Pad Mixer | yes | own slot |
| 0x2083 | Track Mixer (3.9.1: Channel Mixer) | yes | own slot |
| 0x2084 | Track View | yes | own slot |
| 0x2085 | Next Sequence | yes | own slot |
| 0x2086 | Sampler | yes | own slot |
| 0x2087 | Sample Edit | yes | own slot |
| 0x2088 | Song | yes | own slot |
| 0x2089 | Arrange | yes | own slot |
| 0x208a | Q-Link Edit | yes | own slot |
| 0x208b | Fx Mode | yes | dummy page (guess: shown as an overlay) |
| 0x208c | Pad Mute | yes | own slot |
| 0x208d | Track Mute | yes | own slot |
| 0x208e | Step Sequencer | yes | own slot |
| 0x208f | XYFX | yes | own slot |
| **0x2090** | **(none)** | **no** | **dummy page** |
| 0x2091 | Browser | yes | own slot |
| **0x2092** | **(none)** | **no** | **dummy page** |
| 0x2093 | Pad Color | yes | own slot |
| 0x2094 | List Edit | yes | own slot |
| 0x2095 | MIDI Control | yes | own slot |
| 0x2096 | MIDI Learn | no | own slot |
| 0x2097 | Looper | yes (`LooperMode`) | own slot |
| 0x2098 | Power On | yes | own slot |
| **0x2099** | **(none)** | **no** | **dummy page** |
| 0x209a | Control | yes | own slot |
| 0x209b | Startup Wizard | yes | own slot |
| 0x209c | Clip Matrix | yes | own slot |
| 0x209d | Navigate | yes | own slot |
| 0x209e | Clip Editor | yes | shares a slot with Grid View |
| 0x209f | Grid View | yes | shares a slot with Clip Editor |
| 0x20a0 | Sounds | yes | own slot |
| 0x20a1 | Key Ranges | yes | own slot |
| 0x20a2 | Input | yes | own slot |
| 0x20a3 | Activation | no | dummy page |
| 0x20a4 | Developer | yes | own slot (`TouchDeveloperPanelPage`, guess) |

Popup-range holes (no name) in 3.10.1: 0x30b6, 0x30c7, 0x30df, 0x30e6, 0x3104, 0x3105, 0x3106.

## How a mode is wired (3.10.1 `b24b7955`, confirmed unless marked)

A mode is four separate pieces of compiled code. None of them is data-driven.

1. **Name.** `getModeName` `0x1bed7c0`: `id==0` → "No Mode"; `0x2080..0x20a4` → halfword table `0x5386fa0`; `0x3080..0x3112` →
   table `0x5386e78`; anything else → empty. `nameToModeId` `0x1bee9e0` loops `id = 0..0x3112`, calls `getModeName` and compares
   strings, so **an ID is addressable by name only if `getModeName` returns a name for it**. The Lua `engineMode.RequestModeChange`
   (binding `0x2fd3d40`) and `GetAvailableModes` both go through names.
2. **Controller behaviour** (pads, buttons, Q-Links, LEDs). One function (the registrar, the 68 calls at `0x1631058..0x1631494`)
   creates the `*Mode` objects (RTTI: `LooperMode`, `PadMuteMode`, `StepSequenceMode`, `QLink*Mode`, ...) and inserts each with
   `0x1beab20(manager, id, Mode*)`: a `std::map<int, Mode*>` at `manager+0x158` (node key `+0x20`, value `+0x28`). These 68 calls are
   the only callers of the insert. The three holes, MIDI Learn and Activation are not inserted. The availability check `0x1beafc0(id)`
   looks the ID up and **returns 1 (available) when there is no entry**, otherwise it calls `Mode::vfunc[+0x10]`.
   The engine keeps the current mode at `+0x80` and the current popup at `+0xd8` of the object at `[...+0xa0]`.
3. **Touch page.** The touch-UI root constructor `0x388c3d0` creates every `Touch*Page` eagerly (e.g. `TouchMainPage` at
   `root+0xad8`, `TouchTrackViewPage` at `root+0x1118`), each with a 0x320-byte holder right after it (`0x3887da4(holder, page)`).
   The mode-change handler `0x38895cc` maps the new `ModeID` to a holder: `id-0x2080 <= 0x24` → halfword table `0x6712c58` (base
   `0x3889800`), anything else → the **`TouchDummyPage`** holder at `root+0x6268`. **The three holes map to the dummy page**, as
   do Fx Mode and Activation.
4. **Entry point.** The MENU grid is `TouchModeMenuGrid` and the tile order is `ModeMenuOrder` (settings keys `ModeMenuPage`,
   `ModeMenuNumPages`). A static 23-entry `ModeID` list at `0x537f338` (built at `0xc9dffc`) holds the user-facing modes and none of
   the holes. Hardware mode buttons go through other `ModeID` lists (`0x66f8060`, `0x5340df0`). How the grid builds its tile list was
   not traced.

Also seen (confirmed):
- **0x2090 is not completely dead.** It is still a member of one "sequencer family" set, tested as a bitmask (`0x13331` over
  `id-0x2080`: Main, Track View, Next Sequence, Song, Arrange, Pad Mute, Track Mute, 0x2090) at `0x16352c4` and
  `0x1651dac..0x1651f14`. 0x2092 and 0x2099 appear in no mask and are never loaded as an immediate anywhere in `.text`.
- Other `movz #0x2090` hits (9) are struct offsets or unrelated bit masks, not mode IDs.
- Other per-mode switches (e.g. `0x1e3ac1c`, which returns a per-mode member, default `+0xb8`) send the holes to their default case.

## JSON and JS resources

- `SME0/Resources/Pages` (Program Edit panels and the generic knob/slider/menu/text overlays) and `Resources/ACVS/layout` hold no
  `ModeID` values and do not define modes (checked in Gen2 3.10.0.23 and Force 3.10.1.8). **A mode cannot be added by shipping JSON.**
- 3.10.1 embeds **Hermes** (Facebook's JS engine, JSI) and a `TouchJSUIPage`. Its runtime looks for `Resources/jsui`, compiles `*.js`
  with `hermesc -commonjs -emit-binary` to `binary.hbc` (or loads one), and exposes `__JSUINative__` with `dataModelGetState`,
  `dataModelGetStateJSON`, `dataModelCallAction`, `dataModelPatch`, `dataModelReload`, `interceptClickEvents` and `onKeyPress`.
  In stock 3.10.1, however, **nothing constructs a `TouchJSUIPage`**: its constructor `0x370bde0` has no branch, call or address
  reference. The Force 3.10.1.8 rootfs ships no `Resources/jsui`. The scripting layer also has a JS registrar
  (`Scripting::ThreadBasedRegistrar<JSRegistrar>`) next to Lua. This is a dormant lead, not a working route.

## How "custom modes" are probably done today (from Hakai's public deploy script, not their code)

Hakai's Gen2 deploy script (`hakai-deploy-3101.sh`) installs an `LD_PRELOAD` library, `hakai_menu_v3.so`. It has one build per MPC
build, chosen by sha256 (3.9.1.2, 3.10.0.23, 3.10.0.42), and the script says it "must fail closed" on unknown firmware and uses a
"masked-signature resolver". MPC counts as ready when the library's log says `H5 pre-populate: registered`. The library itself was not
available, so how it registers modes is unknown. The shape fits the layers above: hook the name, register a page, add a MENU tile.

## Feasibility (judgement, offline)

| Goal | Rating | Why |
|---|---|---|
| A slot that shows its name and can be entered (Lua `RequestModeChange`, MENU tile) | **medium** | One hook on `getModeName` makes the ID addressable. The availability check already says yes (no map entry). The page would be the dummy page. Unknown: what pads and buttons do with no `Mode` object (null use? ignored?), and how the MENU grid builds its tiles. |
| Its own screen | **medium (overlay) / low (native page)** | A native `TouchPage` subclass means building against MPC's private, stripped JUCE classes (unknown vtable layout, per build). An overlay drawn above the dummy page while `currentMode == slot` reuses the Force Shadow technique and needs only the current-mode read. |
| a. New sequencer mode (screen, touch, pads, steps) | **low** | All of the above, plus a `Mode` object for pad/step handling (no public ABI) and sequence data. Lua scripts cannot read events (FINDINGS, push2-force); the only known route is a build-specific hook. A large, per-build reverse-engineering effort that breaks on every update. |
| b. Plugin Manager page inside MPC | **low value** | Our Plugin Manager already runs inside MPC, as a VST2 plugin with its own touchscreen skin: install, update, remove, restart, no SSH or stick after the first install. A mode would add a MENU tile instead of a track slot, at the cost of a per-build binary hook running in MPC's process. If an entry point is wanted, a Lua device script or an `engineMode` call that opens the plugin's track is cheaper. |
| JSON/resources only | **not possible** | Modes are compiled code, and no resource defines one. |

### Mechanism, per firmware build, and how to undo it
- **`LD_PRELOAD` shim (recommended for a proof of concept).** The same model as `tools/mpc_patch/hwremap` and the addins. Hooks are
  absolute addresses or matched code patterns, so each build needs its table (`getModeName`, `nameToModeId`, the page-switch handler,
  the current-mode field) and must refuse unknown md5s. Undo: remove the preload line or drop-in and restart MPC; the binary is never
  changed. On Gen2, `/etc` is read-only, so it uses the same `/run` drop-in plus Addin Restore path as the addins (NOTES "addins on 3.10.1").
- **Patched binary bound over `/usr/bin/MPC`** (Gen2, like `mpc-drum-pad-patch.sh`). Patching jump tables (`0x5386fa0`, `0x6712c58`) is
  cheap, but there is no code to point the hole cases at without a code cave, and only one bind of `/usr/bin/MPC` can win, so it would
  clash with the drum-pad patch (`94-` drop-in). Undo: remove the drop-in and restart. Worse for this job than a shim.
- **JSON/resource-only:** not available (see above). If the dormant `TouchJSUIPage` were ever wired up by Akai, it would become the
  natural route.

## Proof of concept: the Mode Slot addin (now in open-mpc/plugin-manager, `modeslot/`)

The shim was developed here as `tools/mpc_patch/modeslot` and moved to the Plugin Manager repo on 2026-11-22, where it
ships with the page the Manager's daemon draws (the slot is now called "Plugin Manager"; it was "Open MPC" in the notes
below). An `LD_PRELOAD` shim for 3.10.1 `b24b7955` only. It gates on the GNU build-id (`8b28179d…b837`) plus the exact entry instructions
of every hooked function, so the drum-pad copy (same build-id, changes elsewhere) loads it and any other build is refused.
Hooks, tests and device steps are in its README.

- **v1, device 2026-11-22 (Live III).** It hooked only `getModeName`, which made the slot addressable. Lua `RequestModeChange("Open MPC")`
  entered it and showed `TouchDummyPage`'s picture ("page coming soon"). The mode buttons could not leave it, because no
  controller object is registered for 0x2090.
- **v2, offline 2026-11-22.** It adds four hooks:
  - `registerMode` `0x1beab20` borrows Main Mode's controller, which MPC already shares between Main, Track View, XYFX,
    Clip Matrix, Navigate, Arrange, Clip Editor and Grid View.
  - The touch mode-change handler `0x38895cc` records the current mode.
  - `juce::ImageCache::getFromMemory` `0x11bd880` swaps the placeholder picture for our own PNG while the slot is current. The
    placeholder is a 1280×800 PNG at `0x5a3b200`, 208,454 bytes, reached through the pointer at `0x7f83b30`.
    `TouchDummyPage::paint` (`0x3c59b80`) fills the page, gets it with `getFromMemory(ptr, 0x32e46)` and draws it.
  - The MENU icon lookup `0x3a3c4c0` (switch table `0x678dd18`; 70×70 PNG icons; unknown IDs get an empty `juce::Image`)
    returns our icon.
- **MENU grid tiles** live in `MPC.settings` by mode name (`ModeMenuNumPages`, `ModeMenuPage<p>Slot<s>`, popups such as
  "Save" included), so a tile for the slot is a settings entry. The 23-entry ModeID list at `0x537f338` only initialises a
  static vector at `0x8003200` (with a `juce::String` at `0x80031f8`) that no code addresses directly, so it may be a default.

## Method (to repeat on a new build)
Pure Python (`python -I`, capstone from the user site added to `sys.path`), mmap'd binary, no full-text disassembly. Memory stayed
well under 1 GB (CV_OUTPUTS.md, "Static analysis").
1. Bit-pattern scan of `.text` words for `movz w,#imm` in 0x2070..0x20bf, for `movn w,#-0x2080` (the switch normalisation) with the
   following `cmp`/`ldrh|ldrb [table, w, uxtw]`/`adr` (jump tables), and for `mov x,#mask; lsl; tst` bitmask sets.
2. Decode each jump table and resolve the `adrp+add` string in each case (armv7: `sub r,#0x2080; cmp; addls pc,pc,r,lsl#2` and
   `ldr r,[pc,#]; add r,pc,r` literals).
3. Class names: vtable → typeinfo through `R_AARCH64_RELATIVE` relocations in `.rela.dyn`, then typeinfo+8 → mangled name.
4. Callers: `bl`/`b` bit-pattern match against a function start (`paciasp` / `bti c`).

## Live page host (design, 2026-11-22; offline findings, not built)

Goal: the slot shows a picture an outside process keeps updating and passes it the screen's touches, so an app (the
Plugin Manager's background server first) can have a full-screen page of its own in MPC. Findings from 3.10.1
`b24b7955`:

- **Touches.** `TouchDummyPage` has its page vtable at `0x7df7080` (paint is entry 8, `0x3c59b80`). Its JUCE
  `Component` vtable is at `0x7df7118`, where entries 2–8 are `MouseListener`'s mouseMove, mouseEnter, mouseExit,
  mouseDown, mouseDrag, mouseUp and mouseDoubleClick. All of them are JUCE's empty default (`0x1203cc8`); mouseWheelMove
  (`0x12739ec`) and mouseMagnify (`0x1273fa4`) follow. Replacing mouseDown/Drag/Up (`0x7df7140`, `0x7df7148`,
  `0x7df7150`; RELRO data, so made writable for the write) gives the shim the touches while the placeholder page is
  shown. `juce::MouseEvent` starts with `Point<float> position`, relative to the page. Not yet checked: whether another
  component on top takes the touches first.
- **Repaint.** `juce::Component::repaint()` is `0x1269b80` (1,023 callers). It loads the size from `+0x28` and calls
  `0x1269664`, which matches JUCE's `internalRepaintUnchecked`: the visible bit in the flags at `+0xa8`, the cached image
  at `+0x68`, the peer, or the parent at `+0x18`. It must run on the message thread. Mouse handlers do. For frames that
  arrive between touches, the shim needs a way onto the message thread: either JUCE's `MessageManager::MessageBase::post`,
  with a static message object whose reference count never reaches zero, or an always-running JUCE `Timer` callback.
  Neither has been located yet.
- **Picture.** As now: `ImageCache::getFromMemory` with the latest PNG. Each new frame needs a new buffer, because the
  cache keys on the pointer; JUCE drops unused cache entries after a timeout.

Proposed protocol (to be tried):
- The app writes `/run/openmpc-page/frame.png` (1280×800) by renaming over it.
- The shim sends events to `/run/openmpc-page/input.sock` (Unix datagram), one text line each: `enter`, `leave`,
  `down X Y`, `drag X Y`, `up X Y`.
- While the slot is shown, the shim watches the frame file and repaints when it changes.
- No app running means the slot shows the shim's own `page.png`.

Steps:
1. Shim v3: touches to the socket, plus repaint on a new frame. Test it on the device with a tiny test app that
   draws the last touch.
2. Plugin Manager: its background server draws its UI (software raster to PNG) and handles the touches.

## The 32-bit builds: Gen1 MPC and Force, MPC OS 3.10.1 (offline, 2026-11-23)

**[F, offline: read from the update images, tested under qemu-user; not on a device.]** The Mode Slot shim now has profiles for
the 32-bit ARM builds. Everything above (the `ModeID` table, the three holes, the hooks) applies to them; this section is what
differs and where the sites are. Images: `MPC-3.10.1-Gen1-update.img` (Gen1 MPC: Live, Live II, One, X, Key 61/37) and
`Force-3.10.1-update.img` (the final Force 3.10.1; the 3.10.1.8 pre-release is a different build), both from the private
open-mpc/mpc-firmware release. An update image is an `AZ01` container holding xz streams; the root filesystem is the big ext4 one.

| | Gen1 MPC 3.10.1 | Force 3.10.1 |
|---|---|---|
| build-id | `851d050eb03ce0b8663aaa572b2599813cbf53d4` | `1d93533452bc330028ca60b735b83a4be3e4ebbd` |
| `getModeName` (out r0, id r1) / its `0x2080` switch | `0x166e39c` / `addls` at `0x166e630` | `0x166e35c` / `0x166e5f0` |
| `registerMode` (mgr, id, Mode\*) | `0x166b374` | `0x166b334` |
| touch UI mode change (this, id) / its page switch | `0x3640804` / `0x36408a4` | `0x36403cc` / `0x364046c` |
| `ImageCache::getFromMemory` (out, data, size) | `0xadbeb4` | `0xadbe74` |
| MENU icon lookup (out, id) | `0x3818620` | `0x38181e8` |
| `ModeMenuOrder` setup (this, vector&, settings) | `0xef4e20` | `0xef4de0` |
| `TouchDummyPage::paint` (slot 8 of the vtable at) | `0x3a5a5ec` (`0x6f3c370`) | `0x3a5a1b4` (`0x6f3b390`) |
| mouseDown/Drag/Up slots; JUCE's empty callback | `0x6f3c3d0/d4/d8`; `0xb53c08` | `0x6f3b3f0/f4/f8`; `0xb53bc8` |
| wrapper vtable (`TouchPageContainer`'s Component sub-vtable) | `0x6f01bec` | `0x6f00c0c` |
| `Component::repaint()`, `internalRepaint(x,y,w,h)`, `setBounds(x,y,w,h)` | `0xbc39d0`, `0xbc322c`, `0xbd72c8` | `0xbc3990`, `0xbc31ec`, `0xbd7288` |
| `MemoryInputStream` ctor / dtor, `findImageFormatForStream` | `0x94f4dc` / `0x93bc70`, `0xa86bbc` | `0x94f49c` / `0x93bc30`, `0xa86b7c` |
| placeholder pointer variable -> PNG (208,454 bytes) | `0x7028620` -> `0x5844d50` | `0x7027620` -> `0x58445d0` |

The two builds are the same program text, `0x40` bytes apart in most of it (the touch UI `0x438` apart), found by matching
functions by instruction patterns with branch targets and literal offsets masked out; every site matched exactly one function.

What is different from Gen2:
- **Calling convention.** A class returned by value (`juce::String`, `juce::Image`) comes back through a hidden pointer that is
  the first argument (`r0`), not `x8`, so the 32-bit hooks are ordinary C functions. `Rectangle<int>` (16 bytes) is passed in
  `r1`-`r3` and the stack: `internalRepaint(this, x, y, w, h)`, not two packed registers. A `ModeID` is `r1` after a result
  pointer in `r0`.
- **Long-branch veneers.** The text is 77 MB, beyond a branch's 32 MB, so calls to far functions go through linker veneers
  (`ldr ip, [pc]; add pc, pc, ip; .word offset`, target = veneer + 12 + offset). Hook the real function, never a veneer.
- **Function starts.** Prologues use `strd`/`str lr`, not `push`; scanning for `push {..., lr}` finds almost nothing. The binary has
  `.ARM.exidx`, which lists every function's start. Entry instructions may be PC-relative literal loads (`ldr r2, [pc, #0x4fc]`);
  what they load is a constant (often an offset the function adds its own pc to later), so a trampoline can re-create them.
- **Jump tables** are `addls pc, pc, rN, lsl #2` followed by one `b` per id (the instruction after the `addls` is the default's
  `b`), not halfword offsets.
- **Layouts** (pointers are 4 bytes): `juce::Component` parent `+0xc`, bounds `x, y, w, h` at `+0x10`, child array `+0x28` with its count
  at `+0x30`, flags `+0x68`; `ReferenceCountedObject`'s count `+4`; `TouchDummyPage`'s Component sub-object is at `+8`
  (Gen2: `+16`); the touch UI keeps the placeholder page's holder at `this + 0x3510`, the page pointer inside it at `+0x1a0`;
  `decodeImage` is vtable slot 5 (`+0x14`). The vtables' groups and offsets-to-top come from the RTTI (`14TouchDummyPage`,
  `18TouchPageContainer`); no JUCE function has a symbol.
- **`ModeMenuOrder`.** The function that reads the `ModeMenuPage`/`Slot` settings keys (`0x23aad68`, 4 arguments) has no direct
  callers; the hook goes on its wrapper `0xef4e20` instead (the same shape as Gen2's `0x154da40`).

Checked by `check_profile_a32.py` (in open-mpc/plugin-manager, `modeslot/`) against both binaries, including through the RTTI that
`paint` is slot 8 of `TouchDummyPage`'s vtable and that the Component layout constants match the code of `setBounds`, `repaint`
and `getFromMemory`.
