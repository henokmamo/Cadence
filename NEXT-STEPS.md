# What to do now

Cadence v1 is written, the engine is green, and the repo is committed and ready to push.
Three things are worth your time, in this order.

---

## 1. See it move (2 minutes, right now, on Windows)

Open **`prototype/cadence-prototype.html`** in any browser. No install, no build.

It's the same scheduling algorithm as the Swift engine, loaded with *your* week
(office hours Tue–Thu, Fri–Mon catch-up, the 20:00–23:00 block, 4 h soft daily cap).

Try these four things — they're the whole product in miniature:

1. **Drag a block** somewhere else → it becomes *pinned*, and a reshuffle will route around it.
2. Type a task into the capture box → watch where the engine puts it, and read the reason it gives.
3. Drag the **time scrubber** to, say, 16:00 → the plan rebuilds as if it were that time.
4. In the rules panel, drop the **daily cap** to 2 h → watch tasks get pushed to other days.

If the placements look right to you, the app will behave the right way — the engine is the
part I could actually test, and it's identical rule-for-rule.

**This is the step where you'll find out if the product is any good.** Everything else is
plumbing. If something feels wrong here ("it should have used my evening block", "that task
should have gone first"), tell me and I'll change the rules — that's cheap to do now.

---

## 2. Get a real compile without a Mac (15 minutes)

The one genuine gap: the SwiftUI/SwiftData layer has only been *syntax*-checked, never
type-checked, because that needs macOS. GitHub will lend you a Mac for free.

### Easiest path — no git, no command line

1. Create a free account at **github.com** (skip if you have one).
2. Click **New repository** → name it `cadence` → **Public** (see the note below) → Create.
3. On the empty-repo page click **uploading an existing file**.
4. Unzip **`Cadence-v1.zip`** and drag everything *inside* the `Cadence/` folder into the
   browser window (the `.github`, `Cadence`, `CadenceCore`, `Package.swift`, … items — not
   the outer `Cadence` folder itself). Drag-and-drop keeps the folder structure.
5. Commit. Then click the **Actions** tab.

### Better path — if you have git installed

```bash
cd path/to/Cadence          # the unzipped folder, the one containing Package.swift
git remote add origin https://github.com/YOUR-USERNAME/cadence.git
git push -u origin main
```

The history is already written and the initial commit is done.

### Reading the result — what you actually do in the Actions tab

**A picture guide with mock screens is in `docs/actions-walkthrough.html`** — open it in a browser.
It shows exactly what the Actions page looks like at each stage. The short version:

1. Click **Actions** in the repo's top menu → a row appears within ~10 seconds with a **yellow
   spinner**. Nothing to do; reload with F5 if the page looks empty.
2. Click that row's title (the commit message) → you now see **three jobs**, each with a coloured
   circle: yellow spinner = running · green tick = passed · red X = failed · grey dash = skipped
   (it didn't run because the job before it failed — not a second problem).
3. **Green?** Scroll to the bottom of that page → **Artifacts** → click **`Cadence-simulator-app`** to
   download. That's the proof it compiles. (It's an *iPhone-Simulator* build: it does **not** run on
   Windows, and it can't go on your phone without Apple code signing. It is proof, plus a head start
   for a Mac.)
4. **Red?** Click the red job → click the step with the red X (usually *Build for the simulator*) →
   copy the lines containing `error:` (the last ~20–30 lines around them) → paste them to me in chat.
   One or two rounds of fixing is normal and expected.
5. **No run at all?** The `.github` folder probably didn't upload (dot-folders hide easily). Go to the
   **Code** tab and check for `.github/workflows/ci.yml`; if it's missing, **Add file → Create new
   file**, type that path into the filename box, paste the contents of `ci.yml` from your download,
   and commit. That commit triggers the run.

### Round 2: your run got to exit code **65** — real compile errors

That is the *good* failure: the project file was read, Xcode started compiling, and it found one
genuine mistake in the code — a `UUID` being assigned to a `String` in `CadenceShared/TaskIntents.swift`
(`CompleteTaskIntent`'s convenience init; the identical init two structs down already did it right).
Fixed, and I went looking for the rest of that class by hand:

- every `UUID` ⇄ `String` boundary in the app and widget targets — audited, all consistent
- every symbol I'd flagged as "never compiled" (31 of them) — all declared, no inventions
- **and two of the files turned out to be Foundation-only**, so they now get genuinely
  type-checked and *run* on Linux: `CadenceShared/WidgetSnapshot.swift` (the widget contract —
  13 new tests) and `Cadence/Settings/Preferences.swift`

`swift test` now runs **47 tests, 0 failures** (was 34). The widget contract tests cover the
round-trip through the App Group, now/next lookups, exclusive block ends, the optimistic
complete/snooze patches, and surviving corrupt data — the stuff that decides what your widget
shows while the app isn't running.

### Round 3: the widget target now builds — one app-target error, also fixed

Your last log shows real progress worth noticing: `Ld ... CadenceWidget.debug.dylib` — the
**widget extension compiled and linked**. The failure moved to the app target, and it was the
same flavour as last time, one line:

```swift
for capture in captures {
    capture(title: capture.title, ...)      // the loop variable hides the method `capture`
}

for queued in captures {                    // fixed
    capture(title: queued.title, ...)
}
```

Rather than pay for another round-trip on the same category of mistake, this round I built a
checker for it — `tools/AuditCallSites.py` — and ran it over the whole project:

- **shadowing**: a local binding whose name hides a method, then a call to that name
- **call sites**: arguments whose labels match no declaration (the "missing argument label"
  family)

It found nothing else in the project, and I verified it genuinely works by re-introducing your
bug in a throwaway copy — it pointed straight at line 89. The tool now runs in CI's fast Linux
job as an advisory step, so this class of bug gets caught in ~1 second instead of a macOS
round-trip.

Also audited this round, since one compile error can hide others in the same batch:

| Checked | Result |
|---|---|
| `RecurrenceFactory` — every member and both initialisers it calls | all exist with matching labels |
| `TaskItem.init` / `Subtask.init` argument labels | match exactly |
| every `UUID` ⇄ `String` boundary in the app + widget | consistent |
| dotted property accesses project-wide (typo hunt) | nothing undeclared |
| `tags` / `subtasks` relationships across model copies | correct (tags shared, subtasks recreated) |

CI also got faster: the macOS test job now runs `-only-testing:CadenceTests`, because the Linux
job already runs the engine and App-Group-contract suites from the same source files — no point
billing macOS minutes twice for the same green result.

Timeline: run appears ~10 s · Linux job green ~1 min · macOS job queued 1–5 min then 3–5 min of
building · app tests after that. Roughly **ten minutes end to end**, most of it waiting.

### If your run failed with `Error: Process completed with exit code 74.`

**That was my bug, and it's fixed.** Here's what it was, because it's worth knowing:

`74` is `EX_IOERR` — xcodebuild's way of saying *"I couldn't read a file."* In practice it
means the project file couldn't be parsed. `project.pbxproj` is **not** JSON or XML; it's an
old-style (OpenStep) property list, and in that grammar the elements of an array **must be
separated by commas**. My generator wrote them space-separated:

```
children = (47EE5701… A760BE0E… EAFC953E…);      ← what my generator wrote. Xcode refuses this.
children = (47EE5701…, A760BE0E…, EAFC953E…);    ← what it writes now.
```

My old validator was regex-based ("is every id defined? path resolvable?") and sailed
straight past it; a real pbxproj parser rejects the file in a millisecond. Three things
changed as a result:

- `tools/GenerateXcodeProject.py` now emits commas — `project.pbxproj` is regenerated.
- `tools/openstep_plist.py` (new) is a strict, dependency-free reader for that grammar; it
  reports the exact byte offset instead of leaving you with a mystery code.
- `tools/ValidateXcodeProject.py` now **refuses to pass** any project file Xcode couldn't
  open (plist grammar + scheme→target references), and the CI's fast Linux job runs it, so
  this class of bug fails in ~1 second rather than on a macOS runner.

**What you need to do: re-upload the project.**

1. Unzip the new `Cadence-v1.zip`.
2. Go to your repo → **Add file → Upload files**.
3. Drag everything *inside* the `Cadence/` folder in again, exactly as you did the first
   time, then **Commit changes**.

Same paths simply overwrite the old files — nothing gets duplicated and there's nothing to
delete. (If you want the bare minimum it's `Cadence.xcodeproj` + `.github` + `tools`, but
the full drag can't get out of sync, so just do that.) The commit triggers a fresh run;
the macOS job's first step now prints the project's syntax check before it tries to build,
so if anything is wrong you'll see *which* file, in plain English.

### Reading the result

Three jobs run on every push:

| Job | Machine | Time | What it means |
|---|---|---|---|
| **Engine tests** | Ubuntu | ~40 s | The 34 scheduling tests. Should pass — it already does here. |
| **Build app + widget** | macOS | ~3–5 min | **The real question.** This is the first time the SwiftUI/SwiftData code is compiled. |
| **App tests** | macOS | ~5 min | Model + coordinator tests on a simulator. |

Then scroll down to **Artifacts** on the `Build app + widget` job → download
**`Cadence-simulator-app`**. That's a genuinely compiled `.app`.

If anything goes red, copy the error lines from the log and paste them back to me — I'll fix
them. I expect a handful: a missing import, an API whose name I misremembered, that sort of
thing. That is normal for code that has never met a real compiler.

> **Public vs private repo:** GitHub Actions is unlimited and free on *public* repos. On
> private repos the free tier gives 2,000 minutes/month, and macOS runners are billed at 10×
> — so each of these builds costs roughly 30–50 minutes of your quota (~40 builds/month).
> Either works; public is simpler and the code holds nothing personal.

> **Want it on your actual iPhone?** That needs Apple code signing ($99/yr developer
> account). The bottom of `.github/workflows/ci.yml` explains what to add. Do this *after*
> the simulator build is green — no point paying before it compiles.

---

## 3. Answer the three questions still open in `SPEC.md` §15.5

These are the only decisions left in the design, and none of them block anything:

1. **Should the evening block get its own budget?** Right now 20:00–23:00 shares the day's
   240-minute cap. If evenings are for a *different kind* of work — personal projects, admin,
   learning — they probably deserve their own separate allowance.
2. **Live Activity in 1.0?** Currently a v1.1 feature (lock-screen countdown for the block
   you're in).
3. **Sync?** Local-first is what ships. iCloud is a capability switch plus one config line
   whenever a second device shows up.

You can answer them in one sentence each and I'll fold them in.

---

## What I'd do first

Open the prototype. Everything else can wait; that's the only step that tells you whether
you actually want this app.
