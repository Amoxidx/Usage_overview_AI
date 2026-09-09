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
Panel width is **collapsed (~16pt)** vs **expanded (pill + tooltip)**.  
`NotchWindowController` polls `NSEvent.mouseLocation` and expands when the cursor enters the left hot zone; collapses when it leaves the panel frame (with small slop). Do not rely on SwiftUI `onHover` alone.

### Providers
Each `UsageProvider` actor returns `UsageReading` with `windows[]` and a `headlineID` for the ring. Claude uses `weekly_all`.
