# Personal Workspace

A personal productivity app for Mac and iPhone: folders, lists, classes and projects, a scoped dashboard, a calendar with Google events, class templates and Kanban boards. The full design is in [docs/DESIGN.md](docs/DESIGN.md).

**Status:** Milestone 0 (foundation) is done. Milestone 1 (core Mac UI) is next.

## Layout

```
Apps/Shared/            SwiftUI app code shared by Mac and iPhone
Apps/macOS, Apps/iOS/   Per-platform Info.plist and entitlements (generated)
Packages/WorkspaceKit/  Swift package
  WorkspaceKit          Models, local SQLite store (GRDB), scope queries, sync engine
  WorkspaceRemote       Supabase auth and the PostgREST sync transport
  WorkspaceUI           Design tokens and shared views
supabase/migrations/    Postgres schema, triggers and RLS
supabase/tests/         SQL tests (run against a throwaway local Postgres)
scripts/test-db.sh      Runs the SQL tests
project.yml             XcodeGen spec (the .xcodeproj is generated, not committed)
```

## Getting started

Requirements: Xcode 26, `brew install xcodegen postgresql@18`.

```bash
xcodegen generate
```

```bash
open PersonalWorkspace.xcodeproj
```

Run the `Workspace-macOS` scheme. Without Supabase keys, the app runs in **local-only** mode, with everything stored in SQLite on your Mac. Use **Debug › Load Sample Data**, or launch with `--sample-data`, to get the example workspace.

## Tests

Swift unit tests cover the store, rules, scope, sync and value types:

```bash
cd Packages/WorkspaceKit && swift test
```

Database tests cover the schema, triggers and RLS. They run against a temporary local Postgres and don't touch anything else:

```bash
scripts/test-db.sh
```

## Connecting Supabase (enables sync and Sign in with Apple)

1. Create a project at supabase.com.
2. Apply the schema:
   ```bash
   brew install supabase/tap/supabase
   ```
   ```bash
   supabase init && supabase link --project-ref <your-project-ref> && supabase db push
   ```
3. In the Supabase dashboard, go to **Authentication → Providers → Apple**, enable it, and add `com.rescalante.workspace` under *Client IDs*.
4. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and fill in the host, the anon key and your `DEVELOPMENT_TEAM`.
5. Run `xcodegen generate`. The Sign in with Apple entitlement is already in `project.yml` (it needs a paid Apple Developer account). The first signed build on a new Mac has to register the device:
   ```bash
   xcodebuild -scheme Workspace-macOS -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```
   Or just press Run in Xcode.

## How sync works (short version)

- Every write goes to local SQLite first and gets queued in `sync_outbox`. The UI never waits on the network.
- Sync pushes queued rows (upsert by id), then pulls rows whose server `updated_at` is newer than the last cursor.
- Conflicts resolve as last write wins per row. The server keeps 30 days of prior row versions in `row_history`.
- Deletes are tombstones (`deleted_at`), so they reach every device.
- RLS restricts every table to `owner_id = auth.uid()`. Triggers enforce tree rules (no tasks in folders, no cycles, materialized paths) and block references to other users' rows.
