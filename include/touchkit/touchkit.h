// touchkit: a reusable on-screen touch-controls overlay for iOS games.
// Game-agnostic and Objective-C free, so plain C++ can include it. The
// host describes its pad (a table of controls); the framework draws it,
// tracks fingers, runs the layout editor and a settings sheet, and turns
// touches that miss every control into a pointer. Implementation: touchkit.mm.
#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace touchkit {

// PointerToggle: a button that flips the pointer mode (label TAP = Absolute,
// DRAG = Relative); the framework adds it to the editor's Add list itself.
// Append-only: values are used in saved tables.
enum class Kind { Button, Trigger, Stick, PointerToggle };

// One built-in control. Saved layouts address these by their index in
// Config::controls: ONLY APPEND new rows, never insert or reorder.
struct ControlDef {
    const char* label;      // "\n" makes two lines
    Kind kind;
    uint32_t bit;           // Button: the bit set in Sample::buttons while held
    int axis;               // Trigger: 0 = L, 1 = R. Stick: 0 = left (floats in its zone), 1 = right (fixed circle)
    float fx, fy;           // centre as fractions of the safe area
    float r;                // radius in points
    bool hiddenByDefault;   // shown only in the editor until the player unhides it
};

// What the editor's Add offers.
struct InputDef {
    const char* name;       // in the Add menu
    const char* label;      // default label on the new control
    Kind kind;              // Button or Trigger (Stick can't be added)
    uint32_t bit;
    int axis;
};

// A host setting shown in the gear sheet. Rows of one `section` share one
// "<section>..." entry there; its sheet lists "Title: Current option" rows, a row
// opens its options, and "Reset settings to defaults" restores the section.
struct HostSetting {
    std::string section;                // "Video", "Audio"
    std::string key;                    // saved as <prefsPrefix>.setting.<key>
    std::string title;
    std::vector<std::string> options;
    int defaultIndex = 0;
    std::function<void(int)> apply;     // the chosen index; main thread when the player picks
};

struct Config {
    std::string prefsPrefix;            // NSUserDefaults key prefix, e.g. "sims2.touch"
    std::vector<ControlDef> controls;
    std::vector<InputDef> addable;
    std::vector<HostSetting> settings;
    uint32_t tapBit = 0;                // Relative pointer: a quick tap holds this bit for 0.1 s
};

enum class PointerMode { Relative, Absolute };

struct Sample {
    uint32_t buttons = 0;
    float stick[2][2] = {};             // [left/right][x/y], -1..1, right and up positive
    float trigger[2] = {};              // [L/R], 0..1
};

struct Tap { float x, y; };             // 0..1 of the game view's bounds, y down

// Main thread, once. `uiView` is the game's UIView*. Adds a full-size overlay
// that draws the pad and takes ALL touches on the view (the host view gets none).
void Attach(void* uiView, const Config&);

// Any thread: what is held now, pointer included (idle while the editor is open).
Sample Read();

// Pointer (touches off the controls):
//  Relative: one finger dragging from where it landed is the left stick (70 pt =
//   full push); a quick tap (< 0.3 s, < 12 pt) holds Config::tapBit for 0.1 s;
//   two fingers dragging is the right stick.
//  Absolute: each quick tap is queued for PopTap; a one-finger drag or a
//   two-finger drag pans with the right stick (no tap is queued for drags).
PointerMode GetPointerMode();
bool PopTap(Tap* out);                  // any thread, oldest first

// Host settings. Call ApplyHostSettings() once after Attach, when the host is
// ready: it calls every apply() with the saved (or default) index, on the calling thread.
void ApplyHostSettings();
int GetHostSetting(const std::string& key);   // any thread; -1 if unknown

// True while the controls are shown: hidden with a hardware controller
// connected (Auto) or when the player turned them off. The gear stays.
bool Visible();

}  // namespace touchkit
