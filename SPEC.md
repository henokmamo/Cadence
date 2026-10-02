# Cadence — Product & Technical Specification

**A task manager that puts your tasks on your calendar for you.**

Version 0.1 (draft for review) · iOS 17+ · SwiftUI + SwiftData · Local-first, sync-ready

---

## 1. One-line pitch

Most to-do apps tell you *what* to do. Cadence tells you *when* you're going to do it — it reads your
working hours and your existing commitments, then slots every task into real free time, with one-tap
"fix my day" when things slip.

## 2. Problem & positioning

| | Classic to-do (Reminders, Todoist) | Calendar-first (Fantastical, Motion) | **Cadence** |
|---|---|---|---|
| Captures tasks | ✅ | ⚠️ clunky | ✅ |
| Shows *when* | ❌ due dates only | ✅ | ✅ time-blocked |
| Decides *when* | you do | you drag or pay-per-seat | **app decides, you adjust** |
| Works offline | ✅ | often cloud-required | ✅ local-first |
| Entry price | free | $$/seat | free core |

The differentiator is the **scheduling engine**: deterministic, explainable, instant, and free.

## 3. Target user & jobs to be done

Primary: a busy knowledge worker / student with 10–40 open tasks, a calendar that's ~40–70% full, and
no desire to plan their day by hand.

Jobs:
1. *"Get it out of my head"* → capture a task in <3 seconds.
2. *"Tell me what to do right now"* → glance at Today / widget.
3. *"Don't let me miss deadlines"* → every task with a deadline gets time carved out.
4. *"Stop me from over-planning"* → if the day is overbooked, say so before I commit.
5. *"When my day falls apart, fix it"* → one tap reshuffles everything not yet started.

## 4. Scope

### v1 (this build)
- Tasks: title, notes, estimate, deadline, priority, list, tags, subtasks, completion.
- Recurring tasks: daily / weekly / monthly / yearly + custom weekday sets, "repeat from completion".
- Smart lists: Today, Upcoming, Anytime, Overdue, Completed.
- **Day & week calendar with drag-to-move time blocks.**
- **Auto-scheduler** with pinned vs. auto-placed blocks, buffers, working hours, per-day load cap.
- Local notifications: block starting, reminders, morning digest, deadline-at-risk.
- Home-screen + lock-screen widgets (interactive complete/reschedule).
- EventKit **read-only** busy-time import (never writes to your calendar in v1).
- Search, settings, dark mode, Dynamic Type, VoiceOver.

### v1 non-goals (deliberate)
- Accounts, server, collaboration/sharing.
- Cross-platform (web/Android).
- NLP parsing of dates in the quick-add field (*"every other Tue at 4"*) — v1.2.
- Location/time-based triggers beyond notifications.
- EventKit write-back (creating real calendar events) — v1.5, gated on user feedback.

### Roadmap
| Version | Theme |
|---|---|
| 1.0 | Capture → schedule → notify → widget. Ship it. |
| 1.1 | Live Activity for the current block; Focus-mode-aware scheduling; snooze rings |
| 1.2 | Natural-language quick add; templates; "deep work" energy profiles |
| 1.3 | CloudKit sync (see §9); shared lists via CKShare |
| 1.5 | Calendar write-back, Apple Watch complications, Siri full App Intents coverage |

## 5. Core concepts

- **Task** — a unit of work with an *estimate* (how long it takes) and optionally a *deadline*.
- **Block** — a task's scheduled slice on the calendar. One task may have several blocks (split).
- **Pinned vs. auto** — a block the user moved/created is **pinned** and the engine treats it as
  immovable. Auto-placed blocks are fair game for the next reshuffle.
- **Busy time** — anything the engine must plan around: pinned blocks, imported calendar events,
  manual busy blocks.
- **Horizon** — how far ahead the engine plans (default 14 days).
- **At risk** — a task whose remaining work can't fit before its deadline. Surfaced loudly, never
  silently dropped.

## 6. Information architecture

```
TabView
├── Today        — "Now" card · today's blocks · overdue · quick add
├── Calendar     — day/week grid · unscheduled tray · Reschedule button
├── Tasks        — smart lists + user lists · search · bulk schedule
└── Settings     — working hours · scheduling rules · notifications · calendar · data
```

### 6.1 Today
- **Now card**: current block with elapsed/total ring, Complete / Snooze 15m / Push to tomorrow.
- **Next up**: the single next block, with start time ("in 42 min").
- Timeline of today's blocks, gaps shown as "free 1h 20m".
- Overdue section (red), At-risk section (amber) with the reason text from the engine.
- Sticky quick-add field: type + estimate chips (15/30/60/∞) + ⏎ → lands in Inbox, auto-placed.

### 6.2 Calendar
- Day view (agenda-style, 5-minute snapping) and Week view (compact; tap a day to expand).
- Drag a block to move it → becomes **pinned** (long-press shows "Unpin / return to auto").
- Drag the bottom edge to resize; estimate updates.
- Bottom **Unscheduled tray**: tasks the engine couldn't place, each with a reason
  ("no 45-min gap before Thu 17:00"). Drag from tray into a gap to pin manually.
- Toolbar: **Reschedule** (recompute, keep pins), **Plan next 7 days**, undo toast.

### 6.3 Tasks
- Sections: Overdue · Today · Upcoming · Anytime · Lists.
- Multi-select → "Schedule now", "Move to list", "Delete".
- Swipe: complete, snooze 1 day, pin to top of Today.

### 6.4 Task editor
Title · notes · estimate (chip + custom) · deadline (date + optional hard/soft) · priority ·
list · tags · subtasks · repeat rule · **Scheduling** section:
*Auto-place* (default) / *Pin to a specific time* / *Anytime (no schedule)* / *Not before date*.

### 6.5 Settings
- **Working hours**: per-weekday windows, customizable, multiple windows per day to allow lunch
  breaks. **Default is the owner's real week** (see §15.2):
  Tue/Wed/Thu (office) 10:00–18:00 with 13:00–14:00 kept free · Fri–Mon (flexible catch-up)
  10:00–16:00 · every day 20:00–23:00 for a different kind of task. 17 windows in total.
- **Scheduling**: min chunk (default 15m), max chunk (default 90m), buffer between blocks (10m),
  max blocks per task (3), daily auto-placed cap (default 240m), plan horizon (14 days),
  **pull blocks forward on completion (default OFF — "calm", see §15.4)**,
  "keep mornings for deep work" (v1.1).
- **Notifications**: block start offset (default: on time), reminder defaults, morning digest time,
  deadline warnings, quiet hours.
- **Calendar**: import busy time from iOS Calendar (read-only), which calendars, refresh cadence.
- **Data**: export JSON, delete all, sample data, (later) sync status.

## 7. Data model (SwiftData)

Rules for the whole model layer, chosen so **CloudKit sync is a config change, not a rewrite** (§9):
every attribute has a default or is optional; no `@Attribute(.unique)`; every relationship has an
inverse and an optional (to-one) or array (to-many) shape; deletes are soft (tombstone) for synced types.

```swift
@Model final class TaskItem {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var estimateMinutes: Int = 30
    var priorityRaw: Int = 1              // 0 none, 1 low, 2 medium, 3 high
    var statusRaw: String = "open"        // open | completed | cancelled
    var deadline: Date?
    var isHardDeadline: Bool = false
    var scheduledStart: Date?             // start of first block
    var scheduledEnd: Date?               // end of last block
    var isPinned: Bool = false
    var allowsSplitting: Bool = true
    var notBefore: Date?
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var completedAt: Date?
    var sortIndex: Double = 0
    // recurrence
    var repeatFrequencyRaw: String?       // daily | weekly | monthly | yearly
    var repeatInterval: Int = 1
    var repeatDaysOfWeekMask: Int = 0     // bit 0 = Sunday … bit 6 = Saturday
    var repeatEndDate: Date?
    var repeatFromCompletion: Bool = false
    var isRecurringTemplate: Bool = false
    var templateID: UUID?
    // relationships
    var list: TaskList?
    @Relationship(deleteRule: .cascade) var subtasks: [Subtask] = []
    var tags: [Tag] = []
    var blocks: [TimeBlock] = []
}

@Model final class TimeBlock {            // a scheduled slice
    var id: UUID; var start: Date; var end: Date
    var isPinned: Bool = false
    var isUserCreated: Bool = false
    var task: TaskItem?
    var originRaw: String = "auto"        // auto | user | imported
    var externalEventID: String?          // EventKit identifier when origin == imported
}

@Model final class TaskList { name, colorHex, symbolName, sortIndex, isArchived, isInbox }
@Model final class Tag { name, colorHex }
@Model final class Subtask { title, isDone, sortIndex, parent }
@Model final class AppPreferences { /* singleton: working windows, rules, notification prefs */ }
@Model final class SchedulingLogEntry { taskID, placedAt, reason, runID }   // explainability + undo
```

Invariants (enforced in `ScheduleCoordinator`, asserted in tests):
1. A task's blocks never overlap each other or any busy interval.
2. `scheduledStart/End` always equal min/max of the task's blocks (or nil).
3. Pinned blocks are never moved or deleted by an automatic reshuffle.
4. Sum of a task's block durations == `estimateMinutes` (unless deliberately partial).
5. Same inputs ⇒ same plan (deterministic tie-breaking by `createdAt`, then `id`).

## 8. The scheduling engine ⭐

Implemented as **pure Swift** in `Scheduling/SchedulingEngine.swift` — value types in, value types
out, zero SwiftData/framework coupling, so it is fully unit-testable and trivially deterministic.

### 8.1 Inputs
```swift
ScheduleProblem(
  now: Date, horizon: DateInterval,
  workingWindows: [DateInterval],     // concrete instants from weekday rules, timezone-resolved
  busy: [BusyInterval],               // pinned blocks + imported events + manual busy
  tasks: [SchedulableTask],           //  id, estimate, deadline, priority, createdAt,
                                      //  allowsSplitting, notBefore, pinnedStart/End
  policy: SchedulingPolicy            //  buffer, min/max chunk, max chunks/task, daily cap, EDF toggle
)
```

### 8.2 Algorithm — "EDF-first, split-aware earliest-fit"

```
1  free ← workingWindows  minus  merged(busy ∪ future pinned blocks), clipped to [now, horizon]
2  order ← tasks sorted by:
        deadlines first (earliest deadline first, EDF — optimal for meeting deadlines on one resource),
        then priority (high→low), then age (oldest first), then id   [stable ⇒ deterministic]
3  for each task in order:
     remaining ← estimate;  chunks ← 0
     while remaining > 0 and chunks < chunkBudget:        # 3 normally, 1 when splitting is off
         desired ← min(remaining, maxChunkMinutes)
         slot ← best placement in `free`, searched in three passes:
             pass 1  full comfort : chunk == desired, buffer fits after it, under the daily cap,
                                    not a day this task already used; earliest such gap wins
                                    ("start soon") — never produces a stunted block
             pass 2  tight fit    : chunk may be shortened to what actually fits, or reuse a day,
                                    still under the cap
             pass 3  last resort  : the soft daily cap, the buffer and cross-day spreading are all
                                    relaxed
                 passes 2–3 take the *roomiest* eligible gap, so a split task spends its chunk
                 budget on the biggest holes of the day instead of early slivers.
                 Ties break on earliest start, so the result stays deterministic.
         if a slot was found: place the block, shrink `free` leaving buffer room,
                              remaining -= duration, chunks += 1
         else: stop placing for this task
     if remaining == 0        → status .scheduled
     else if anything placed  → status .partial(remainingMinutes)   # reported, never hidden
     else                     → status .unscheduled(reason)
4  risk pass: each task that is unscheduled or short of its deadline emits
   .atRisk(shortfallMinutes); every relaxation actually used (pass 2 or 3) is appended to that
   task's reason string in plain words
5  return plan + per-task reasons:
     "Split into 3 blocks to fit around your day (tight fit)"
     "Placed 1h 20m; 10m doesn't fit before 5:30 PM"
     "No free gap big enough — the longest is 20m"
```

Consequences worth knowing:
- A 90-minute chunk of work is never *started* in a 20-minute hole; the relaxed passes exist for
  "something is better than nothing", and they say so in the reason string.
- When nothing can be placed, the reason is concrete: how much still needs placing and the longest
  gap the engine could find. The unscheduled tray and Today's "Won't fit" section render it.

### 8.3 Design decisions & why
- **EDF ordering** — provably optimal for feasibility when tasks are single-resource and
  preemptible-in-chunks; our chunking is a bounded relaxation of that, and it's *explainable* to a user.
- **Greedy earliest-fit, no backtracking** — O(n·m), sub-millisecond at realistic sizes (n≤500,
  m≤200 free intervals), so it can run synchronously on the main thread during a drag, and inside a
  widget/App Intent without a background task. No ML, no cloud, no waiting.
- **Determinism** — no randomness, total ordering with `id` as final tiebreak. The same
  plan is produced on the phone and in the widget; tests are golden-file based.
- **Splitting** — respects human reality (a 6-hour task must span days) while capping fragmentation
  (`maxChunksPerTask`, prefer a fresh day, never chunks < `minChunkMinutes`, and pass 1 refuses to
  start a full chunk in a hole too small for it).
- **Deadline vs. priority order** — deadline-bearing tasks are never starved by an inbox full of
  undated ones. `policy.edfEnabled = false` switches to pure priority order for "do important stuff first"
  users; both modes share one code path.
- **Soft daily cap** — a *soft* constraint (relaxed rather than failing) prevents the classic
  auto-scheduler failure mode of stacking 12 hours into one heroic day; when it is relaxed the task's
  reason says so.
- **Roomiest gap in the relaxed passes** — first-fit alone fragments long tasks into early slivers and
  leaves the big holes for later, less important work. Passes 2–3 therefore choose the largest eligible
  gap, which packs the day better while keeping pass 1's "start soon" bias.
- **Pins are sacred** — user intent always beats the algorithm; unpinning is explicit.
- **Calm by default** — finishing early never yanks the rest of the day forward. Completing a task
  frees its slot and, if the next auto block today starts later than the freed time by at least two
  chunks, a banner *offers* to pull it forward ("you finished early — move the 14:00 block up?").
  One tap, undoable. `policy.pullForwardOnCompletion = true` restores the aggressive behaviour:
  compact immediately, with an undo toast. Rationale: an auto-scheduler that reshuffles your day
  every time you tick a checkbox feels alive in the bad way.

### 8.4 Recompute triggers
Task created/edited/completed · block moved or resized · day rollover · calendar import changes
(`EKEventStoreChanged`) · app foreground if `planIsStale` (>15 min since last run) · manual
Reschedule · widget/App Intent action.

Recomputes are **incremental**: pinned and already-started blocks are frozen; only future auto blocks
of affected tasks are recomputed, then a compaction pass removes gaps left behind — *unless* the
completion was what triggered the recompute and pull-forward is off (§15.4), in which case the gaps
are preserved and only *offered* for compaction.

### 8.5 Explainability
Every placement carries a `reason` string and every failure a concrete reason
(`"No 45-min gap before Thu 17:00 — short by 2h 15m"`). Reasons render in Today's at-risk rows, the
unscheduled tray, and the undo toast. If the engine can't explain a decision, that's a bug.

### 8.6 Test plan (`CadenceTests/SchedulingEngineTests.swift`)
| Case | Expected |
|---|---|
| Simple fit | one block, exactly the estimate, inside working hours |
| Deadline two-pass | tight-deadline task placed before a high-priority undated one |
| Buffer respected | next block starts ≥ buffer after previous end |
| Splitting | 6h task, 90m max chunk ⇒ 4 blocks ≤3 days, each ≥ min chunk |
| Busy collision | block never overlaps an imported event |
| Daily cap | tasks spread across days instead of one 12h day |
| Pinned immovable | reshuffle leaves pinned block byte-identical |
| Unschedulable | reports remaining minutes + human reason |
| Determinism | 200 shuffled input orders ⇒ identical plan |
| Horizon edge | task past horizon ⇒ unscheduled, not silently dropped |
| DST / timezone rollover | no zero-length or off-by-one-hour blocks (add: `Asia/Riyadh`, `Africa/Addis_Ababa`, `America/New_York` DST dates) |

## 9. Data & sync strategy (your "not sure yet" — recommendation)

**Decision: local-first SwiftData now, CloudKit-ready from day one; add sync in 1.3 without touching
the model layer.**

Why local-first: instant launch, works on a plane/offline, no backend cost, no accounts, best privacy
story, faster to ship and to review on the App Store.

Why CloudKit-ready: the §7 rules (defaults/optionals everywhere, no unique constraints, inverses on all
relationships, soft deletes, monotonic `updatedAt`) are exactly what `NSPersistentCloudKitContainer`
requires — they're the parts that force a model migration if you get them wrong up front. Follow them
and enabling sync later is: add the CloudKit capability, add `.autosave`/`.privateCloudDatabase` config,
handle account-status UI.

Not chosen: a custom backend. It buys multi-user sharing and web access you don't need for v1, at the
cost of auth, hosting, GDPR, and an offline-sync engine to maintain. `CKShare` covers shared lists later
in the Apple ecosystem with no servers.

Sync conflict policy when it lands: last-writer-wins per field via `updatedAt`, with scheduling plans
recomputed locally on each device (plans are derived data — never synced, never authoritative, so two
devices can't fight over them).

## 10. Notifications

Local-only (`UNUserNotificationCenter`), no push server.

| Trigger | Default | Notes |
|---|---|---|
| Block starting | at start time | actions: **Complete**, **Snooze 15m**, **Skip** |
| Task reminder | –10 min before block | per-task override |
| Deadline risk | 24h before a hard deadline if not fully placed | includes shortfall |
| Morning digest | 07:30 (configurable) | "3 blocks today, 4h 20m planned, first 09:30" |
| Day-in-review | optional 21:00 | completed vs. planned |

Constraint: iOS keeps **64 pending local notifications**. A `NotificationScheduler` keeps a rolling
window of the next ~48 events (≤7 days ahead), re-filling on foreground, on plan change, and from a
`BGAppRefreshTask`. Actions are `UNNotificationAction`s handled by an App Intent so they work from the
lock screen and the widget without launching the app fully.

Quiet hours suppress block-start notifications; deadline warnings always fire.

## 11. Widgets & Live Activity

Extension `CadenceWidget`, sharing the app's code via an App Group + shared files (no snapshots of the
SwiftData store over the group container in v1 — too fragile with migrations):

- `WidgetSnapshot` (Codable, small JSON, written to `group.com.example.cadence` on every plan change):
  now/next block, today's block count + planned minutes + completed minutes, overdue count, top 3
  at-risk, generator timestamp.
- **Today (systemMedium)**: current block + progress bar, next block time, "Reschedule" button.
- **Now (systemSmall / accessoryCircular)**: ring with time remaining in current block.
- **Up Next (accessoryRectangular, lock screen)**: next block, start time, complete button.
- Interactive buttons via `AppIntent`s (`CompleteCurrentBlockIntent`, `RescheduleDayIntent`,
  `SnoozeBlockIntent`) that write through a shared `TaskActionService` and reload timelines.
- Timeline policy: refresh at every block boundary + a 15-minute safety net; `.atEnd` fallback.
- v1.1: **Live Activity** for the current block (lock screen + Dynamic Island countdown).

## 12. Calendar (EventKit) integration

v1 = read-only. `NSCalendarsFullAccessUsageDescription` (iOS 17+; also set the legacy
`NSCalendarsUsageDescription` for older paths). Read events for the plan horizon, respect per-calendar
toggles, write nothing back, and cache imported busy intervals as `TimeBlock(origin: .imported)` keyed
by `eventID`/occurrence for incremental updates. If permission is denied the app works fine with zero
imported busy time — never nag, explain once in Settings. v1.5 adds write-back (opt-in, per list).

## 13. Non-functional requirements

- **Performance**: cold launch < 400 ms to Today's first frame; reschedule < 50 ms for 500 tasks;
  list scrolling 60/120 fps with `List` + lazy rows; snapshot write < 5 ms.
- **Battery**: no polling; EventKit change notifications + BGAppRefresh only.
- **Accessibility**: Dynamic Type through XXL, VoiceOver labels on blocks ("Deep work report, 09:30 to
  11:00, 90 minutes, in progress"), color never the sole signal (icons + text too), Reduce Motion
  respected (no animated block shuffles), 44pt minimum hit targets, full keyboard/Voice Control for
  the editor.
- **Privacy**: no analytics SDK, no network calls in v1, everything on device. App Store privacy label:
  "Data Not Collected". Calendar data stays on device.
- **Localization**: all strings in `Localizable.strings`; week start configurable (Monday default);
  12/24-hour honouring locale; scheduling is fully timezone/DST-aware (blocks stored as instants,
  rendered in the device timezone). *Stretch: Ethiopian-calendar display option for your region —
  affordable later because all date math happens on `Date`/`Calendar`, with display formatting isolated
  in `DesignSystem/DateFormatting.swift`.*
- **Error handling**: engine never blocks the UI; a failed plan leaves the previous plan intact and logs
  to `SchedulingLogEntry`.

## 14. Milestones (suggested, 6–8 weeks solo)

| Week | Deliverable |
|---|---|
| 1 | Models + ModelContainer + seed data + Today list (no scheduling) |
| 2 | Engine + unit tests (green) + ScheduleCoordinator wiring |
| 3 | Task editor, lists, smart lists, search |
| 4 | Calendar day/week grid + drag/resize + pins + unscheduled tray |
| 5 | Notifications + actions + digest |
| 6 | Widget extension + App Intents + App Group snapshot |
| 7 | EventKit import, settings, accessibility + localization pass |
| 8 | TestFlight: 10 users, instrument plan overrides, ship 1.0 |

## 15. Decisions (was: open questions)

### 15.1 Resolved — deadline-first ordering ✅ *(answered 2026-10-02)*
> "1. Deadline Default"

Deadline-bearing tasks are always scheduled ahead of undated ones; a task due tomorrow outranks an
undated high-priority task. `policy.edfEnabled = false` still switches to pure priority order in
Settings, and both modes share one code path (§8.3). **Default: deadlines first.**

### 15.2 Resolved — working hours are the owner's real week ✅ *(answered 2026-10-02)*
> "Tue/Wed/Thu 10:00–18:00 are office hours, anything after 20:00 is for different tasks,
>  Fri–Mon are flexible (finish tasks + personal time)"

| Days | Windows | Intent |
|---|---|---|
| **Tue, Wed, Thu** | 10:00–13:00 · 14:00–18:00 · 20:00–23:00 | Office days. 13:00–14:00 stays free for lunch — a real meeting-shaped gap the engine must route around. |
| **Fri, Sat, Sun, Mon** | 10:00–16:00 · 20:00–23:00 | Flexible catch-up: finish what's left, protect personal time by keeping the evening shift in one predictable slot. |
| **Every day** | 20:00–23:00 | The "different tasks" window — v1 treats it as ordinary capacity, but it is modelled as its own window so a `list`-aware policy can reserve it later without re-cutting the week. |

17 windows total, encoded in `WorkingHours.defaultWindows` (`Calendar` weekday numbering:
1 = Sun … 7 = Sat) and humanised in Settings via `WorkingHours.summary(of:)`. Tests:
`CadenceCoreTests/WorkingHoursTests.swift` (8 cases).

### 15.3 Resolved — one soft daily cap, evenings included ✅ *(answered 2026-10-02, implicitly)*
The 240-minute daily auto-placed cap applies per calendar day across all of that day's windows,
evening included; it stays **soft** (pass 3 relaxes it rather than leaving work unplaced) and says so
in the task's reason string when it does. If the evening block should have its *own* budget, that is a
one-line policy change — say the word.

### 15.4 Resolved — calm completion ✅ *(answered 2026-10-02)*
> "pull-forward should be calm"

Finishing a block early **does not** move anything. The freed time is returned to the day; if the
next auto block today starts later than the freed slot by ≥ 2 × `minChunkMinutes`, a banner offers a
one-tap "pull forward" (undoable). Settings has **"Pull blocks forward when I finish early"**, default
**off**. Implementation: `Preferences.pullsBlocksForwardOnCompletion`,
`ScheduleCoordinator.complete(task:at:) -> CompletionOutcome { nextInstance, suggestion }`, and
`PullForwardSuggestion` rendered by `ToastBanner` in `RootView`.

### 15.5 Still open
1. **Evening budget** — should 20:00–23:00 have its own daily cap instead of sharing the day's
   240 minutes (see §15.3)?
2. **Live Activity in 1.0** — currently planned for v1.1 (§11).
3. **Sync** — local-first is the shipped default (§9); flip on iCloud when a second device arrives.

## 16. How this builds and how it is verified

The codebase is split so that the part with all the logic compiles *anywhere*, and the part with the
UI compiles where the UI frameworks actually exist.

| Layer | What it is | Built by | Verified in this repo |
|---|---|---|---|
| **CadenceCore** | Pure Foundation. The scheduling engine, recurrence maths, working-hours rules, formatting. Zero platform dependencies — no SwiftUI, no SwiftData, no UIKit. | `swift build` / `swift test` on Linux, macOS, or Windows | ✅ green: `swift build` clean, `swift test` = **34 tests, 0 failures** (`docs/engine-test-log.txt`) |
| **Cadence** (app), **CadenceWidget**, **CadenceTests** | SwiftUI, SwiftData, WidgetKit, EventKit, App Intents | Xcode on macOS (`xcodebuild`), or the `ios-build` / `ios-tests` CI jobs | ⚠️ not compiled in this environment — no macOS/Xcode available. Syntax-checked only. |

```bash
# Engine tests — anywhere Swift 6 is installed (this is what CI runs first):
swift test                       # 34 tests, ~0.3 s

# App + widget — needs macOS with Xcode 16:
xcodebuild build -project Cadence.xcodeproj -scheme Cadence \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

`.github/workflows/ci.yml` runs both on every push: `engine-tests` on Ubuntu (fast feedback on the
algorithm) and `ios-build` / `ios-tests` on macOS 15 (the real answer to "does it compile?"), the
latter uploading a signed-less simulator `.app` as a downloadable artifact. This matters for a
Windows-based owner: push the repo to GitHub and the Actions tab compiles the app for you.

### 16.1 Honest limitations of v1 as delivered
- The SwiftUI/SwiftData layer has **never been type-checked** — only parsed. Expect first-build
  fixups (missing imports, an API name or two). The engine underneath it is tested and stable.
- The widget and App Intents mutate the App-Group snapshot and enqueue actions rather than opening
  the SwiftData store directly (the widget process must not open the store); this path is designed
  and documented but not runtime-proven until built on a device.
- Notifications, calendar import, and drag-to-pin all require a real device/simulator to exercise.
- `prototype/cadence-prototype.html` is the behavioural reference for the engine: it is a
  self-contained page (no build step, no network) that mirrors §8.2 and is the fastest way to *feel*
  the scheduling rules on a Windows machine. Its JS passes `node --check`; the UI itself is
  exercised only by opening the file.
