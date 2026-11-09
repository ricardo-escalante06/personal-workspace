# Personal Workspace — Design Doc v0.3

**Date:** 2026-11-08 · **Supersedes:** `productivity_workspace_design_v0_2.docx`
**Status:** Architecture and core UX decided. Visual details need a prototype pass on real screens.

---

## 0. What changed from v0.2

| Area | v0.2 | v0.3 | Why |
|---|---|---|---|
| Laptop client | Next.js web app | **Native SwiftUI macOS app** | One Swift codebase for Mac, iPhone and widgets. Scope/recurrence/template logic lives in one shared package instead of being written twice. |
| Google Calendar | Server OAuth sync in Phase 4 | **MVP-critical. Read and write through EventKit in Phase 2** | You need class events on day one. EventKit uses the Google account already added to macOS/iOS Calendar, so the app needs no OAuth, webhooks or token storage. |
| Templates | Static category presets; template builder deferred | **Real templates:** Class template with assignment series, plus "Save as template" for any container | Your main ask. |
| Big projects | Same dashboard as everything else | **Project containers get a Kanban board** with custom columns | Your main ask. |
| Dashboard calendar | Compact 7-day time grid | **7-day week strip with task chips** (your "General Tasks" screenshot), with "Open in Calendar" going to the full time grid | Your second screenshot. The time grid now lives only in the full Calendar. |
| Container kinds | folder, project | **folder, list, class, project.** Folders only organize (Personal, School, Clubs). Lists hold tasks, and classes and projects are lists with extras. | It's clear where a task lives, and classes and projects need different defaults and views. |
| Recurrence storage | Generated occurrence rows on a rolling horizon | **Occurrences computed on the fly; only overrides are stored** | No background generation jobs, nothing to keep idempotent. |

Everything else in v0.2 still holds: one canonical task store, deadline ≠ scheduled work, independent completion per recurring occurrence, scoped dashboards that include descendants, and a fixed V1 dashboard layout.

---

## 1. Product summary

A personal productivity app for **Mac and iPhone** that replaces Notion for tasks and planning. Work is organized in a tree: **folders** for areas of life (Personal, School, Clubs) containing **lists**, **classes** and **projects** that hold the tasks. Every node has the same scoped **dashboard**: Today, a week strip, upcoming deadlines and child items. **Classes** come from a template that sets up categories and generates the whole term's assignments. **Projects** add a **Kanban board**. A full **Calendar** shows Google Calendar events next to your scheduled work blocks.

### Goals
1. Capture a task in under 3 seconds from anywhere: ⌘N on Mac, a sheet or widget on iPhone.
2. Set up a new class for a term in under 2 minutes with a template.
3. Run a multi-week project on a board without losing deadlines or calendar context.
4. See Google Calendar events and your own work blocks in one calendar, editable on both devices.
5. Keep one canonical record per task. Every view and device is a projection of it.

### Non-goals (V1)
Collaboration or sharing, a Notion-style document editor, AI scheduling, gradebook/grade weighting, movable dashboard modules, Android or web clients.

---

## 2. Information architecture

```
All Workspace (root)
├── Personal                    folder
│   ├── General                 list    (default list for Personal)
│   ├── Errands                 list
│   └── Apartment Move          project (board)
├── School                      folder
│   ├── CS61A                   class   (term: Fall 2026)
│   ├── CS61B                   class
│   │   └── Project 3           project (board, nested in the class)
│   └── EE66                    class
└── Clubs                       folder
    ├── Robotics                folder
    │   ├── General             list
    │   └── Competition Bot     project (board)
    └── HEI                     list
```

**Two layers: folders organize, lists hold tasks.**

- **Container kinds**
  - `folder`: organizes only. It holds other containers and **never holds tasks directly**. Top-level areas (Personal, School, Clubs) are folders. Dashboard view only.
  - `list`: the general-purpose task container, such as Personal › General, Errands or a small club. Views: Dashboard and List.
  - `class`: a **list with class extras**: a term (start/end dates, skip weeks), class categories and assignment rules. Views: Dashboard and Assignments.
  - `project`: a **list with a board**: board columns, an optional target date and progress. Views: Dashboard, Board and List.
- `list`, `class` and `project` are the **task-holding kinds**. They share the same behavior and differ only in extras and default views. In code: `kind.holdsTasks == (kind != .folder)`.
- **Nesting rules:** folders can contain any kind. Task-holding containers can contain child projects (e.g. CS61B › Project 3) but not folders. That keeps the tree shaped as "areas → lists → (optional) sub-projects".
- **Converting kinds:** a `list` can become a `class` or `project` (and back) without losing tasks. Conversion only adds or hides the extras. A folder can't become a list while it has children.
- **Default list per folder:** every folder has a `default_list_id`. Quick-add from a folder's dashboard (e.g. Personal) puts the task in that list. The first time you quick-add in a folder with no lists, the app creates "General" automatically. You can change the default list in folder settings.
- **Tasks** belong to exactly one task-holding container, or to the Inbox (`container_id = null`). Subtasks are tasks with `parent_task_id`. They are not containers.
- **Scope:** a container's views include all descendant tasks by default. Root includes everything.

---

## 3. Visual design

Reference: your two screenshots (Notion Calendar week view and the Notion "General Tasks" week strip). The look should be **calm, dense and legible**. It should read like a well-made native tool, not a landing page.

### 3.1 Rules (what "not AI slop" means here)
- **No** gradients, glows, glassy cards everywhere, emoji as icons, oversized rounded "bento" cards, decorative illustrations or drop shadows on flat content.
- **Color comes from your data.** Project and class colors are the only saturated color on screen. Chrome stays neutral grey.
- **Hairlines, not boxes:** 1px separators at low contrast. Cards only where something is draggable, such as calendar blocks and board cards.
- **Type does the hierarchy:** SF Pro with 2–3 weights, tabular numbers for times and counts.
- **Small radii:** 6px on blocks and cards, 8px on popovers. Spacing on a 4pt grid.
- Use native controls (SwiftUI `List`, `Table`, `NavigationSplitView`, toolbars, `.inspector`) so the app feels like a Mac app. Use the system material only on the sidebar and popovers.

### 3.2 Tokens (dark is the default; light mode mirrors the same semantic names)

| Token | Dark | Use |
|---|---|---|
| `bg.canvas` | `#191919` | Main background (screenshot base) |
| `bg.weekend` | `#1E1E1E` | Weekend columns and today's column tint |
| `bg.raised` | `#232323` | Popovers, inspector |
| `line.hairline` | `#2A2A2A` | Grid lines, separators |
| `text.primary` | `#EDEDED` | Titles |
| `text.secondary` | `#9B9B9B` | Times, metadata |
| `text.tertiary` | `#6B6B6B` | Past events, hour labels |
| `accent.now` | `#E5484D` | Current-time line, today badge (red pill like "Sun 8") |
| `accent.action` | `#2F81F7` | Primary button ("New"), focus ring |

**Container color palette.** Each color has an *accent* (left bar and checkbox) and a *fill* (block background, roughly the accent at 30% over the canvas). The values below match the screenshot hues.

| Name | Accent | Fill |
|---|---|---|
| Plum | `#B65FD1` | `#4A3550` |
| Violet | `#8B7BE0` | `#3F3A63` |
| Green | `#4FA66A` | `#2C4433` |
| Rust | `#E07A45` | `#5E3524` |
| Steel | `#5AA9E6` | `#2B3F50` |
| Gold | `#D6A740` | `#4D4126` |
| Rose | `#E0607E` | `#55303A` |
| Grey | `#8A8A8A` | `#3A3A3A` |

### 3.3 Calendar block anatomy (from screenshot 1)
- A filled rectangle in the container's *fill*, with a **3px left bar** in the *accent* color.
- Title in 12–13pt semibold `text.primary`. The time range goes on the second line in `text.secondary` when the block is tall enough.
- **Past** blocks drop to about 60% opacity. **Completed** tasks get a strikethrough title and a check glyph, and keep their color.
- **Due-date markers** sit in the all-day row with a small flag glyph. Scheduled work blocks sit on the time grid. They must look different without relying on color.
- **Tentative or declined** external events use a dashed outline and transparent fill (like "weekly HEI meeting").
- **Overlaps** share the column width side by side, as on Mon 6:30 PM in the screenshot.
- **Now line:** a 1px `accent.now` line across the week, with a red time pill in the gutter ("3:24 PM").

### 3.4 Dashboard week strip (from screenshot 2)
- Seven equal columns, Sun–Sat (week start configurable), with day number top-right and today as a red circle.
- Each cell lists **chips**: a task title with a container color dot. Due tasks show a flag, scheduled tasks show a time, and done tasks are struck through. All-day events show as chips; timed events are hidden by default (toggle).
- The header row holds the month label, `‹ Today ›` navigation and **"Open in Calendar"**, which opens the full Calendar on that week and scope.
- Overflow shows "+3 more", which opens the day in the Calendar.
- Click an empty part of a cell to quick-add a task due that day. Drag a chip to another day to change its **due date**, or its schedule if it's a scheduled block. A tooltip says which one changes.

---

## 4. Screens

### 4.1 Mac app layout
`NavigationSplitView` with three regions:

```
┌────────────┬───────────────────────────────────────────────┬──────────────┐
│ Sidebar    │ Content                                        │ Inspector    │
│            │                                                │ (task detail,│
│ ⌂ Today    │ School › CS61B           [Dashboard|Assign.] + │  toggle ⌘I)  │
│ ▢ Inbox  3 │ ─────────────────────────────────────────────  │              │
│ ▦ Calendar │  2 due today · 1 overdue · 6 this week · 40%   │              │
│            │                                                │              │
│ WORKSPACE  │  TODAY                     │ UPCOMING          │              │
│ ▾ School   │  ☐ HW 9          Fri       │  Thu  Quiz 4      │              │
│    CS61A   │  ☐ Study Quiz 4  7–8p      │  Fri  HW 9        │              │
│    CS61B   │                            │  Mon  Proj 3 ckpt │              │
│    EE66    │  ── WEEK ───────────── ‹ Today ›  Open in Cal ─ │              │
│ ▸ Engin.   │  Sun │ Mon │ Tue │ Wed │ Thu │ Fri │ Sat      │              │
│ ▸ Personal │      │     │Study│     │Quiz4│HW 9 │          │              │
│            │                                                │              │
│            │  ASSIGNMENTS  All·HW·Quiz·Exam·Lab·Project      │              │
│            │  …                                             │              │
│            │  CHILDREN  (cards for nested containers)       │              │
└────────────┴───────────────────────────────────────────────┴──────────────┘
```

**Sidebar:** Today, Inbox, Calendar, then the workspace tree. Supports drag to reorder or re-parent, right-click → New folder/list/class/project/from template, and a color dot per node.

**Keyboard (priority):** ⌘N quick add · ⌘K command palette (jump to any container or task) · ⌘1/2/3 switch views · ⌘I inspector · ← → change week, T jumps to today · Space toggles complete on the selected task · ⌘Z undo.

### 4.2 Dashboard (fixed V1 layout, same for every scope)
1. **Header:** breadcrumb, title, color and kind icon, view switcher (folder: Dashboard only · list: Dashboard / List · class: Dashboard / Assignments · project: Dashboard / Board / List), quick-add button (goes to the default list in a folder).
2. **Metrics line:** due today, scheduled today, overdue, next 7 days, completed today, progress. This is one line of text, not big number tiles.
3. **Today** (left) and **Upcoming 7 days** (right) side by side on wide windows, stacked on narrow ones.
4. **Week strip** (§3.4).
5. **Task list:** grouped by category with filter chips. Class views default to category grouping; project views default to board-column grouping.
6. **Children:** compact rows or cards for direct child containers, with progress and next deadline.

Today rules (default; configurable in Settings): tasks scheduled today, plus due today, plus recurring occurrences for today, plus overdue (collapsed under an "Overdue (n)" disclosure). One row per task, however many work blocks it has.

### 4.3 Full Calendar
- **Day / Week / Month**, Week by default. Matches screenshot 1: hour gutter, all-day row, now line, weekend shading, scrolls to 8 AM on open.
- **Sources:** your schedule blocks, task due markers, and EventKit calendars (Google and others). Each calendar can be toggled from a source list in the sidebar.
- **Create:** drag on empty time to open a popover asking "Task block or Event?". *Task block* asks for a title or an existing task, and destination. *Event* asks for a title and target calendar (writable Google calendars listed).
- **Edit:** move or resize your blocks (changes `scheduled_*` only, never the due date). External events can be moved or resized when their calendar is writable, with a confirmation saying "This updates Google Calendar".
- **Scope filter:** "All" by default. When opened from a container, it shows that scope's tasks plus events mapped to that scope (§7.3).

### 4.4 Project Board (Kanban)
- Columns are defined **per project**. Defaults: Backlog · To do · In progress · Review · Done. Columns can be renamed, reordered, added or deleted, and each has an optional WIP limit.
- Each column **maps to a status** (`not_started` / `in_progress` / `done` / `cancelled`). Dragging a card into a `done` column completes it. Checking a task off elsewhere moves it to the first `done` column. Status and column never disagree.
- **Cards** show the title, due date (red when overdue), category badge, subtask progress (2/5), a calendar glyph if it has scheduled blocks, and priority.
- **Swimlanes** (optional): none, child project, category or priority. Nested projects appear as a swimlane or are filtered out with a "This project only" toggle.
- **Milestones:** a task with category `Milestone` shows as a diamond marker in the week strip and calendar all-day row.
- A board card *is* the task. Opening it gives the same inspector as everywhere else.

### 4.5 Class Assignments view
A table with columns for type, title, due, status, scheduled, and estimate, grouped by category. It also shows the class's **assignment rules** with "Edit series" (§6.2), so you can shift every remaining HW deadline in one step.

### 4.6 iPhone app
Tabs: **Today · Calendar · Browse · (+) quick add**.
- **Today:** checklist with swipe to complete or defer.
- **Calendar:** 3-day time grid by default, with agenda and month available.
- **Browse:** tree → container dashboard (stacked layout) → board as horizontally paged columns.
- **Quick add:** a sheet with a natural-language title field (§6.4).
- **Widgets:** an interactive *Today* checklist (small/medium), *Next up* (next block or deadline), and a Lock Screen accessory showing the next deadline. Uses App Intents for completing tasks.
- **Shortcuts/Siri:** "Add task to CS61B", "What's due today".

---

## 5. Task model and date semantics

One `tasks` table for every kind of work. Homework, quizzes, exams, labs and milestones are **categories**, not separate tables.

| Field | Notes |
|---|---|
| `id`, `owner_id`, `container_id?`, `parent_task_id?` | null container = Inbox |
| `title`, `notes` (Markdown) | |
| `category_id?`, `priority?` (0–3) | |
| `status` | `not_started` · `in_progress` · `done` · `cancelled` |
| `due_date?` (date), `due_time?` (time), `due_tz?` | Stored as a local date plus an optional time, so date-only deadlines never drift across time zones. |
| `estimated_minutes?`, `source_url?` | |
| `board_column_id?`, `board_rank` | Board position (fractional rank string) |
| `sort_rank` | Manual order in lists |
| `rrule?`, `rrule_tz?`, `rrule_anchor?` | Present means this task is a **recurring series** |
| `generated_by_rule_id?` | Set when created by a class assignment rule |
| `template_origin_id?` | Provenance when created from a template |
| `completed_at?`, `created_at`, `updated_at`, `deleted_at?` | `deleted_at` is a sync tombstone |

**Schedule blocks** (`task_schedule_blocks`): zero or more per task. Each has `id, task_id, starts_at, ends_at, occurrence_key?`. Moving a block never creates a new task.

**Invariants**
- `due_*` and schedule blocks are independent. Dragging a block never changes the due date.
- Completing a task completes it once, however many blocks it has.
- Status and `board_column_id` agree whenever the task is on a board.

---

## 6. Templates

### 6.1 Template model
A template is a saved **container subtree spec**: containers, categories, board columns, tasks with subtasks, and assignment rules. All dates are stored as **offsets from an anchor** (term start, project start or "today"). Templates can declare **variables** that the apply sheet asks for.

```jsonc
{
  "kind": "class",                       // folder | list | class | project | task
  "name": "Class",
  "variables": [
    {"key": "code",  "label": "Course code", "type": "text"},       // "CS61B"
    {"key": "term_start", "type": "date"}, {"key": "term_end", "type": "date"},
    {"key": "color", "type": "color"}
  ],
  "container": {"name": "{{code}}", "kind": "class", "color": "{{color}}"},
  "categories": ["Homework", "Lab", "Quiz", "Exam", "Project", "Reading"],
  "assignment_rules": [ /* §6.2, optional, prompted in apply sheet */ ],
  "tasks": [],
  "board_columns": null
}
```

**Kinds of templates**
- **Class (built-in):** creates the class container, enables class categories and walks you through assignment series.
- **Area (built-in):** creates a folder with a "General" default list, e.g. a new club. Optionally includes starter lists.
- **Project (built-in):** creates the project with default board columns, and optionally starter milestones.
- **Custom:** "Save as template…" on any container or task captures its structure. Completion state and real dates are dropped; dates become offsets from the container's anchor.
- **Task template:** a single task with subtasks and defaults, e.g. "Lab write-up: pre-lab, collect data, write, submit".

**Apply flow:** pick a template → fill variables → **preview** everything it will create, with dates resolved → Create. All rows are created in one transaction and can be undone in one step.

### 6.2 Assignment series (class templates)
An **assignment rule** generates concrete, numbered tasks. These are real tasks, not a recurrence series, because each HW is its own deliverable that you edit, schedule and complete separately.

| Rule field | Example |
|---|---|
| `category` | Homework |
| `title_pattern` | `HW {n}` |
| `start_number`, `count` | 1, 12 |
| `first_due` | 2026-08-29 23:59 |
| `repeat` | every 1 week · on Fri (or every 2 weeks, or explicit date list) |
| `skip_dates` | inherited from class term skip weeks (e.g. Thanksgiving week) |
| `estimated_minutes?`, `source_url_pattern?` | `https://cs61b.org/hw/hw{n}` |

**Behavior**
- Generated tasks carry `generated_by_rule_id`. Each one can be edited, renamed, moved or deleted on its own. A per-field "detached" flag is set when you edit a generated field, so later series edits don't overwrite your change.
- **Edit series** works on *not-yet-completed, not-detached* tasks only: shift all due dates by N days, change the time, change the count (adds or removes from the end), and preview before applying.
- Exams and quizzes are usually irregular, so the apply sheet also offers a **quick date list**: "Quiz on 9/18, 10/9, 11/6" creates Quiz 1–3.

### 6.3 Categories
User-editable. Each has a name, SF Symbol, optional default color, default due time, default estimate and optional default subtasks. A category can be global or enabled per container, so "Milestone" doesn't clutter class views.

### 6.4 Quick add parsing (lightweight, deterministic, no AI)
`HW 5 cs61b fri 11:59pm #hw !2` → title "HW 5", container CS61B (fuzzy match on name/code), due Fri 11:59 PM, category Homework, priority 2. Parsed tokens are highlighted live and each can be removed. Unparsed text stays in the title.

---

## 7. Calendar and Google Calendar

### 7.1 Approach: EventKit first
Google Calendar is MVP-critical, and both clients are Apple-native, so V1 reads and writes Google events **through EventKit**, using the Google account you already added to macOS/iOS Calendar (System Settings → Internet Accounts).

| | EventKit (V1) | Server Google API sync (later, optional) |
|---|---|---|
| Setup | One permission prompt | OAuth, token encryption, Edge Function, webhook channels |
| Works offline | Yes (system cache) | Needs own cache |
| Read and write Google | Yes (via CalDAV, done by the OS) | Yes |
| Events in Supabase | No (device-local) | Yes |
| Risk | Depends on the device's Calendar account setup; small sync lag | Lots of sync edge cases (v0.2 §8) |

Server-side sync is only worth building if you later want a web client or server-side automations that need events. Mappings and annotations (§7.3) live in Supabase either way, so switching later is additive.

### 7.2 Event identity
Store `calendarItemExternalIdentifier` plus the calendar's source and title as the cross-device key. (`eventIdentifier` is device-local.) Recurring external events are keyed by external ID plus occurrence start date. If an identifier can't be resolved on a device, the event still shows; only its local annotations are hidden. Never block on this.

### 7.3 Event → container mapping
Your class events are named like `COMPSCI 61A LEC` and `ELENG 66 DIS`. **Mapping rules** assign external events to containers so they appear in that class's scope:
- **By calendar:** every event in the "Work" calendar → Engineering.
- **By title pattern:** a title starting with `COMPSCI 61A` → CS61A. The class template asks for this pattern, suggested from the course code.
- **Manual:** right-click an event → "Assign to…" (stored in `event_links`).

Unmapped events show only in the global calendar, not inside class dashboards (v0.2 rule kept).

### 7.4 Publishing work blocks to Google (opt-in, Phase 2b)
"Also add to calendar…" on a schedule block creates an EventKit event in a chosen calendar. The link is stored in `task_schedule_blocks.external_event_key`. From then on, moving either side updates the other. The task's due date is never published unless you choose to.

---

## 8. Recurrence

- A recurring task has an `rrule` (supported subset: DAILY, WEEKLY with BYDAY, MONTHLY by day or BYSETPOS, INTERVAL, COUNT, UNTIL), plus `rrule_tz` and an anchor.
- **Occurrences are computed, not stored.** Key: `occurrence_key = local date (and time) in rrule_tz`.
- **`task_occurrence_overrides`** stores only exceptions: `(task_id, occurrence_key)` unique, with status, completed_at, a moved due date or time, skipped, or a title override.
- Completing one occurrence writes one override row. It never touches the series.
- Edit scopes are explicit: *this occurrence* (override), *this and future* (split the series: end the old rule with UNTIL and create a new series), or *all*.
- Missed occurrences stay visible as overdue until completed or skipped. They never disappear silently.
- Class *meetings* are calendar events (Google), not recurring tasks.
- The evaluator is a small, well-tested Swift module. Tests cover DST transitions, month-end (31st → 30-day months), leap days, time zone changes and COUNT/UNTIL boundaries.

---

## 9. Architecture

```
┌──────────────── Xcode workspace ─────────────────┐
│  App-macOS     App-iOS     WidgetExtension        │
│      └───────────┬──────────────┘                 │
│        WorkspaceUI (SwiftUI package)              │
│        WeekGrid · WeekStrip · Board · TaskRow …   │
│                  │                                │
│        WorkspaceKit (Swift package, no UI)        │
│  Models · Store(GRDB/SQLite) · Sync · ScopeQuery  │
│  Recurrence · Templates · QuickAddParser · EK     │
└──────────────┬───────────────────────────┬────────┘
               │ supabase-swift            │ EventKit
        ┌──────▼──────┐             ┌──────▼──────┐
        │  Supabase   │             │ OS Calendar │──CalDAV── Google
        │ Postgres+RLS│             └─────────────┘
        │ Auth (Apple)│
        │ Realtime    │
        └─────────────┘
```

| Layer | Choice | Notes |
|---|---|---|
| Platforms | macOS 15+, iOS 18+ | Multiplatform SwiftUI. Use `#if os()` only where layouts differ. macOS 15 because the development Mac runs 15.7; raise it later if a newer API is worth it. |
| Code layout | One Swift package with three libraries: `WorkspaceKit` (models, store, scope, sync; GRDB only), `WorkspaceRemote` (Supabase), `WorkspaceUI` (tokens, shared views). The Xcode project is generated from `project.yml` by XcodeGen. | Widgets will depend on `WorkspaceKit` only. |
| Local store | **GRDB (SQLite)** in an App Group container | The widget reads the same DB. GRDB gives explicit control over schema, migrations and observation (`ValueObservation` drives SwiftUI). Chosen over SwiftData for more predictable sync and widget sharing. |
| Backend | Supabase Postgres + RLS, Auth with Sign in with Apple, Realtime | All tables are owner-scoped. Edge Functions aren't needed for V1. |
| Sync | Local-first: write locally → outbox → push. Pull by `updated_at` cursor. Realtime pokes trigger a pull. | Single user, few devices: **last-write-wins per row** using server `updated_at`, with `deleted_at` tombstones. Re-evaluate PowerSync if conflicts become painful. |
| Scope queries | `ScopeQuery` in WorkspaceKit, run on local SQLite | Uses a materialized `path` column (`/root/school/cs61b/`), so a descendant query is `path LIKE ?%`. The one implementation serves Mac, iPhone and widgets. |
| Widgets | WidgetKit + App Intents + shared GRDB | The intent writes to the local DB and outbox, then reloads timelines. The main app or a background task flushes the outbox. |

**Rule:** business logic (scope, recurrence, templates, status↔column, Today rules) lives only in WorkspaceKit and gets unit tests. Views just render.

---

## 10. Database schema (Supabase / Postgres)

All tables have `id uuid pk`, `owner_id uuid` (RLS: `owner_id = auth.uid()`), `created_at`, `updated_at` (trigger-maintained), and `deleted_at`.

| Table | Key columns / constraints |
|---|---|
| `containers` | `parent_id?`, `kind` (folder/list/class/project), `name`, `color`, `icon`, `path` (text, maintained by trigger; cycle check), `default_list_id?` (folders only), `sort_rank`, `archived_at?`, `settings jsonb` · trigger rejects a folder under a task-holding kind |
| *tasks constraint* | trigger rejects `tasks.container_id` pointing at a `folder` |
| `class_terms` | `container_id` (unique), `term_start`, `term_end`, `skip_ranges jsonb`, `course_code`, `event_title_pattern?` |
| `project_meta` | `container_id` (unique), `status`, `target_date?`, `description` |
| `board_columns` | `container_id`, `name`, `maps_to_status`, `sort_rank`, `wip_limit?` · at least one `done` column per board |
| `categories` | `name`, `symbol`, `color?`, `default_due_time?`, `default_estimate?`, `default_subtasks jsonb`, `is_global` |
| `container_categories` | `container_id`, `category_id` (enabled-per-container) |
| `tasks` | as §5 · indexes: `(owner_id, container_id)`, `(owner_id, due_date)`, `(owner_id, status)`, `generated_by_rule_id` |
| `task_schedule_blocks` | `task_id`, `starts_at`, `ends_at`, `occurrence_key?`, `external_event_key?` · index `(owner_id, starts_at)` |
| `task_occurrence_overrides` | `task_id`, `occurrence_key`, `status`, `completed_at?`, `due_date?`, `due_time?`, `skipped`, `title?` · UNIQUE(`task_id`,`occurrence_key`) |
| `assignment_rules` | `container_id`, `category_id`, `title_pattern`, `start_number`, `count`, `first_due_date`, `due_time`, `repeat jsonb`, `explicit_dates date[]?`, `source_url_pattern?`, `estimate?` |
| `templates` | `kind`, `name`, `spec jsonb` (§6.1), `is_builtin` |
| `event_mapping_rules` | `match_type` (calendar/title_prefix/title_regex), `match_value`, `container_id`, `priority` |
| `event_links` | `external_event_key`, `occurrence_start?`, `container_id?`, `task_id?`, `notes?` |
| `user_settings` | `today_policy jsonb`, `week_start`, `default_calendar_key?`, `visible_calendars jsonb` |

---

## 11. Milestones

Each milestone ends with: migrations reviewed, unit tests passing, a short manual check list run on real hardware, and a note on what changed and what was deferred.

| # | Milestone | Done when |
|---|---|---|
| 0 | **Foundation** | Xcode workspace and both packages exist. Supabase project has migrations and RLS tests. Sign in with Apple works. GRDB schema and sync engine (outbox, pull cursor, tombstones) work. Design tokens are in place. Seed data matches the §12 examples. |
| 1 | **Core Mac** | Sidebar tree (CRUD, drag re-parent), scoped dashboard (all six regions), week strip, task inspector, categories, ⌘N quick add with parser, ⌘K palette. |
| 2 | **Calendar + Google** | Full Calendar day/week/month time grid. Schedule block create/move/resize. EventKit read/write. Event mapping rules. Calendar source toggles. *(2b: publishing blocks to Google.)* |
| 3 | **Classes, Clubs + Boards** | *3a Classes:* assignment series ("HW 1–12, due Fridays 11:59 PM") with Edit series; class template (term, categories, meetings, series in one sheet). *3b Event links:* rules for any container — "titles starting with X" or "everything on calendar Y" — managed from the container editor; Belongs to can apply to all occurrences of a recurring event. *3c Boards:* project Kanban with custom columns, status mapping, drag between columns, optional swimlanes; Milestone category as diamond markers in the week strip and calendar. *3d Templates:* project template (columns + starter milestones), save any container as a template, task templates. |
| 4 | **Recurring tasks** | Rule editor (daily/weekly/monthly/custom) with next-occurrences preview. Overrides per occurrence. This/future/all edits. Recurring tasks on the dashboard and calendar. Edge-case test suite (DST, month ends, completed-early). |
| 5 | **iPhone + Widgets** | Today, Calendar (3-day), Browse, board paging, quick-add sheet, Google sign-in on iOS, interactive Today widget, Lock Screen widget, App Intents and Shortcuts. |
| 6 | **Polish** | Publish task blocks to Google (optional, per calendar). Better overlap layout in narrow columns. Notion import (one-time), JSON export/backup, notifications for due tasks and blocks, accessibility pass, empty and error states. |

The iPhone app comes after the Mac UI settles, but WorkspaceKit already builds for iOS from Milestone 0, so Phase 5 is mostly UI work.

---

## 12. Acceptance tests (examples to seed and verify)

1. **Scope:** School > CS61A, CS61B, EE66. The Root, School and CS61B dashboards show progressively narrower sets of the same task rows.
1b. **Folders vs lists:** quick-adding "Buy groceries" on the Personal folder dashboard puts it in Personal › General (creating General if needed). It shows on the Personal and Root dashboards but not under School. A task can't be saved directly into a folder.
2. **Due vs scheduled:** CS61B has HW 9 (due Fri, date only), Quiz 4 (Thu 2 PM) and "Study for Quiz 4" (block Tue 7–8 PM). The week strip shows all three on their days. The time grid shows only the Tue 7–8 block, plus Quiz 4 if it is given an exam time. Today on Tuesday lists the study task once.
3. **Multiple blocks:** an EE66 lab has two work blocks and a Fri deadline. The calendar shows two timed blocks and one all-day flag. The checklist shows one task.
4. **Class template:** applying "Class" with code CS61B, term 8/26–12/12, "HW {n}" ×12 weekly on Fri 11:59 PM, and Thanksgiving week skipped creates exactly 12 HW tasks on the right dates. "Shift remaining by +1 day" after completing HW 1–3 moves only HW 4–12.
5. **Detach:** HW 6 has a manually changed due date. A later series shift leaves HW 6 alone.
6. **Board:** in Clubs › Robotics › Competition Bot, dragging a card to "Done" completes it and it shows completed in the Root Today list. Unchecking it in Today moves it back to the first non-done column.
7. **Google:** a `COMPSCI 61A LEC` event from Google shows in the global Calendar and in CS61A's scope (by title rule), but not in CS61B. Moving a writable Google event in the app moves it in Google Calendar after a confirmation.
8. **Recurrence:** completing Monday's weekly reading doesn't complete next Monday's. "This and future" on a time change splits the series. Earlier occurrences keep the old time.
9. **Sync:** completing a task on Mac shows on iPhone within seconds while both are online. An offline iPhone edit reconciles on reconnect with no lost rows.
10. **Widget:** the Today widget shows cached data in airplane mode, checking off a task works, and the app reflects it on next launch.

---

## 13. Risks and mitigations

| Risk | Mitigation |
|---|---|
| EventKit identifiers differ across devices or change after the account is re-added | Key on external identifier plus a fallback (calendar title, start, event title). Annotations degrade gracefully. Server sync is the escape hatch. |
| LWW sync drops a concurrent edit | Single user makes this rare. Keep server-side history of row versions for 30 days (audit trigger) so a lost edit can be recovered. |
| Template/series edits clobber manual changes | Per-field detach flags, and preview before every bulk change. |
| Recurrence edge cases | Small supported RRULE subset with property-style tests across DST and month-end. |
| Scope creep toward Notion | Notes are Markdown text on tasks and containers only. No block editor. |

---

## 14. Open decisions (defaults chosen, change any time)

1. **Today policy default:** scheduled today + due today + overdue (collapsed). *Default: yes.*
2. **Week start:** Sunday (matches your screenshots). *Configurable.*
3. **Dashboard week strip:** should it show timed Google events as chips? *Default: off; all-day events on.*
4. **Board scope:** do nested sub-project tasks show on the parent board? *Default: yes, as swimlanes, with a "This project only" toggle.*
5. **Completed tasks on the board:** hide from Done after 7 days? *Default: yes, with "Show all" toggle.*
6. **Server Google sync:** build only if a non-Apple client is added later.

---

## 15. Notes for AI coding agents

- Build in milestone order, one milestone per PR series. Don't generate everything at once.
- For each milestone: state assumptions → define schema and interfaces → implement → run `swift test` and RLS tests → report changed files, tradeoffs and manual checks.
- Never duplicate logic from WorkspaceKit in views. Never conflate `due_*` with schedule blocks. Never create a new task when moving a block or occurrence.
- Visual rules in §3 are requirements, not suggestions. Match the token names exactly.

### References
- EventKit: https://developer.apple.com/documentation/eventkit
- Interactive widgets: https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- App Intents: https://developer.apple.com/documentation/appintents
- supabase-swift: https://github.com/supabase/supabase-swift
- GRDB: https://github.com/groue/GRDB.swift
- Google Calendar sync (for the optional server path): https://developers.google.com/workspace/calendar/api/guides/sync
