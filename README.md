# touchkit

Reusable iOS (15+) on-screen touch controls: drawn buttons, triggers and floating thumb-sticks with multi-touch and sliding between buttons, haptics, a layout editor (move, size, opacity, Add, Label, Hide/Show, Remove, Reset, 3 layout slots saved in NSUserDefaults), a gear settings sheet (pointer mode, haptics, show on/off/auto-hide with a hardware controller, edit layout), and a screen pointer for touches that miss every control. No game or emulator includes; the host maps `touchkit::Sample` onto its own pad.

## API (`include/touchkit/touchkit.h`)
- `Attach(void* uiView, const Config&)` main thread, once. Adds the overlay over the game's view; the overlay takes all touches on it.
- `Sample Read()` any thread: `buttons` bitmask, `stick[left/right][x/y]` (-1..1, up/right +), `trigger[L/R]` (0..1).
- `PointerMode GetPointerMode()`, `bool PopTap(Tap*)` (absolute-mode taps, 0..1 of the view, oldest first), `bool Visible()`.
- `Config`: `prefsPrefix`, `controls` (the built-in table; saved layouts address rows by index, so only ever APPEND rows), `addable` (what the editor's Add offers), `tapBit`.

Host settings: `Config::settings` (`HostSetting`: section, key, title, options, defaultIndex, apply) become "<Section>..." rows in the gear sheet; call `ApplyHostSettings()` once after `Attach`. `Kind::PointerToggle` is an on-screen button that flips the pointer mode.

Pointer: Relative = one-finger drag is the left stick (70 pt = full), quick tap holds `tapBit` 0.1 s, two-finger drag is the right stick. Absolute = quick taps are queued for `PopTap`; any drag (one or two fingers) pans with the right stick.

## Adding to a host
```cmake
add_subdirectory(/path/to/touchkit touchkit)   # needs OBJCXX; builds libtouchkit.a
target_link_libraries(mygame PRIVATE touchkit)
```
```cpp
touchkit::Config c; c.prefsPrefix = "mygame.touch"; c.tapBit = A;
c.controls = {{"A", touchkit::Kind::Button, A, 0, 0.9f, 0.72f, 44, false}, ...};
touchkit::Attach((__bridge void*)gameView, c);
// every frame: touchkit::Sample s = touchkit::Read();
```
