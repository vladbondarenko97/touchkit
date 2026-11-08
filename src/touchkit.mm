// touchkit: see touchkit.h. Built with ARC.
#if !__has_feature(objc_arc)
#error compile with -fobjc-arc
#endif
#include <touchkit/touchkit.h>

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <deque>
#include <mutex>

namespace
{
    using namespace touchkit;

    enum class K { Button, Trigger, Stick, Settings, Toggle, Hide };

    struct Control
    {
        std::string label;
        K kind;
        float fx, fy, r;        // centre as fractions of the safe area, radius in points
        uint32_t bit = 0;       // Button
        int axis = 0;           // Trigger / Stick
        bool hidden = false;    // not drawn or touchable outside the editor
        int input = -1;         // an added control: its row in Config::addable (else a built-in, -1)
        CAShapeLayer* shape = nil;
        CATextLayer* text = nil;
        CAShapeLayer* knob = nil;   // sticks: where the thumb is
        int holds = 0;
        UITouch* touch = nil;       // sticks: the finger on it, where it landed / is now
        CGPoint origin{}, at{};
    };

    K ToK(Kind k)
    {
        switch (k)
        {
        case Kind::Trigger: return K::Trigger;
        case Kind::Stick: return K::Stick;
        case Kind::PointerToggle: return K::Toggle;
        case Kind::HideToggle: return K::Hide;
        default: return K::Button;
        }
    }

    Config s_cfg;
    bool s_ghost = false;  // ghost mode: controls invisible but live
    // s_controls: the built-ins (Config::controls), then the gear (always, can't be
    // removed or hidden), then the added controls. The gear is saved under "g".
    std::vector<Control> s_controls, s_defaults;
    size_t s_gear = 0;

    UIView* s_view = nil;
    UIImpactFeedbackGenerator* s_haptic = nil;
    struct Finger { UITouch* touch = nil; int control = -1; };
    Finger s_fingers[16];
    Finger* FingerOf(UITouch* t)
    {
        for (Finger& f : s_fingers)
            if (f.touch == t)
                return &f;
        return nullptr;
    }

    // Settings (all persisted).
    std::atomic<int> s_pointerMode{0};  // PointerMode
    bool s_haptics = true;
    int s_showMode = 2;                 // 0 on, 1 off, 2 auto (hide while a controller is connected)
    std::atomic<bool> s_show{true};     // the controls are shown now
    std::atomic<bool> s_editingA{false};
    bool s_editing = false;

    // What Read() hands out.
    std::mutex s_mutex;
    Sample s_sample;
    float s_ptr[2][2] = {};
    double s_tapUntil = 0;
    std::deque<Tap> s_taps;

    // The pointer: touches that landed off every control.
    NSMutableArray<UITouch*>* s_ptrTouches = nil;
    CGPoint s_ptrOrigin{}, s_ptrLast{};
    NSTimeInterval s_ptrBegan = 0;
    CGFloat s_ptrTravel = 0;
    NSUInteger s_ptrMax = 0;
    constexpr CGFloat kPointerRadius = 70;
    CGFloat s_ptrD0 = 0;  // two fingers: their distance at the start
    int s_ptrGesture = 0;  // 0 undecided, 1 pan, 2 pinch

    CGFloat PtrDistance()
    {
        if (s_ptrTouches.count < 2)
            return 0;
        CGPoint a = [s_ptrTouches[0] locationInView:s_view], b = [s_ptrTouches[1] locationInView:s_view];
        return std::hypot(a.x - b.x, a.y - b.y);
    }

    // Layout slots: diffs from the table as built, saved on every change.
    struct Saved { std::string label; float fx, fy, r; bool hidden; };
    struct Extra { int input; std::string label; float fx, fy, r; };
    struct LayoutData { std::vector<Saved> controls; std::vector<Extra> extras; };
    constexpr int kSlots = 3;
    LayoutData s_data[kSlots];
    int s_slot = 0, s_appliedSlot = -1;
    UIButton *s_labelButton = nil, *s_removeButton = nil;
    UITextField* s_renameField = nil;
    int s_selected = -1;
    UITouch* s_dragTouch = nil;
    CGPoint s_dragOffset{};
    float s_opacity = 1.0f;
    UIView* s_toolbar = nil;
    UISlider* s_sizeSlider = nil;
    UISegmentedControl* s_slotControl = nil;

    std::vector<int> s_hostVals;  // per Config::settings, under s_mutex

    NSString* Key(const char* suffix) { return [NSString stringWithFormat:@"%s.%s", s_cfg.prefsPrefix.c_str(), suffix]; }
    NSString* Str(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

    bool Shown() { return s_editing || s_show; }
    bool Visible(const Control& c) { return c.kind == K::Settings || (Shown() && (!c.hidden || s_editing)); }
    bool IsStick(const Control& c) { return c.kind == K::Stick; }

    CGPoint CentreOf(const Control& c)
    {
        CGRect safe = UIEdgeInsetsInsetRect(s_view.bounds, s_view.safeAreaInsets);
        return CGPointMake(safe.origin.x + c.fx * safe.size.width, safe.origin.y + c.fy * safe.size.height);
    }

    // The nearest visible control under `p` (a little generous: fingers are wide); -1 for none.
    int ControlAt(CGPoint p, bool withStick = false)
    {
        int best = -1;
        float bestDistance = 0;
        for (size_t i = 0; i < s_controls.size(); i++)
        {
            const Control& c = s_controls[i];
            if (!Visible(c) || (IsStick(c) && !withStick))
                continue;
            CGPoint o = CentreOf(c);
            float d = std::hypot(float(p.x - o.x), float(p.y - o.y));
            if (d < c.r * 1.35f && (best < 0 || d < bestDistance))
            {
                best = int(i);
                bestDistance = d;
            }
        }
        return best;
    }

    // The stick that takes a finger at `p`: only one landing near its drawn circle
    // (fixed position; the rest of the screen is the game's and the pointer's).
    int StickAt(CGPoint p)
    {
        for (size_t i = 0; i < s_controls.size(); i++)
        {
            const Control& c = s_controls[i];
            if (!IsStick(c) || !Visible(c) || c.touch)
                continue;
            CGPoint o = CentreOf(c);
            const bool in = std::hypot(float(p.x - o.x), float(p.y - o.y)) < c.r * 1.3f;
            if (in)
                return int(i);
        }
        return -1;
    }

    // What the game sees now (nothing while editing).
    void Publish()
    {
        Sample s;
        if (!s_editing)
            for (const Control& c : s_controls)
            {
                if (c.kind == K::Button && c.holds > 0)
                    s.buttons |= c.bit;
                else if (c.kind == K::Trigger && c.holds > 0)
                    s.trigger[c.axis & 1] = 1.0f;
                else if (IsStick(c) && c.touch)
                {
                    s.stick[c.axis & 1][0] = std::clamp(float(c.at.x - c.origin.x) / c.r, -1.0f, 1.0f);
                    s.stick[c.axis & 1][1] = std::clamp(float(c.origin.y - c.at.y) / c.r, -1.0f, 1.0f);  // (UIKit's y is down)
                }
            }
        std::lock_guard<std::mutex> lock(s_mutex);
        s_sample = s;
    }

    void Redraw()
    {
        if (!s_view)
            return;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (Control& c : s_controls)
        {
            const bool visible = Visible(c);
            c.shape.hidden = !visible;
            c.text.hidden = !visible;
            c.knob.hidden = !visible || s_editing;
            if (!visible)
                continue;
            CGPoint o = IsStick(c) && c.touch ? c.origin : CentreOf(c);
            c.shape.path = [UIBezierPath bezierPathWithArcCenter:o radius:c.r startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
            const bool held = c.holds > 0 || (IsStick(c) && c.touch);
            // (hidden, seen in the editor; the gear alone, with the controls off)
            float faint = c.hidden ? 0.35f : (c.kind == K::Settings && !Shown()) ? 0.5f : 1.0f;
            if (s_ghost && !s_editing && c.kind != K::Settings)
                faint *= c.kind == K::Hide ? 0.25f : held ? 0.35f : 0.0f;  // (invisible but live; flashes when held)
            c.shape.fillColor = [UIColor colorWithWhite:held ? 1.0 : 0.15 alpha:(held ? 0.45 : 0.30) * s_opacity * faint].CGColor;
            const bool selected = s_editing && s_selected >= 0 && &c == &s_controls[size_t(s_selected)];
            c.shape.strokeColor = selected ? UIColor.systemYellowColor.CGColor
                                           : [UIColor colorWithWhite:1 alpha:0.55 * s_opacity * faint].CGColor;
            c.shape.lineWidth = selected ? 3 : s_editing ? 2 : 1.5;
            c.shape.lineDashPattern = s_editing && !selected ? @[ @6, @4 ] : nil;
            c.text.opacity = std::max(s_opacity, 0.35f) * faint;
            if (c.kind == K::Toggle)
                c.text.string = s_pointerMode == int(PointerMode::Absolute) ? @"TAP" : @"DRAG";
            CGFloat size = c.text.fontSize * (c.label.find('\n') != std::string::npos ? 2.4 : 1.25);
            c.text.frame = CGRectMake(o.x - c.r, o.y - size / 2, c.r * 2, size);
            if (IsStick(c))
            {
                CGFloat dx = 0, dy = 0;
                if (c.touch)
                {
                    dx = std::clamp(c.at.x - c.origin.x, -CGFloat(c.r), CGFloat(c.r));
                    dy = std::clamp(c.at.y - c.origin.y, -CGFloat(c.r), CGFloat(c.r));
                }
                const CGFloat k = c.r >= 50 ? 28 : 18;
                c.knob.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(o.x + dx, o.y + dy) radius:k startAngle:0
                    endAngle:2 * M_PI clockwise:YES].CGPath;
                c.knob.opacity = s_opacity * (s_ghost && !s_editing ? (held ? 0.35f : 0.0f) : 1.0f);
            }
        }
        s_toolbar.hidden = !s_editing;
        [CATransaction commit];
        Publish();
    }

    void PointerOut(float lx, float ly, float rx, float ry)
    {
        std::lock_guard<std::mutex> lock(s_mutex);
        s_ptr[0][0] = lx; s_ptr[0][1] = ly; s_ptr[1][0] = rx; s_ptr[1][1] = ry;
    }

    void ReleaseAll()
    {
        for (Finger& f : s_fingers)
            f = {};
        for (Control& c : s_controls)
        {
            c.holds = 0;
            c.touch = nil;
        }
        [s_ptrTouches removeAllObjects];
        PointerOut(0, 0, 0, 0);
    }

    // The controls shown or not, from the player's choice and any controller.
    void Apply()
    {
        const bool controller = GCController.controllers.count > 0;
        const bool show = s_showMode == 0 || (s_showMode == 2 && !controller);
        if (show != s_show)
        {
            s_show = show;
            ReleaseAll();
        }
        Redraw();
    }

    void OpenSettings();
    void OpenSection(int section);
    void OpenKeyboard();

    void SaveSettings();

    void Press(int i)
    {
        Control& c = s_controls[size_t(i)];
        if (c.kind == K::Toggle)  // flips the pointer mode, holds nothing
        {
            s_pointerMode = s_pointerMode == 0 ? 1 : 0;
            SaveSettings();
            [s_haptic impactOccurred];
            Redraw();
            return;
        }
        if (c.kind == K::Hide)
        {
            s_ghost = !s_ghost;
            SaveSettings();
            [s_haptic impactOccurred];
            Redraw();
            return;
        }
        c.holds++;
        if (s_haptics)
            [s_haptic impactOccurred];
    }

    void Release(int i)
    {
        Control& c = s_controls[size_t(i)];
        if (c.holds > 0)
            c.holds--;
        if (c.kind == K::Settings && c.holds == 0 && !s_editing)
            dispatch_async(dispatch_get_main_queue(), ^{ OpenSettings(); });  // (not while touches are being handled)
    }

    void MakeLayers(Control& c)
    {
        c.shape = [CAShapeLayer layer];
        c.shape.strokeColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        c.shape.lineWidth = 1.5;
        [s_view.layer addSublayer:c.shape];
        c.text = [CATextLayer layer];
        c.text.string = Str(c.label);
        c.text.fontSize = c.r >= 40 ? 15 : c.r >= 30 ? 12 : 10;
        c.text.alignmentMode = kCAAlignmentCenter;
        c.text.wrapped = YES;
        c.text.contentsScale = UIScreen.mainScreen.scale;
        c.text.foregroundColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        [s_view.layer addSublayer:c.text];
        if (IsStick(c))
        {
            c.knob = [CAShapeLayer layer];
            c.knob.fillColor = [UIColor colorWithWhite:1 alpha:0.40].CGColor;
            [s_view.layer addSublayer:c.knob];
        }
    }

    void DropLayers(Control& c)
    {
        [c.shape removeFromSuperlayer];
        [c.text removeFromSuperlayer];
        [c.knob removeFromSuperlayer];
    }

    Control MakeExtra(int input, const std::string& label, float fx, float fy, float r)
    {
        const InputDef& in = s_cfg.addable[size_t(input)];
        Control c{ label, ToK(in.kind),
                   fx, fy, r, in.bit, in.axis };
        c.input = input;
        return c;
    }

    // s_controls to the layout of the slot it is showing (s_data keeps it for later).
    void Capture()
    {
        if (s_appliedSlot < 0)
            return;
        LayoutData& d = s_data[s_appliedSlot];
        d.extras.clear();
        for (size_t i = 0; i < s_controls.size(); i++)
        {
            const Control& c = s_controls[i];
            if (i < s_defaults.size())
                d.controls[i] = { c.label, c.fx, c.fy, c.r, c.hidden };
            else
                d.extras.push_back({ c.input, c.label, c.fx, c.fy, c.r });
        }
    }

    void DropExtras()
    {
        for (size_t i = s_defaults.size(); i < s_controls.size(); i++)
            DropLayers(s_controls[i]);
        s_controls.erase(s_controls.begin() + s_defaults.size(), s_controls.end());
    }

    void SetBuiltin(size_t i, const std::string& label, float fx, float fy, float r, bool hidden)
    {
        Control& c = s_controls[i];
        c.label = label;
        c.fx = fx;
        c.fy = fy;
        c.r = r;
        c.hidden = hidden && c.kind != K::Settings;
        c.text.string = Str(label);
    }

    void ShowLayout(int slot)
    {
        if (slot == s_appliedSlot)
            return;
        Capture();
        ReleaseAll();  // a held control would stay held
        DropExtras();
        const LayoutData& d = s_data[slot];
        for (size_t i = 0; i < s_defaults.size(); i++)
            SetBuiltin(i, d.controls[i].label, d.controls[i].fx, d.controls[i].fy, d.controls[i].r, d.controls[i].hidden);
        for (const Extra& e : d.extras)
        {
            s_controls.push_back(MakeExtra(e.input, e.label, e.fx, e.fy, e.r));
            MakeLayers(s_controls.back());
        }
        s_slot = s_appliedSlot = slot;
        s_selected = -1;
    }

    // Saved per slot: { "c": { index or "g": [fx, fy, r, hidden, label] }, "a": [[input, label, fx, fy, r]] }, diffs only.
    NSString* IndexKey(size_t i) { return i == s_gear ? @"g" : [NSString stringWithFormat:@"%zu", i]; }

    void SaveSettings()
    {
        NSUserDefaults* u = [NSUserDefaults standardUserDefaults];
        [u setInteger:s_pointerMode forKey:Key("pointer")];
        [u setBool:s_haptics forKey:Key("haptics")];
        [u setInteger:s_showMode forKey:Key("show")];
        [u setBool:s_ghost forKey:Key("ghost")];
        [u synchronize];  // now: the app may be killed (a reinstall) before iOS writes it
    }

    void SaveLayout()
    {
        Capture();
        NSMutableArray* slots = [NSMutableArray array];
        for (const LayoutData& d : s_data)
        {
            NSMutableDictionary* cd = [NSMutableDictionary dictionary];
            for (size_t i = 0; i < d.controls.size(); i++)
            {
                const Saved& c = d.controls[i];
                const Control& o = s_defaults[i];
                if (c.fx != o.fx || c.fy != o.fy || c.r != o.r || c.hidden != o.hidden || c.label != o.label)
                    cd[IndexKey(i)] = @[ @(c.fx), @(c.fy), @(c.r), @(c.hidden), Str(c.label) ];
            }
            NSMutableArray* ad = [NSMutableArray array];
            for (const Extra& e : d.extras)
                [ad addObject:@[ @(e.input), Str(e.label), @(e.fx), @(e.fy), @(e.r) ]];
            [slots addObject:@{ @"c" : cd, @"a" : ad }];
        }
        NSUserDefaults* u = [NSUserDefaults standardUserDefaults];
        [u setObject:slots forKey:Key("profiles")];
        [u setInteger:s_slot forKey:Key("slot")];
        [u setFloat:s_opacity forKey:Key("opacity")];
        [u synchronize];
    }

    void ReadSaved(Saved& s, id v)
    {
        if (![v isKindOfClass:[NSArray class]] || [v count] != 5 || ![v[4] isKindOfClass:[NSString class]])
            return;
        s.fx = std::clamp([v[0] floatValue], 0.0f, 1.0f);
        s.fy = std::clamp([v[1] floatValue], 0.0f, 1.0f);
        s.r = std::clamp([v[2] floatValue], 14.0f, 110.0f);
        s.hidden = [v[3] boolValue];
        s.label = [v[4] UTF8String];
    }

    void LoadLayout()
    {
        for (LayoutData& d : s_data)
        {
            d.extras.clear();
            d.controls.clear();
            for (const Control& c : s_defaults)
                d.controls.push_back({ c.label, c.fx, c.fy, c.r, c.hidden });
        }
        NSUserDefaults* u = [NSUserDefaults standardUserDefaults];
        NSArray* slots = [u arrayForKey:Key("profiles")];
        for (NSUInteger n = 0; n < slots.count && n < NSUInteger(kSlots); n++)
        {
            NSDictionary* sd = [slots[n] isKindOfClass:[NSDictionary class]] ? slots[n] : nil;
            LayoutData& d = s_data[n];
            NSDictionary* cd = [sd[@"c"] isKindOfClass:[NSDictionary class]] ? sd[@"c"] : nil;
            for (NSString* key in cd)
            {
                const NSInteger i = [key isEqualToString:@"g"] ? NSInteger(s_gear) : key.integerValue;
                if (i >= 0 && size_t(i) < d.controls.size())
                {
                    ReadSaved(d.controls[size_t(i)], cd[key]);
                    if (size_t(i) == s_gear)
                        d.controls[s_gear].hidden = false;
                }
            }
            NSArray* ad = [sd[@"a"] isKindOfClass:[NSArray class]] ? sd[@"a"] : nil;
            for (NSArray* v in ad)
            {
                if (![v isKindOfClass:[NSArray class]] || v.count != 5 || ![v[1] isKindOfClass:[NSString class]])
                    continue;
                const int input = [v[0] intValue];
                if (input >= 0 && size_t(input) < s_cfg.addable.size())
                    d.extras.push_back({ input, [v[1] UTF8String], std::clamp([v[2] floatValue], 0.0f, 1.0f),
                        std::clamp([v[3] floatValue], 0.0f, 1.0f), std::clamp([v[4] floatValue], 14.0f, 110.0f) });
            }
        }
        s_slot = std::clamp(int([u integerForKey:Key("slot")]), 0, kSlots - 1);
        if (float v = [u floatForKey:Key("opacity")]; v >= 0.1f && v <= 1.0f)
            s_opacity = v;
        s_pointerMode = std::clamp(int([u integerForKey:Key("pointer")]), 0, 1);
        if ([u objectForKey:Key("haptics")])
            s_haptics = [u boolForKey:Key("haptics")];
        s_ghost = [u boolForKey:Key("ghost")];
        if ([u objectForKey:Key("show")])
            s_showMode = std::clamp(int([u integerForKey:Key("show")]), 0, 2);
    }

    void SyncToolbar()
    {
        const Control* c = s_selected >= 0 ? &s_controls[size_t(s_selected)] : nullptr;
        s_sizeSlider.enabled = c != nullptr;
        if (c)
            s_sizeSlider.value = c->r;
        const bool other = c && c->kind != K::Settings;  // (the gear stays, as it is)
        s_labelButton.enabled = other && c->kind != K::Toggle;  // (its label shows the mode)
        s_removeButton.enabled = other;
        [s_removeButton setTitle:c && c->input < 0 ? (c->hidden ? @"Show" : @"Hide") : @"Remove" forState:UIControlStateNormal];
        s_slotControl.selectedSegmentIndex = s_slot;
    }

    void SetEditing(bool on)
    {
        if (on == s_editing)
            return;
        ReleaseAll();
        s_editing = on;
        s_editingA = on;
        s_selected = -1;
        s_dragTouch = nil;
        if (!on)
            SaveLayout();
        SyncToolbar();
        Redraw();
    }

    void Present(UIViewController* vc, UIView* source = nil)
    {
        UIViewController* top = s_view.window.rootViewController;
        while (top.presentedViewController)
            top = top.presentedViewController;
        vc.popoverPresentationController.sourceView = source ?: s_view;  // (iPad)
        vc.popoverPresentationController.sourceRect = source ? source.bounds
            : CGRectMake(CGRectGetMidX(s_view.bounds), CGRectGetMidY(s_view.bounds), 1, 1);
        [top presentViewController:vc animated:YES completion:nil];
    }

    // Host settings: the section sheet, a setting's options, and Reset.
    void OpenSection(int section);

    std::vector<std::string> SectionNames()
    {
        std::vector<std::string> sections;
        for (const HostSetting& h : s_cfg.settings)
            if (std::find(sections.begin(), sections.end(), h.section) == sections.end())
                sections.push_back(h.section);
        return sections;
    }

    int HostValue(size_t i)
    {
        std::lock_guard<std::mutex> lock(s_mutex);
        return s_hostVals[i];
    }

    void SetHostValue(size_t i, int v, bool apply)
    {
        {
            std::lock_guard<std::mutex> lock(s_mutex);
            s_hostVals[i] = v;
        }
        NSString* key = [NSString stringWithFormat:@"%@.setting.%@", Str(s_cfg.prefsPrefix), Str(s_cfg.settings[i].key)];
        [[NSUserDefaults standardUserDefaults] setInteger:v forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        if (apply && s_cfg.settings[i].apply)
            s_cfg.settings[i].apply(v);
    }

    void OpenOptions(int section, int setting)
    {
        const HostSetting& h = s_cfg.settings[size_t(setting)];
        UIAlertController* a = [UIAlertController alertControllerWithTitle:Str(h.title) message:nil
            preferredStyle:UIAlertControllerStyleActionSheet];
        const int current = HostValue(size_t(setting));
        for (size_t o = 0; o < h.options.size(); o++)
        {
            const int n = int(o);
            NSString* title = (int(o) == current ? @"✓ " : @"    ");
            [a addAction:[UIAlertAction actionWithTitle:[title stringByAppendingString:Str(h.options[o])]
                style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
                    SetHostValue(size_t(setting), n, true);
                    dispatch_async(dispatch_get_main_queue(), ^{ OpenSection(section); });
                }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
            dispatch_async(dispatch_get_main_queue(), ^{ OpenSection(section); });
        }]];
        Present(a);
    }

    void OpenSection(int section)
    {
        const std::vector<std::string> names = SectionNames();
        if (section < 0 || size_t(section) >= names.size() || s_editing || !s_view.window)
            return;
        UIAlertController* a = [UIAlertController alertControllerWithTitle:Str(names[size_t(section)]) message:nil
            preferredStyle:UIAlertControllerStyleActionSheet];
        for (size_t i = 0; i < s_cfg.settings.size(); i++)
        {
            const HostSetting& h = s_cfg.settings[i];
            if (h.section != names[size_t(section)])
                continue;
            const int v = HostValue(i);
            NSString* cur = v >= 0 && size_t(v) < h.options.size() ? Str(h.options[size_t(v)]) : @"?";
            const int n = int(i);
            [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@: %@", Str(h.title), cur]
                style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
                    dispatch_async(dispatch_get_main_queue(), ^{ OpenOptions(section, n); });
                }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Reset settings to defaults" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction*) {
                const std::vector<std::string> names = SectionNames();
                for (size_t i = 0; i < s_cfg.settings.size(); i++)
                    if (section >= 0 && size_t(section) < names.size() && s_cfg.settings[i].section == names[size_t(section)])
                        SetHostValue(i, s_cfg.settings[i].defaultIndex, true);
                dispatch_async(dispatch_get_main_queue(), ^{ OpenSection(section); });
            }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
            dispatch_async(dispatch_get_main_queue(), ^{ OpenSettings(); });
        }]];
        Present(a);
    }

    // HID usage to a name, for the read-only keyboard list.
    NSString* KeyName(uint16_t k)
    {
        if (k >= 0x04 && k <= 0x1D) return [NSString stringWithFormat:@"%c", 'A' + (k - 0x04)];
        if (k >= 0x1E && k <= 0x26) return [NSString stringWithFormat:@"%d", 1 + (k - 0x1E)];
        switch (k)
        {
        case 0x27: return @"0";
        case 0x28: return @"Return";   case 0x29: return @"Esc";    case 0x2A: return @"Backspace";
        case 0x2B: return @"Tab";      case 0x2C: return @"Space";  case 0x2D: return @"-";
        case 0x2E: return @"=";        case 0x36: return @",";      case 0x37: return @".";
        case 0x4B: return @"Page Up";  case 0x4E: return @"Page Down";
        case 0x4F: return @"Right";    case 0x50: return @"Left";   case 0x51: return @"Down";
        case 0x52: return @"Up";
        default: return [NSString stringWithFormat:@"Key %u", unsigned(k)];
        }
    }

    void OpenKeyboard()
    {
        if (s_editing || !s_view.window)
            return;
        std::vector<std::string> labels;
        NSMutableArray<NSMutableString*>* names = [NSMutableArray array];
        for (const KeyBind& k : s_cfg.keys)
        {
            size_t i = std::find(labels.begin(), labels.end(), k.label) - labels.begin();
            if (i == labels.size())
            {
                labels.push_back(k.label);
                [names addObject:[NSMutableString string]];
            }
            if (names[i].length)
                [names[i] appendString:@" / "];
            [names[i] appendString:KeyName(k.key)];
        }
        NSMutableString* text = [NSMutableString string];
        for (size_t i = 0; i < labels.size(); i++)
            [text appendFormat:@"%@: %@\n", Str(labels[i]), names[i]];
        UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Keyboard" message:text
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
            dispatch_async(dispatch_get_main_queue(), ^{ OpenSettings(); });
        }]];
        Present(a);
    }

    // The settings sheet: each row changes its setting and shows the sheet again.
    void OpenSettings()
    {
        if (s_editing || !s_view.window)
            return;
        UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Touch controls" message:nil
            preferredStyle:UIAlertControllerStyleActionSheet];
        const bool abs = s_pointerMode == int(PointerMode::Absolute);
        [a addAction:[UIAlertAction actionWithTitle:abs ? @"Pointer: Absolute (tap to point)" : @"Pointer: Relative (drag = stick, tap = A)"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
                s_pointerMode = s_pointerMode == 0 ? 1 : 0;
                SaveSettings();
                OpenSettings();
            }]];
        [a addAction:[UIAlertAction actionWithTitle:s_haptics ? @"Haptics: On" : @"Haptics: Off"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
                s_haptics = !s_haptics;
                SaveSettings();
                OpenSettings();
            }]];
        NSString* show[] = { @"Show controls: On", @"Show controls: Off", @"Show controls: Auto (hide with a controller)" };
        [a addAction:[UIAlertAction actionWithTitle:show[s_showMode] style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
            s_showMode = (s_showMode + 1) % 3;
            SaveSettings();
            Apply();
            OpenSettings();
        }]];
        std::vector<std::string> sections;
        for (const HostSetting& h : s_cfg.settings)
            if (std::find(sections.begin(), sections.end(), h.section) == sections.end())
                sections.push_back(h.section);
        for (size_t i = 0; i < sections.size(); i++)
        {
            const int n = int(i);
            [a addAction:[UIAlertAction actionWithTitle:[Str(sections[i]) stringByAppendingString:@"…"]
                style:UIAlertActionStyleDefault handler:^(UIAlertAction*) { OpenSection(n); }]];
        }
        for (size_t i = 0; i < s_cfg.actions.size(); i++)
        {
            const size_t n = i;
            [a addAction:[UIAlertAction actionWithTitle:Str(s_cfg.actions[i].title()) style:UIAlertActionStyleDefault
                handler:^(UIAlertAction*) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIViewController* top = s_view.window.rootViewController;
                        while (top.presentedViewController)
                            top = top.presentedViewController;
                        s_cfg.actions[n].run((__bridge void*)top);
                    });
                }]];
        }
        if (!s_cfg.keys.empty())
            [a addAction:[UIAlertAction actionWithTitle:@"Keyboard…" style:UIAlertActionStyleDefault
                handler:^(UIAlertAction*) { dispatch_async(dispatch_get_main_queue(), ^{ OpenKeyboard(); }); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Edit layout" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction*) { SetEditing(true); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        Present(a);
    }

    // The alerts' handlers capture nothing but numbers: the alert is gone when they run.
    void AddControl(int input)
    {
        const InputDef& in = s_cfg.addable[size_t(input)];
        s_controls.push_back(MakeExtra(input, in.label, 0.5f, 0.5f, in.kind == Kind::Trigger ? 44.0f : 32.0f));
        MakeLayers(s_controls.back());
        s_selected = int(s_controls.size()) - 1;
        SaveLayout();
        SyncToolbar();
        Redraw();
    }

    void Rename()
    {
        NSString* text = s_renameField.text;
        s_renameField = nil;
        if (s_selected < 0 || size_t(s_selected) >= s_controls.size() || !text)
            return;
        Control& c = s_controls[size_t(s_selected)];
        c.label = text.UTF8String;
        c.text.string = text;
        SaveLayout();
        Redraw();
    }

    // This slot's layout back to the table as built.
    void ResetCurrent()
    {
        DropExtras();
        for (size_t i = 0; i < s_defaults.size(); i++)
            SetBuiltin(i, s_defaults[i].label, s_defaults[i].fx, s_defaults[i].fy, s_defaults[i].r, s_defaults[i].hidden);
        s_selected = -1;
        SaveLayout();
        SyncToolbar();
        Redraw();
    }

    // Pointer.
    CGPoint Centroid()
    {
        CGPoint c{};
        for (UITouch* t in s_ptrTouches)
        {
            CGPoint p = [t locationInView:s_view];
            c.x += p.x / s_ptrTouches.count;
            c.y += p.y / s_ptrTouches.count;
        }
        return c;
    }

    void PointerRestart()
    {
        s_ptrOrigin = s_ptrLast = Centroid();
        s_ptrD0 = PtrDistance();
        s_ptrGesture = 0;
        PointerOut(0, 0, 0, 0);
    }
}

@interface TKOverlay : UIView
@end

@implementation TKOverlay
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    // The overlay takes every touch (the pointer). In the editor the toolbar's
    // sliders and buttons go through UIKit, but the selected control wins over the toolbar.
    if (![self pointInside:point withEvent:event])
        return nil;
    if (s_editing)
        return s_selected >= 0 && ControlAt(point, true) == s_selected ? self : [super hitTest:point withEvent:event];
    return self;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (s_editing)
    {
        UITouch* t = touches.anyObject;
        CGPoint p = [t locationInView:self];
        s_selected = ControlAt(p, true);
        if (s_selected >= 0)
        {
            CGPoint o = CentreOf(s_controls[size_t(s_selected)]);
            s_dragTouch = t;
            s_dragOffset = CGPointMake(p.x - o.x, p.y - o.y);
        }
        SyncToolbar();
        Redraw();
        return;
    }
    for (UITouch* t in touches)
    {
        CGPoint p = [t locationInView:self];
        int i = ControlAt(p);
        int s;
        if (i >= 0)
        {
            if (Finger* f = FingerOf(nil))  // a free slot (more fingers than 16 are ignored)
            {
                *f = { t, i };
                Press(i);
            }
        }
        else if ((s = StickAt(p)) >= 0)
        {
            Control& c = s_controls[size_t(s)];
            c.touch = t;
            c.origin = c.at = p;
        }
        else
        {
            if (s_ptrTouches.count == 0)
            {
                s_ptrBegan = event.timestamp;
                s_ptrTravel = 0;
                s_ptrMax = 0;
            }
            [s_ptrTouches addObject:t];
            s_ptrMax = std::max(s_ptrMax, s_ptrTouches.count);
            PointerRestart();
        }
    }
    Redraw();
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (s_editing)
    {
        if (s_dragTouch && [touches containsObject:s_dragTouch] && s_selected >= 0)
        {
            CGPoint p = [s_dragTouch locationInView:self];
            CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
            Control& c = s_controls[size_t(s_selected)];
            c.fx = std::clamp(float((p.x - s_dragOffset.x - safe.origin.x) / safe.size.width), 0.0f, 1.0f);
            c.fy = std::clamp(float((p.y - s_dragOffset.y - safe.origin.y) / safe.size.height), 0.0f, 1.0f);
            Redraw();
        }
        return;
    }
    bool pointer = false;
    for (UITouch* t in touches)
    {
        CGPoint p = [t locationInView:self];
        bool isStick = false;
        for (Control& c : s_controls)
            if (c.touch == t)
            {
                c.at = p;
                isStick = true;
            }
        if (isStick)
            continue;
        if ([s_ptrTouches containsObject:t])
        {
            pointer = true;
            continue;
        }
        // A finger slides from one button or trigger to the next.
        Finger* f = FingerOf(t);
        if (!f)
            continue;
        int i = ControlAt(p);
        auto slides = [](K k) { return k == K::Button || k == K::Trigger; };
        if (i >= 0 && i != f->control && slides(s_controls[size_t(i)].kind) && slides(s_controls[size_t(f->control)].kind))
        {
            Release(f->control);
            f->control = i;
            Press(i);
        }
    }
    if (pointer && s_ptrTouches.count)
    {
        const CGPoint c = Centroid();
        s_ptrLast = c;
        const CGFloat dx = c.x - s_ptrOrigin.x, dy = c.y - s_ptrOrigin.y;
        s_ptrTravel = std::max(s_ptrTravel, std::hypot(dx, dy));
        const float x = std::clamp(float(dx / kPointerRadius), -1.f, 1.f);
        const float y = std::clamp(float(-dy / kPointerRadius), -1.f, 1.f);
        // Two fingers (or any drag in Absolute mode) pan with the right stick; with
        // Config::pinch, two fingers are a pinch or a pan, whichever dominates first.
        const bool two = s_ptrTouches.count >= 2;
        if (two && s_cfg.pinch.enabled && s_ptrD0 > 1)
        {
            const CGFloat dd = PtrDistance() - s_ptrD0;
            if (s_ptrGesture == 0 && std::max(std::hypot(dx, dy), std::fabs(dd)) > 10)
                s_ptrGesture = std::fabs(dd) > std::hypot(dx, dy) ? 2 : 1;
            if (s_ptrGesture == 2)
            {
                const Pinch& pc = s_cfg.pinch;
                std::lock_guard<std::mutex> lock(s_mutex);
                s_ptr[0][0] = s_ptr[0][1] = s_ptr[1][0] = s_ptr[1][1] = 0;
                s_ptr[pc.stick & 1][pc.axis & 1] = std::clamp(pc.sign * pc.gain * float(PtrDistance() / s_ptrD0 - 1) * 3, -1.0f, 1.0f);
            }
            else if (s_ptrGesture == 1)
                PointerOut(0, 0, x, y);
        }
        else if (two || s_pointerMode == int(PointerMode::Absolute))
            PointerOut(0, 0, x, y);
        else
            PointerOut(x, y, 0, 0);
    }
    Redraw();
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    if (s_editing)
    {
        if (s_dragTouch && [touches containsObject:s_dragTouch])
        {
            s_dragTouch = nil;
            SaveLayout();
        }
        return;
    }
    const BOOL cancelled = touches.anyObject.phase == UITouchPhaseCancelled;
    bool wasPointer = false;
    for (UITouch* t in touches)
    {
        for (Control& c : s_controls)
            if (c.touch == t)
                c.touch = nil;
        if ([s_ptrTouches containsObject:t])
        {
            wasPointer = true;
            [s_ptrTouches removeObject:t];
        }
        if (Finger* f = FingerOf(t))
        {
            const int i = f->control;
            *f = {};
            Release(i);
        }
    }
    if (wasPointer)
    {
        const CGPoint last = s_ptrLast;
        PointerRestart();
        if (s_ptrTouches.count == 0 && !cancelled && s_ptrMax == 1 && s_ptrTravel < 12 && event.timestamp - s_ptrBegan < 0.3)
        {
            std::lock_guard<std::mutex> lock(s_mutex);
            if (s_pointerMode == int(PointerMode::Relative))
                s_tapUntil = CACurrentMediaTime() + 0.1;
            else
            {
                if (s_taps.size() >= 16)
                    s_taps.pop_front();
                s_taps.push_back({ std::clamp(float(last.x / self.bounds.size.width), 0.0f, 1.0f),
                                   std::clamp(float(last.y / self.bounds.size.height), 0.0f, 1.0f) });
            }
        }
    }
    Redraw();
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self touchesEnded:touches withEvent:event];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGSize size = [s_toolbar systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    size.width = std::min(size.width, safe.size.width - 16);
    s_toolbar.frame = CGRectMake(CGRectGetMidX(safe) - size.width / 2, CGRectGetMidY(safe) - size.height / 2, size.width, size.height);
    Redraw();
}

- (void)sizeChanged:(UISlider*)slider
{
    if (s_selected >= 0)
        s_controls[size_t(s_selected)].r = slider.value;
    Redraw();
}

- (void)opacityChanged:(UISlider*)slider
{
    s_opacity = slider.value;
    Redraw();
}

- (void)layoutChanged
{
    SaveLayout();  // (a slider let go)
}

- (void)slotChanged:(UISegmentedControl*)seg
{
    ShowLayout(int(seg.selectedSegmentIndex));
    SaveLayout();
    SyncToolbar();
    Redraw();
}

- (void)addPressed:(UIButton*)sender
{
    if (s_cfg.addable.empty())
        return;
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Add button" message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (size_t i = 0; i < s_cfg.addable.size(); i++)
    {
        const int n = int(i);
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:s_cfg.addable[i].name]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction*) { AddControl(n); }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    Present(a, sender);
}

- (void)labelPressed
{
    if (s_selected < 0)
        return;
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Label" message:nil
        preferredStyle:UIAlertControllerStyleAlert];
    NSString* current = Str(s_controls[size_t(s_selected)].label);
    [a addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.text = current;
        s_renameField = field;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction*) { s_renameField = nil; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) { Rename(); }]];
    Present(a);
}

- (void)removePressed
{
    if (s_selected < 0 || s_controls[size_t(s_selected)].kind == K::Settings)
        return;
    Control& c = s_controls[size_t(s_selected)];
    if (c.input >= 0)  // an added control goes; a built-in one is hidden (or shown again)
    {
        DropLayers(c);
        s_controls.erase(s_controls.begin() + s_selected);
        s_selected = -1;
    }
    else
        c.hidden = !c.hidden;
    SaveLayout();
    SyncToolbar();
    Redraw();
}

- (void)resetLayout
{
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Reset this layout?"
        message:@"Positions, sizes, labels and hidden controls of this layout go back to the defaults, and its added buttons are removed."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction*) { ResetCurrent(); }]];
    Present(a);
}

- (void)doneEditing
{
    SetEditing(false);
}
@end

namespace
{
    UIView* Labelled(NSString* name, UIView* control)
    {
        UILabel* label = [[UILabel alloc] init];
        label.text = name;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[ label, control ]];
        row.axis = UILayoutConstraintAxisVertical;
        row.alignment = UIStackViewAlignmentFill;
        row.spacing = 2;
        [control.widthAnchor constraintEqualToConstant:110].active = YES;
        return row;
    }

    UISlider* Slider(float min, float max, float value, SEL action)
    {
        UISlider* s = [[UISlider alloc] init];
        s.minimumValue = min;
        s.maximumValue = max;
        s.value = value;
        [s addTarget:s_view action:action forControlEvents:UIControlEventValueChanged];
        [s addTarget:s_view action:@selector(layoutChanged)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        return s;
    }

    UIButton* ToolButton(NSString* title, SEL action)
    {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        [b addTarget:s_view action:action forControlEvents:UIControlEventTouchUpInside];
        return b;
    }

    UIStackView* Row(NSArray* views)
    {
        UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:views];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 14;
        return row;
    }

    void BuildToolbar()
    {
        s_sizeSlider = Slider(14, 110, 40, @selector(sizeChanged:));
        s_slotControl = [[UISegmentedControl alloc] initWithItems:@[ @"Layout 1", @"Layout 2", @"Layout 3" ]];
        s_slotControl.selectedSegmentIndex = s_slot;
        s_slotControl.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [s_slotControl setTitleTextAttributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] }
            forState:UIControlStateNormal];
        [s_slotControl addTarget:s_view action:@selector(slotChanged:) forControlEvents:UIControlEventValueChanged];
        s_labelButton = ToolButton(@"Label", @selector(labelPressed));
        s_removeButton = ToolButton(@"Remove", @selector(removePressed));
        [s_removeButton.widthAnchor constraintEqualToConstant:64].active = YES;  // (its title changes)
        UIStackView* bar = [[UIStackView alloc] initWithArrangedSubviews:@[
            Row(@[ Labelled(@"Size (tap a control)", s_sizeSlider),
                   Labelled(@"Opacity", Slider(0.1f, 1.0f, s_opacity, @selector(opacityChanged:))), s_slotControl ]),
            Row(@[ ToolButton(@"Add", @selector(addPressed:)), s_labelButton, s_removeButton,
                   ToolButton(@"Reset", @selector(resetLayout)), ToolButton(@"Done", @selector(doneEditing)) ]),
        ]];
        bar.axis = UILayoutConstraintAxisVertical;
        bar.alignment = UIStackViewAlignmentCenter;
        bar.spacing = 8;
        bar.layoutMarginsRelativeArrangement = YES;
        bar.layoutMargins = UIEdgeInsetsMake(10, 14, 10, 14);
        bar.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
        bar.layer.cornerRadius = 12;
        bar.hidden = YES;
        [s_view addSubview:bar];
        s_toolbar = bar;
        SyncToolbar();
    }
}

namespace touchkit
{
    void Attach(void* uiView, const Config& config)
    {
        UIView* parent = (__bridge UIView*)uiView;
        if (s_view || !parent)
            return;
        s_cfg = config;
        bool hasToggle = false;
        for (const InputDef& in : s_cfg.addable)
            hasToggle |= in.kind == Kind::PointerToggle;
        bool hasHide = false;
        for (const InputDef& in : s_cfg.addable)
            hasHide |= in.kind == Kind::HideToggle;
        if (!hasToggle)
            s_cfg.addable.push_back({ "Pointer toggle", "DRAG", Kind::PointerToggle, 0, 0 });
        if (!hasHide)
            s_cfg.addable.push_back({ "Hide-UI toggle", "HIDE", Kind::HideToggle, 0, 0 });
        {
            NSUserDefaults* u = [NSUserDefaults standardUserDefaults];
            std::lock_guard<std::mutex> lock(s_mutex);
            for (const HostSetting& h : s_cfg.settings)
            {
                NSString* key = [NSString stringWithFormat:@"%@.setting.%@", Str(s_cfg.prefsPrefix), Str(h.key)];
                const int top = std::max(int(h.options.size()) - 1, 0);
                int v = std::clamp(h.defaultIndex, 0, top);
                if ([u objectForKey:key])
                    v = std::clamp(int([u integerForKey:key]), 0, top);
                s_hostVals.push_back(v);
            }
        }
        s_ptrTouches = [NSMutableArray array];
        s_view = [[TKOverlay alloc] initWithFrame:parent.bounds];
        s_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        s_view.multipleTouchEnabled = YES;
        s_view.backgroundColor = UIColor.clearColor;
        [parent addSubview:s_view];

        for (const ControlDef& d : config.controls)
        {
            Control c{ d.label, ToK(d.kind),
                       d.fx, d.fy, d.r, d.bit, d.axis };
            c.hidden = d.hiddenByDefault;
            s_controls.push_back(c);
        }
        s_gear = s_controls.size();
        s_controls.push_back({ "⚙", K::Settings, 0.62f, 0.11f, 22 });
        for (Control& c : s_controls)
            MakeLayers(c);
        s_defaults = s_controls;
        LoadLayout();
        BuildToolbar();
        s_haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        ShowLayout(s_slot);
        NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification ])
            [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*) { Apply(); }];
        Apply();
    }

    Sample Read()
    {
        std::lock_guard<std::mutex> lock(s_mutex);
        if (s_editingA)
            return {};
        Sample s = s_sample;
        for (int i = 0; i < 2; i++)
            if (s.stick[i][0] == 0 && s.stick[i][1] == 0)
            {
                s.stick[i][0] = s_ptr[i][0];
                s.stick[i][1] = s_ptr[i][1];
            }
        if (CACurrentMediaTime() < s_tapUntil)
            s.buttons |= s_cfg.tapBit;
        if (!s_cfg.keys.empty())
            if (GCKeyboardInput* ki = GCKeyboard.coalescedKeyboard.keyboardInput)
            {
                for (const KeyBind& k : s_cfg.keys)
                {
                    if (![ki buttonForKeyCode:GCKeyCode(k.key)].pressed)
                        continue;
                    s.buttons |= k.bit;
                    if (k.stick >= 0 && k.stick < 2)
                        s.stick[k.stick][k.axis & 1] += k.value;
                    if (k.trigger >= 0 && k.trigger < 2)
                        s.trigger[k.trigger] = 1.0f;
                }
                for (auto& st : s.stick)
                    for (float& v : st)
                        v = std::clamp(v, -1.0f, 1.0f);
            }
        return s;
    }

    void ApplyHostSettings()
    {
        std::vector<int> vals;
        {
            std::lock_guard<std::mutex> lock(s_mutex);
            vals = s_hostVals;
        }
        for (size_t i = 0; i < vals.size(); i++)
            if (s_cfg.settings[i].apply)
                s_cfg.settings[i].apply(vals[i]);
    }

    int GetHostSetting(const std::string& key)
    {
        std::lock_guard<std::mutex> lock(s_mutex);
        for (size_t i = 0; i < s_hostVals.size(); i++)
            if (s_cfg.settings[i].key == key)
                return s_hostVals[i];
        return -1;
    }

    void SetHostSetting(const std::string& key, int index, bool apply)
    {
        for (size_t i = 0; i < s_cfg.settings.size(); i++)
            if (s_cfg.settings[i].key == key)
            {
                const int n = int(s_cfg.settings[i].options.size());
                SetHostValue(i, std::clamp(index, 0, n - 1), apply);
                return;
            }
    }

    PointerMode GetPointerMode() { return PointerMode(s_pointerMode.load()); }

    bool PopTap(Tap* out)
    {
        std::lock_guard<std::mutex> lock(s_mutex);
        if (s_taps.empty())
            return false;
        if (out)
            *out = s_taps.front();
        s_taps.pop_front();
        return true;
    }

    bool Visible() { return s_show; }
}
