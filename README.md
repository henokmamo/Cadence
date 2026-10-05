# Cadence

**An iOS task manager that puts your tasks on your calendar for you.**

Capture a task → Cadence reads your working hours and your existing calendar → it blocks
real, honest free time for the work → when the week falls apart, one tap re-plans everything
you haven't started yet. Widgets let you complete or replan without opening the app.

- 📄 Product & architecture spec: **[SPEC.md](SPEC.md)**
- 🍎 Real Xcode project: **`Cadence.xcodeproj`** (iOS 17+, SwiftUI, SwiftData, WidgetKit)
- 🧠 Deterministic scheduling engine with a real test suite — and it's the part that's **already green**: `swift test` → 47 tests, 0 failures
- 🌐 Interactive prototype, no Xcode needed: **`prototype/cadence-prototype.html`**
- 🤖 CI that compiles the app for you on GitHub's Macs: **`.github/workflows/ci.yml`**

---

## 1. Open it

```bash
open Cadence.xcodeproj        # macOS, Xcode 15 or newer
```

Then:

1. Select the **Cadence** scheme, pick an **iOS 17+ simulator** (or your device), ⌘R.
2. The app seeds a realistic sample week (an overbooked week with deadlines, a long
   splittable task, a pinned call and an overdue item) so you can see the scheduler work
   immediately. Settings → Data → *Delete all data* clears it.
3. Press the ⟳ **Reschedule** button in the Today or Calendar toolbar to watch the plan
   get rebuilt around your pins.

App icon, accent colour and Info.plist are already wired up. There are no third-party
packages, no CocoaPods/SPM setup, and no network calls.

### Enable the widget + App Group (2 minutes, needed for the widget target)

The widget reads a shared JSON snapshot through the App Group `group.com.example.cadence`.

1. Signing & Capabilities → **Cadence** target → **+ Capability** → *App Groups* →
   add `group.com.example.cadence` (or change the ID in `Preferences.appGroupID`,
   `WidgetSnapshotStore.appGroupID`, and both `.entitlements` files).
2. Repeat for the **CadenceWidget** target.
3. Set your own bundle identifiers (`com.example.*` → yours) and pick your Team.

Without step 1–2 the app still runs; the widget simply has no snapshot to display.

### Turning on iCloud sync later (roadmap 1.3)

The data model is already shaped for CloudKit: every attribute has a default, relationships
have inverses, there are no unique constraints and deletes are soft. Enabling sync is one
argument plus a capability:

```swift
// Cadence/App/CadenceApp.swift, AppModelContainer.make()
cloudKitDatabase: .private("iCloud.com.example.cadence")
```

…plus the iCloud capability and the commented-out entitlements block. No model migration,
no sync engine to write.

### Run the tests

⌘U in Xcode, or:

```bash
xcodebuild test -scheme Cadence -destination 'platform=iOS Simulator,name=iPhone 16'
```

…or just the engine suite, anywhere (this is the one that currently passes end-to-end):

```bash
swift test
```

The engine suite covers: earliest-fit placement, deadlines-beat-priority ordering,
buffer spacing, splitting across days, busy-time collisions, the soft daily cap, pinned
blocks never moving, honest failure reporting, 25 shuffled-input determinism runs, interval
algebra, working-hours materialisation, and DST/timezone behaviour
(`America/New_York` spring-forward, plus `Africa/Addis_Ababa` and `Asia/Riyadh` where there
is no DST).

---

## 2. Building without a Mac (Windows is fine)

Xcode only runs on macOS, so the code is split into two halves:

| Half | Files | Needs | Command |
|---|---|---|---|
| **Engine** — scheduling, recurrence, working hours, formatting | `CadenceCore/` | Any Swift 6 toolchain (Linux, macOS, **Windows**) | `swift build` · `swift test` |
| **Shared contract** — the App Group snapshot the widget reads | `CadenceShared/WidgetSnapshot.swift` | Any Swift 6 toolchain | included in `swift test` |
| **Settings** — preferences bridged to the engine | `Cadence/Settings/Preferences.swift` | Any Swift 6 toolchain | `swiftc -typecheck` |
| **App + widget UI** — SwiftUI, SwiftData, WidgetKit, EventKit | `Cadence/…`, `CadenceWidget/` | Xcode on macOS | `xcodebuild build` |

```bash
# On Linux — verified green in this repo, ~3 seconds:
swift test                       # → Executed 47 tests, with 0 failures

# Syntax-check the Apple-only layer too (needs no frameworks, no Mac):
tools/ParseAllSwift.sh           # → All 34 Swift files parse cleanly.
```

That suite is the honest heart of the product: if the engine places your work wrongly, no amount
of pretty UI saves the app. It runs the algorithm against 20 engine cases, 8 working-hours cases
(the actual default week, including the 20:00–23:00 window that every day gets) and 6 recurrence
cases — plus 13 tests of the **App Group contract** between the app and the widget (round-trip,
now/next, the optimistic complete/snooze patches, corrupt-data survival). `docs/engine-test-log.txt`
is a captured run. Anything tagged `[type-checked on Linux]` in this file is code the compiler has
actually seen, not just parsed.

**For the app itself, the Mac is on GitHub.** Push this repo to GitHub and `.github/workflows/ci.yml`
does three things on every push: runs the engine tests on Ubuntu (fast), compiles the full app +
widget for the iOS Simulator on `macos-15` with code signing off, and runs the app-level tests on a
simulator. The compiled `Cadence.app` is uploaded as a build artifact you can download from the
Actions tab — no Mac required. (Getting it onto a *physical* iPhone needs Apple code signing; the
bottom of the workflow file explains the TestFlight path if you ever want it.)

If you'd rather see the scheduling rules move on your machine right now, open
`prototype/cadence-prototype.html` in a browser — it's the same algorithm in one self-contained
file, with drag-to-pin, a time scrubber and live knobs.

---

## 3. How the scheduling engine works

Pure Swift, no framework coupling (`Cadence/Scheduling/SchedulingEngine.swift`):

```
free time  =  working windows  −  ( pinned blocks ∪ user blocks ∪ imported calendar events )
order      =  earliest deadline first → priority → age → id      (total order ⇒ deterministic)
for each task (in that order), place chunks of at most maxChunk, searching in three passes:
    pass 1  the earliest gap where the full chunk fits, buffer after it, under the daily cap,
            on a day this task hasn't used yet        → "start soon", never a stunted block
    pass 2  tight fit: the chunk may be shortened to what actually fits, or reuse a day
    pass 3  last resort: daily cap, buffer and cross-day spreading all relaxed
    relaxed passes take the roomiest eligible gap (big holes get big chunks, not slivers)
report     =  every decision carries a reason string; every failure carries a shortfall
```

Design choices worth knowing:

| Choice | Why |
|---|---|
| Earliest-deadline-first ordering | Optimal for meeting deadlines on a single resource, and explainable to a human |
| Greedy, no backtracking | O(n·m), sub-millisecond at realistic sizes → safe to run during a drag and inside a widget/App Intent |
| Three relaxation passes | "Placed with a caveat" always beats "not placed" — and the caveat (*tight fit*, *no buffer*, *daily cap relaxed*) is *reported* in the task's reason, never hidden |
| Full chunks in pass 1 | A 90-minute chunk of work is never started in a 20-minute hole just because it comes first |
| Roomiest-gap choice when relaxing | A split task spends its chunk budget on the biggest holes available instead of early slivers |
| Pinned blocks are sacred | User intent beats the algorithm; unpinning is explicit |
| No RNG, total sort order | Identical inputs ⇒ identical plan, on every device, in golden tests |
| Engine stores nothing | Plans are derived data: the store keeps tasks and blocks, never a "schedule" |
| Calm completion (default) | Finishing early frees the slot but moves nothing. The next block is *offered* for pull-forward, one tap, undoable — an auto-scheduler that reshuffles your day on every checkbox feels alive in the bad way. Settings → *Pull blocks forward when I finish early* turns on the aggressive behaviour. |

Scheduling priorities when they conflict: **deadline > priority > age**, configurable
(Settings → *Deadlines first* off ⇒ pure priority order).

## 4. Project layout

```
Cadence/
├── Package.swift                SwiftPM manifest: CadenceCore + its tests (builds on Linux/Windows)
├── CadenceCore/                 ⭐ pure Foundation — no SwiftUI, no SwiftData. Compiles anywhere.
│   ├── SchedulingEngine.swift   the algorithm (EDF, chunking, three relaxation passes)
│   ├── WorkingHours.swift       the real default week + human-readable summaries
│   ├── RecurrenceRule.swift     next-occurrence maths (daily/weekly/monthly/… masks)
│   ├── Enums.swift              shared value types
│   └── Formatting.swift         portable relative-date formatting
├── CadenceCoreTests/            the 34 green tests (engine, working hours, recurrence)
├── Cadence/                     app target
│   ├── App/                     entry point, AppEnvironment, ModelContainer, background refresh
│   ├── Models/                  TaskItem, TimeBlock, TaskList, Tag, Subtask, SchedulingLogEntry
│   ├── Scheduling/              ScheduleCoordinator, RecurrenceFactory (the SwiftData side)
│   ├── Services/                TaskActionService (one funnel for every action), snapshot writer, sample data
│   ├── Calendar/                EventKit import (read-only)
│   ├── Notifications/           rolling 48-event window, digest, quiet hours, actions
│   ├── Views/                   Today, Calendar (day/week grid), Tasks, Editor, Settings, components
│   ├── DesignSystem/            theme, colours, all date formatting in one place
│   └── Settings/                Preferences (App Group-backed, shared with the widget)
├── CadenceShared/               compiled into BOTH the app and the widget
│   ├── WidgetSnapshot.swift     the tiny JSON contract between processes
│   └── TaskIntents.swift        App Intents + the App Group action/capture queues
├── CadenceWidget/               widget extension (home screen + lock screen, interactive)
├── CadenceTests/                app-level tests (models, coordinator, calm completion)
├── docs/engine-test-log.txt     a captured green `swift test` run
└── tools/                       project generator + validator (see below)
```

### Two architectural decisions you'll notice in the code

**1. Intents never open a second database.** Widget buttons run in the widget process.
Instead of risking two SwiftData containers with different migration states, they
optimistically update the shared snapshot and enqueue an action; the app drains the queue on
activation. Users get an instant widget response and the store stays single-writer.

**2. One action funnel.** Every mutation — from a tap, a lock-screen notification action, a
widget button, Siri or a bulk selection — goes through `TaskActionService` →
`ScheduleCoordinator`. Behaviour can't diverge by entry point.

## 5. Regenerating the Xcode project

The `.xcodeproj` was generated (there was no Xcode available where this was authored), and
the generator is checked in so adding files doesn't mean hand-editing `project.pbxproj`:

```bash
python3 tools/GenerateXcodeProject.py     # rebuild Cadence.xcodeproj from the files on disk
python3 tools/ValidateXcodeProject.py     # offline sanity check: dangling ids, file paths,
                                          # every Swift file assigned to exactly one target
```

Both are idempotent and dependency-free (Python 3 stdlib only). If you'd rather use
XcodeGen or Tuist, the same file lists in `tools/GenerateXcodeProject.py` translate
directly — but you don't have to.

## 6. What v1 deliberately does **not** do

Honest limitations, so nobody is surprised in TestFlight:

- **No iCloud sync yet** (1.3). Everything is on-device; the model is already CloudKit-shaped.
- **No calendar write-back.** Cadence reads your events to find free time and never creates,
  moves or deletes anything in your calendar. Opt-in write-back is 1.5.
- **No natural-language parsing.** "Every other Tuesday at 4" is a 1.2 feature; the editor is
  structured today.
- **No collaboration/sharing, no accounts, no server.** By design: it's what makes the app
  instant and private, and it is labelled *Data Not Collected* on the App Store.
- **No Live Activity yet** (1.1) — widgets and lock-screen widgets ship in 1.0.
- **All-day calendar events are ignored** when finding free time (they're usually context,
  not commitments). Timed events you declined or marked "free" are ignored too.
- **Notifications are best-effort**: iOS caps pending local notifications at 64, so Cadence
  keeps a rolling 48-event window and refills on foreground/plan change/background refresh.
- **Recurring tasks materialise one occurrence ahead**, not as a fully generated series.

## 7. Roadmap

| Version | Theme |
|---|---|
| 1.0 | Capture → schedule → notify → widgets (this build) |
| 1.1 | Live Activity for the current block, focus-mode-aware planning, smarter snooze |
| 1.2 | Natural-language quick add, templates, per-project working hours |
| 1.3 | CloudKit sync + `CKShare` shared lists |
| 1.5 | Calendar write-back, Apple Watch complications, fuller App Intents |

## 8. Settings that change the algorithm

Everything here is live and re-plans immediately:

- Working hours per weekday (multiple windows per day → lunch breaks stay free). Default is the
  real week: **Tue–Thu 10:00–18:00** (lunch free), **Fri–Mon 10:00–16:00**, and **20:00–23:00 every
  day** for a different kind of task
- Buffer between blocks · shortest block · longest block · max blocks per task
- Daily auto-planned cap (soft: exceeded rather than losing work) · planning horizon
- Deadlines-first (EDF) vs priority-first ordering — **deadline-first by default**
- Pull blocks forward when I finish early — **off by default** ("calm")
- Notification offsets, morning digest, quiet hours, deadline warnings
- Which calendars to import, and full read-only privacy story

Settings → **Why was it planned that way?** shows the last 40 scheduling decisions with the
engine's own explanation for each one.
