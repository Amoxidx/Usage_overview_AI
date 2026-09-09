# Architecture

```
NSStatusItem (quit/refresh)
        │
AppDelegate ── UsageStore (60s poll, last-good cache)
        │
NotchWindowController ── HoverSession
        │                     ▲
        │                     │ mouseLocation timer (~80ms)
NotchPanel (NSPanel, LSUIElement)
        │
NotchView ── ProviderRingView ×3
          └── UsageTooltipView (on hover + hovered provider)
```

### Hover
The panel frame stays at **expanded size**. The resting visual is a half-stadium that **morphs** into the flared notch (`MorphingNotch` progress 0→1) via `withAnimation(Motion.expand/collapse)` — the window is not resized, and the hosting view is not replaced (both would kill the transition).

`NotchWindowController` polls `NSEvent.mouseLocation` and expands when the cursor enters the left hot zone; collapses when it leaves the panel frame (with small slop). The panel `ignoresMouseEvents` so the transparent expanded frame never steals clicks. Do not rely on SwiftUI `onHover` alone.

### Providers
Each `UsageProvider` actor returns `UsageReading` with `windows[]` and a `headlineID` for the ring. Claude uses `weekly_all`.
