# 018 — Per-stream categories

Requested by Ali (voice, 28 Nov 2026): refactor categories from **global per owner** to **per stream**. Move category management into each stream. Copy every existing global category into every stream the owner has, preserving name, colour, sort order and parent/child hierarchy (remap parent ids in each copy). Ali will clean up duplicates by hand afterwards. **No global-vs-per-stream toggle.** Keep it simple: per-stream only.

This is a large, migrating change. Work in phases, commit each phase, and **do not push the migration until a production backup can be taken from this box (or Ali explicitly accepts the VPS compose snapshot as sufficient).** Runs get cut off around 50 minutes; resume from this file.

**UI copy:** use “transactions”, not “events”. Menus stay on `AppMenuAnchor`. Reset Stream keeps categories. Never touch `.github` or Vercel. Commit as `dragonworx`. Don’t commit `client/test/failures/` or `client/test/rollout/failures/`.

## Status (resume here)

- [x] Investigation (this file).
- [x] Plan written and pushed (`04a9dbd` on main, `docs/018-per-stream-categories.md`). **No migration has been pushed.**
- [x] Phase A done locally, **not pushed:**
  - Dev backup: `/workspace/backups/dev-before-035-20261128-153711.dump` (270268 bytes, 15:37 AEDT 28 Nov 2026).
  - `server/migrations/035_per_stream_categories.sql` + `server/test/migration_035_test.dart` (test passed).
  - Dry run on `budget_035_dry` (restored from that dump, then dropped): **420** categories (38×10 + 9×2 + 6×2 + 2×1 + 2×4), **69** events, **0** missing, **0** crossed, **8/8** transfer pairs remapped to each leg's stream copy of the same path, uniques stream-scoped, `owner_id` dropped. Idempotent re-run left 420. Cross-stream `category_id` rejected; name-only create stayed in one stream; deleting a stream removed its tree.
  - **Live dev `budget` was left on the pre-035 schema** (57 categories, `owner_id` still present) so the current owner-scoped API keeps working. Apply 035 to `budget` only when Phase B is ready to run with it.
- [ ] **Prod backup gate:** cannot be done from this box today (see [Prod backup](#prod-backup-gate)). Stop before pushing `035_per_stream_categories.sql` or any commit that depends on it.
- [x] Phase B done locally, **not pushed:** server Category/repo/API use `streamId`; editors may write; Move to… and transfer peers remap by full path; event category must belong to the event's stream. `categories_test`, `event_move_test`, `route_sweep_test`, `migration_035_test` passed. Live dev `budget` is on 035 (420 categories, 69 events).
- [x] Phase C done locally, **not pushed:** removed user-menu Categories; added Categories to the Home stream ⋮ (`stream-categories`) and timeline More (`more-categories`); editors can manage this stream's categories; copy uses “transactions” and “this stream”. Viewers get a ⋮ menu with Categories only. `categories_ui_test` has 2 remaining failures (Esc closes category picker; editor-save after Esc in the sort test) — investigate in Phase D. `reset_stream_test`, `auth_test`, `entry_points_test` passed.
- [ ] Phase D — Tests (`analyze` + suites), Playwright QA, designer shot.
- [ ] Phase E — After the gate: push, confirm deploy and `/ready`, read-only prod count check, `wake.sh`.

HEAD when this plan was written: `163394c` (Reset Stream). Plan commit: `04a9dbd`. Next migration number: **035**.

## Current model (verified 28 Nov 2026 against the dev DB and tree)

Categories started **per stream** in `024_categories.sql`, then became **global per owner** in `025_global_categories.sql`. Hierarchy (`parent_id`, max depth 2, `sort_order`, `category_favorites`) landed in `031`; folders cannot hold transactions (`032`).

### Table `categories`

| Column | Notes |
| --- | --- |
| `id` | UUID PK |
| `owner_id` | NOT NULL, FK `users(id)` ON DELETE CASCADE. **No `stream_id` today.** |
| `name` | trimmed, non-empty; unique per owner, case-insensitive (`categories_owner_name_uq`) |
| `color` | `#RRGGBB` (this is the visual identity) |
| `hidden` | hidden from the timeline and left out of the balance (eye menu) |
| `parent_id` | FK to `categories(id)` ON DELETE RESTRICT; null = top-level |
| `sort_order` | unique among siblings: `UNIQUE (owner_id, parent_key, sort_order)` |
| `parent_key` | generated `COALESCE(parent_id, '0000…0000')` |
| `version`, `created_at`, `updated_at` | usual |

**There is no `icon` column**, and no icon field on the Dart `Category` models. Colour is what Ali is seeing as the “icon.” Preserve colour; do not invent an icon column.

### References

- `events.category_id` — NOT NULL, FK ON DELETE CASCADE. `events.name` is kept equal to the category name by `events_category_sync` (BEFORE INSERT/UPDATE) and `categories_name_sync` (AFTER UPDATE OF name).
- `events_category_sync` today: the category must belong to the **stream’s owner**; a write that only sets `name` maps to / creates that owner’s category of that name.
- `events_category_must_be_leaf` — cannot file a transaction on a folder.
- `category_favorites (user_id, category_id)` — per-user, not per-stream. Dev has **0** rows. Still remap, then drop dangling rows with the old ids.
- No variable, budget, or other table has a `category_id`. Charts, filters, last-used category, and import all go through events + the category list API.

### Triggers and guards to update in 035

- `events_category_sync` — restore the 024 rule: category must belong to the **event’s stream**; name-only writes map/create in that stream.
- `categories_parent_guard` — parent must be in the **same stream** (today: same owner). Still: no self-parent, max depth 2, Sync cannot nest or have children.
- `categories_default_sort`, `categories_parent_must_be_empty`, `categories_name_sync`, `categories_bump_version`, `events_category_must_be_leaf` — keep, just scoped to the stream where they mention owner.

### Authz and API today

Routes are already under `/api/streams/:a/categories…` (stream URL, owner data):

| Method | Path | min role today | after |
| --- | --- | --- | --- |
| GET list / delete-preview / favorites | stream-scoped | any member | any member (that stream’s rows only) |
| POST create | editor | editor |
| POST reorder, PATCH, DELETE category, DELETE category events | **owner** | **editor** (scoped to this stream) |
| favorite PUT/DELETE | any member | any member, but the id must be in this stream |

Delete-preview / delete-events today count and delete the category’s transactions in **all of the owner’s streams** (plus transfer counterparts). After: **this stream only**, plus transfer counterparts in other streams (same as deleting those transactions one by one — already the single-event and Reset Stream rule).

`rehomeEventCategory` in `server/lib/api/events.dart` remaps Move to… **only when the two streams have different owners**, and only by **name**. After: remap whenever the **stream** changes, by **full path** (parent name + leaf name; create missing path in the target, same colour).

### Sharing today

A shared stream uses the **owner’s** global set. Ali’s wife (e.g. Wendy on Kids) sees Ali’s categories. Editors may add; only the owner may rename, recolour, hide, or delete (those changes reach every stream he owns).

After: each stream has its own copy. A viewer of a shared stream **reads that stream’s categories**. An editor may edit **that stream only**. Editing Wages’ “Groceries” does not change Everyday’s “Groceries”.

### Entry points today

- User menu → **Categories** (global entry; on home it uses last-opened or first stream; on a timeline it passes that stream id, but the data is still the owner set). **Remove this item.**
- Timeline View (eye) menu → Manage / View categories… Keep, but it shows **this stream** and `canEditCategories` becomes `stream.role.canEdit` (not owner-only).
- Add **Categories** to the Home stream-card ⋮ and the timeline More menu (near Stream settings), opening `showCategoriesManager` for that stream.

### Dev counts (budget @ 127.0.0.1, 28 Nov 2026)

| | |
| --- | --- |
| categories | 57 (25 roots, 32 children) |
| events | 69 (none missing a category; none on another owner’s category) |
| streams | 19 |
| owners with categories | 5 |
| `category_favorites` | 0 |
| transfer pairs | 8, **all 8 share one category row** today |

Ali (`musicartscience@gmail.com`): **38 categories, 10 streams** → migration should create **380** category rows for him (38 × 10), and remap every event in those streams to that stream’s copy. Other owners similarly (`qa-kb` 9×2, `loan-qa` 6×2, `wendy.qa` 2×1, `loan-api` 2×4). Expected total after copy: `sum(cats × streams)` = 38×10 + 9×2 + 6×2 + 2×1 + 2×4 = **420**, then drop the 57 originals (they are replaced, not kept alongside). Event count stays 69; every `events.category_id` points at a row with `categories.stream_id = events.stream_id`.

## Design decisions

### Transfers

Each leg lives in its own stream, so after the copy **each leg gets that stream’s copy** of the (same-named / same-path) category. Today both legs share one row; the trigger will require the category to be in the event’s stream, so this remap is mandatory. Creating or syncing a transfer later should also place the peer on the peer stream’s same-path category (create the path if missing, same colour).

### New streams

There is **no default seed set** in the repo or DB (no seed table, no fixture list used at `POST /api/streams`). New streams should **start empty**. Categories appear when the user adds them in the manager, or when an import / name-only write / Move to… creates them. Report this in the ship note.

### Reset Stream

Already deletes transactions only. Categories on that stream stay. Do not change this.

### Hidden and favourites

`hidden` is copied per stream (hiding Groceries on Wages does not hide it on Everyday). Favourites: after remap, a favourite is a `(user, category_id)` where that category belongs to one stream; the picker in a stream only shows favourites whose category is in that stream. Copy each existing favourite onto every stream-copy of that category so nothing is lost (dev has zero).

### Idempotency

If `categories.stream_id` already exists and is NOT NULL for every row, and no owner-only leftovers remain, the migration is a no-op. Use a single transaction. Disable USER triggers while remapping, re-enable, then run verification `DO` blocks that `RAISE EXCEPTION` on failure.

## Migration 035 (outline)

File: `server/migrations/035_per_stream_categories.sql`. Test: `server/test/migration_035_test.dart` (scratch DB like 025: apply 001–034, seed owner + 2 streams + hierarchy + events + a transfer + a favourite, apply 035, assert counts, paths, event remap, trigger rejects a cross-stream `category_id`).

Steps (one transaction):

1. `ALTER TABLE categories ADD COLUMN IF NOT EXISTS stream_id UUID REFERENCES streams(id) ON DELETE CASCADE;`
2. Mapping table (temp, ON COMMIT DROP): for every stream S of owner O, for every category C of O, a new id. Insert **parents first** (preserve `name`, `color`, `hidden`, `sort_order`, `created_at`), then children with `parent_id` remapped to the copy **in the same stream**. Set `stream_id = S`, keep `owner_id` temporarily if the column still exists.
3. Remap `events.category_id` to the copy for `events.stream_id`. Remap `category_favorites.category_id` to every corresponding copy (or one row per (user, new id)).
4. Delete category rows with `stream_id IS NULL` (the pre-copy originals).
5. `ALTER COLUMN stream_id SET NOT NULL`. Drop `categories_owner_name_uq` and `categories_sibling_sort_uq`. Create `categories_stream_name_uq (stream_id, lower(name))` and `UNIQUE (stream_id, parent_key, sort_order)`. Drop `owner_id` (source of truth is `streams.owner_id`).
6. Replace `events_category_sync` and `categories_parent_guard` as above.
7. Verify:
   - `events` with no category, or `category.stream_id <> event.stream_id` = 0
   - for every owner, `count(categories) = count(owner categories before) × count(streams)` (use a pre-copy snapshot table for the before-count)
   - hierarchy: each stream has the same (parent name, child name, sort_order, color, hidden) tuples as the owner’s original set
   - transfer pairs: the two legs’ categories have the same path, different ids, each in its own stream

**Dev backup (before running 035 on `budget`):**

```bash
pg_dump -Fc -h 127.0.0.1 -U budget budget > /workspace/backups/dev-before-035-$(date +%Y%m%d-%H%M%S).dump
# confirm non-zero size
```

**Dry run:** restore that dump into a scratch DB (e.g. `budget_035_dry`), apply 035, print verification counts, drop the scratch DB. Only then apply to `budget` (local API will restart via inotify / migrate on boot). Apply to `budget_test` via the usual test/setup path.

## Prod backup gate

`deploy/vps/docker-compose.yml` already runs a one-shot `backup` service **before** `migrate` on every VPS deploy: `pg_dump -Fc` to `/opt/apps/budget/backups/<utc>-before.dump` plus a row-count file (no personal data in the counts). `counts-after` runs after migrate. This is **on the VPS**, triggered by GitHub Actions using `secrets.VPS_HOST` / `VPS_USER` / `VPS_SSH_KEY`.

**This box cannot take that backup itself.** There is no `VPS_*` or prod database URL in the agent environment, and no SSH key to the VPS. The GitHub workflow would take a snapshot only *after* a push, as part of deploy — we cannot pull that file back here first.

Per Ali’s brief: **stop before pushing the migration commit** and report, so the parent can ask Ali whether to:

1. Have someone with VPS access take a `pg_dump` (or confirm the compose `backup` service is enough and copy the file off the VPS), then allow the push; or
2. Grant this box a way to snapshot prod (SSH or a one-off dump) and resume Phase E from this spec.

Do **not** push `035_*.sql` or any follow-up that expects `categories.stream_id` until that is resolved. The plan file itself is safe to push.

## Phase B — Server (after 035 is applied on dev)

- `Category` domain + `CategoryRepo`: key by `streamId`, not `ownerId`. List/create/reorder/update/delete/favorites all constrained to the stream. Event counts are for that stream only. `deleteEvents` / `deleteCounts` only this stream (+ transfer counterparts).
- `ownerOfStream` stays as a helper; `byName` / `byPath` become stream-scoped. Add `ensurePath(streamId, names[], colors[])` for Move to… and transfer peers.
- `rehomeEventCategory`: always when `fromId != toId`; match full path; create missing nodes with the same colour.
- Transfer `syncPeer` / create peer: after writing the peer row, rehome its category onto the peer stream’s same path (the name trigger alone would create a **top-level** same-named category and drop the parent). Prefer an explicit path copy.
- Authz: PATCH / DELETE / reorder / delete-events min role **editor**. Route shapes stay `/api/streams/:a/categories…` (route_sweep unchanged except any new helper path).
- Audit / realtime: keep `category.*` actions with `streamId` of the stream that changed. Client already has `categoriesProvider(streamId)`; do not invalidate every stream unless a transfer counterpart was touched (`notifyPeers` pattern).
- New stream create: do **not** copy categories (start empty).
- Import: name mapping uses the stream’s set (trigger + repo). No global fallback.

## Phase C — Client

- `showCategoriesManager` / `CategoriesManager`: this stream only. Copy: drop “shared by all your streams”; event counts are this stream; editors (not only the owner) can rename, recolour, hide, delete. Viewers remain read-only.
- Remove **Categories** from the user menu (`user_menu.dart`).
- Add **Categories** to the Home stream-card ⋮ and the timeline More menu (and keep View → Manage categories…). `AppMenuAnchor` already used.
- Pickers, list filters, charts, last-category: already take a `streamId`; confirm they only list that stream’s categories after the API change. Combined-timeline charts must use each event’s own stream’s category (name/colour still live on the event / category id).
- Tests that look for `menu-categories` on the user menu need updating.

## Phase D — Tests and QA

- `migration_035_test.dart` as above.
- Server: extend `categories_test.dart` and authz sweep (editor can PATCH; viewer 403; event with another stream’s `category_id` → 400/23503). Move to… test: same-owner two streams, path created on the target, colour preserved, source stream’s category unchanged.
- Client: manager opens from the stream menu; edit in stream A does not appear in stream B (fake repos with distinct lists); picker uses the current stream.
- Known pre-existing failures (do not block): `streams_home_test` P8/P10 SeedMetaRow overflow; `stream_delete_test` descendant-of-card “Stream actions”; the known-failing “tap lane -> create Rent” test.
- Playwright, QA streams only (never Wages / Savings / Everyday / Mortgage / Kids / Car loan as the *edited* stream). Suggested: `QA Reset Stream` and `QA Reset Peer`, or a fresh `QA Cats A` / `QA Cats B`.
  - Desktop, phone 412, phone 320, WebKit iPhone 15 Pro.
  - Open a stream’s Categories, rename or recolour one, confirm the other stream is unchanged.
  - Create a transaction with a category; Move to… the other stream; confirm the target has the same path/colour and the source still has its category.
  - Shots: `/workspace/timeline-qa/per-stream-categories/`. Check them visually. Copy one phone shot to `/workspace/designer-share/per-stream-categories-phone.png`.

## Phase E — Ship (after the prod backup gate)

Push in small commits if not already split: (1) 035 + migration test, (2) server API, (3) client, (4) tests/QA notes if any. Confirm GitHub Actions deploy, `https://budget.fresneldigital.com/ready` 200, new `/build.json` id. Read-only prod check: if we still cannot query prod Postgres, count via the API as Ali (categories listed on two of his streams should each equal the pre-migration owner set size, and editing is out of scope for that check). Run `/workspace/budget/wake.sh`.

## Out of scope / leftovers

- No “copy categories from another stream” helper (Ali will prune duplicates by hand). Can be a later request.
- No icon column.
- No toggle back to a global set.
- Variables stay owner-global (spec 010); they do not reference categories.
- Do not change Reset Stream beyond relying on “delete transactions, keep the stream and its categories.”

## Resume commands

```bash
# Dev backup
pg_dump -Fc -h 127.0.0.1 -U budget budget > /workspace/backups/dev-before-035-$(date +%Y%m%d-%H%M%S).dump
ls -l /workspace/backups/dev-before-035-*.dump

# After writing 035, dry-run on a copy (example)
# createdb budget_035_dry && pg_restore -d budget_035_dry the.dump
# psql budget_035_dry -f server/migrations/035_per_stream_categories.sql
# then verification SELECTs; dropdb budget_035_dry

# Tests
cd /workspace/budget/server && dart test test/migration_035_test.dart test/categories_test.dart
cd /workspace/budget/client && flutter test test/categories_ui_test.dart  # plus new tests
```
