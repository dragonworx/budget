# Budget Tool

A Flutter application for visually planning and tracking pool balances over time through discrete credit/debit transactions.

**Platforms (v1):** Web only (`flutter run -d chrome` / web build). iOS, Android, and desktop are out of scope.

**Dev experience:** Hot reload / hot restart must work for the web target during development.

**Persistence (v1):** Browser-local only (e.g. IndexedDB / local storage via the chosen Flutter persistence layer). No accounts, sync, or cloud backend.

---

## 1. Goals

1. Let a user model one or more **pools** (top level, owned by the user and shareable per pool), each with **transactions**.
2. Show a pool’s projected **balance over time** on an infinite, zoomable timeline.
3. Let the user create transactions by picking dates/ranges on the timeline and **solving** for unknown transaction variables (goal planning).

Non-goals for v1: bank sync, receipts, budgets-by-category, multi-currency conversion, interest accrual formulas.

---

## 2. Domain Model

### 2.1 Hierarchy

```
User
 └── Pool (seed balance + seed date; shareable: owner / editor / viewer)
      └── Transaction (one-time or repeating credit/debit)
           └── Occurrence (computed instance on a calendar day)
```

| Entity | Purpose |
|--------|---------|
| **Pool** | Named ledger with a seed balance and seed date. Owns transactions. |
| **Transaction** | A planned credit or debit pattern applied to one pool. |
| **Occurrence** | A concrete application of a transaction on one calendar day (derived, not stored unless overridden). |

### 2.2 (Projects were removed: pools are top level.)

### 2.3 Pool

| Field | Type | Notes |
|-------|------|--------|
| `id` | UUID | |
| `ownerId` | UUID | Owning user |
| `name` | string | Required, unique per owner (case-insensitive) |
| `currency` | ISO 4217 | Fixed per pool in v1 (default device locale currency). No FX. |
| `seedBalance` | decimal | Balance **at the start of** `seedDate` (before that day’s occurrences) |
| `seedDate` | date | Anchor for the balance series; timeline may extend before this date (balance is undefined / not drawn before seed, or shown as flat seed—**decision: do not draw before seedDate**) |
| `transactionOrder` | list of transaction IDs | Explicit order used as same-day tiebreaker (see §3) |

**Seed semantics:** On `seedDate`, apply occurrences for that day in `transactionOrder`, starting from `seedBalance`. Days before `seedDate` are out of range for the chart.

### 2.4 Transaction

| Field | Type | Notes |
|-------|------|--------|
| `id` | UUID | |
| `poolId` | UUID | |
| `name` | string | Optional label (e.g. “Rent”, “Paycheck”) |
| `direction` | `credit` \| `debit` | Credit raises balance; debit lowers it |
| `amount` | decimal ≥ 0 | Magnitude per occurrence (direction separate from sign) |
| `startDate` | date | First possible occurrence date |
| `recurrence` | see below | |
| `endRule` | see below | When repeating stops |
| `enabled` | bool | Disabled transactions contribute no occurrences |

#### Recurrence

Exactly one of:

| Mode | Meaning |
|------|---------|
| `once` | Single occurrence on `startDate` |
| `every` | Occurs on `startDate`, then every `interval` `unit`s |

| Field | Type | Notes |
|-------|------|--------|
| `interval` | int ≥ 1 | e.g. 1, 2, 3 |
| `unit` | `days` \| `weeks` \| `months` \| `years` | Calendar-aware for months/years (see §3.2) |

`daily` is sugar for `every 1 day` (UI may offer it as a shortcut; model stores `every`).

#### End rule (repeating transactions only)

Exactly one of:

| Mode | Meaning |
|------|---------|
| `never` | Continues indefinitely (UI/chart must clamp render window; see §5) |
| `untilDate` | Last occurrence on or before `endDate` (inclusive) |
| `count` | Exactly `occurrenceCount` occurrences (including the first) |

`once` transactions ignore `endRule`.

#### Solver / planning mode

Transactions may be created in **fully specified** form or via the **solver** (§4), which fills missing fields from a goal. After solving, the transaction is stored as a normal fully specified transaction (solver inputs are not re-solved unless the user re-opens Solve).

### 2.5 Occurrence (derived)

| Field | Type | Notes |
|-------|------|--------|
| `transactionId` | UUID | |
| `date` | date | Calendar day |
| `signedDelta` | decimal | `+amount` for credit, `-amount` for debit |
| `skipped` | bool | Optional per-instance override (v1: support skip only) |

Skipping an occurrence does not shift later dates; later occurrences keep their schedule.

---

## 3. Balance Engine

### 3.1 Daily series

Balance is computed as a **daily** series:

- For each date `D >= seedDate`,  
  `balance(D) = balance(D-1) + sum(signedDelta of occurrences on D)`  
  with `balance(seedDate - 1)` conceptually equal to `seedBalance` before applying `seedDate` occurrences…  
  **Clarify:** `openingBalance(seedDate) = seedBalance`.  
  `closingBalance(D) = openingBalance(D) + sum(deltas on D)`.  
  `openingBalance(D+1) = closingBalance(D)`.  
  The chart plots **closing balance** per day.

### 3.2 Same-day order

If multiple occurrences fall on the same date, apply them in **`transactionOrder`** (pool-level list). Transactions not in the list append in creation order. Reordering in the UI updates `transactionOrder`.

### 3.3 Calendar arithmetic

- **Days / weeks:** Fixed 1 day / 7 days from `startDate`.
- **Months:** Same day-of-month when possible; if the target month is shorter, use the last day of that month (e.g. Jan 31 + 1 month → Feb 28/29).
- **Years:** Same rule on anniversary; Feb 29 start → Feb 28 in non-leap years.

### 3.4 Indefinite transactions

Computation and rendering use a **visible window** plus a buffer (e.g. ±2× viewport). Do not materialize infinite occurrences. Solver “until never” is allowed but goals that need a finite horizon require `untilDate` or `count`.

### 3.5 Precision

Use decimal money (not binary float) with currency minor units (e.g. 2 places for USD). Display with the pool’s currency formatter.

---

## 4. Transaction Solver (Goal Planning)

The user fills in whichever variables they know; the solver derives **all** the others it can. Two relations tie the variables together:

- **Total:** `T = A × N`
- **Schedule:** `S`, `F`, `N`, `E` — any three determine the fourth

So any four independent knowns determine the transaction (e.g. `S` + `T` + weekly `F` + `A` → `N` and `E`).

### 4.1 Variables

| Variable | Symbol | Notes |
|----------|--------|--------|
| Start date | `S` | |
| End date | `E` | Implies `endRule = untilDate` |
| Occurrence count | `N` | Implies `endRule = count` |
| Interval + unit | `F` | Frequency |
| Amount per occurrence | `A` | |
| Direction | `Dir` | Usually user-chosen, not solved |
| Target total transferred | `T` | `T = A × N` (signed by direction for balance impact) |
| Target closing balance on date | `B*` | On date `E` or on date of Nth occurrence |

### 4.2 Supported solve modes (v1)

Every field is optional; blank means "calculate". The planner re-solves as the user types and marks calculated fields. The frequency unit is always user-chosen; its interval (every N units) may be solved.

| Known | Calculated |
|-------|-----------|
| `S`, `F`, `A`, `T` | `N`, `E` |
| `S`, `F`, `N` or `E`, `T` | `A`, and `E` or `N` |
| `S`, `F`, `A`, `N` or `E` | `T`, and `E` or `N` |
| `S`, `E`, `N` (or `A` + `T`) | `F` interval (exact match in the chosen unit, else error with closest options) |
| `E`, `F`, `N` (or `A` + `T`) | `S` |

- **Too few knowns:** the solver reports how many more are needed and which fields would help (e.g. `S` + `T` + `F` → "fill in one more: end date, increment amount or count").
- **Too many knowns:** accepted if consistent, otherwise rejected with a message naming the fields to clear.
- `N = 1` produces a `once` transaction. The stored end rule is `untilDate` when `E` was user-supplied, otherwise `count`.

**Balance goal (`B*`):** Solve using  
`needed = B* − projectedClosingBalance(E) without this transaction`  
then treat `needed` as signed `T` (credit if positive, debit if negative)—or require the user to pick direction explicitly if `needed` sign conflicts with `Dir`.

### 4.3 Constraints / errors

- Reject `A = 0`, `N < 1`, `E < S`, interval < 1.
- If no integer `N`/`F` satisfies the goal exactly, round with an explicit UI choice: **nearest**, **at least goal**, or **at most goal**.
- Show a preview of resulting occurrences and end balance before commit.

---

## 5. Major UI

### 5.1 Pools home

**Purpose:** List my pools and those shared with me; enter Timeline for a pool. After sign-in the app opens the last-used pool directly; the home is shown when there is none (or via “Manage pools”).

**Capabilities:**

- List pools: “My pools”, then “Shared with me” (owner + my role).
- Create / edit / delete pools.
- Reorder pools (display order only).
- Open **Timeline View** for a pool (primary CTA).

**Empty state:** No pools → “New pool”.

### 5.2 Timeline View

**Purpose:** Infinite horizontal chart of closing balance vs time; create and manage transactions in context.

#### Chart

| Aspect | Spec |
|--------|------|
| Type | Step / bar / line of **daily closing balance** (pick one visual; recommendation: step line + optional column markers on occurrence days) |
| X axis | Time, base unit = 1 day |
| Y axis | Money; may be negative |
| Pan | Horizontal infinite scroll within computed window |
| Zoom | Scroll-wheel / trackpad pinch + buttons; discrete levels: day → week → month → quarter → year (aggregate display of Y still reflects daily series; ticks/labels coarsen) |
| Window | Default: seedDate − 7d … today + 90d (or seedDate if in future). Lazy-extend on pan |
| Before seed | No series (axis may show empty) |
| Today | Vertical marker |

#### Transaction interaction

- **Tap occurrence marker** → inspect transaction / edit / skip this occurrence / delete transaction.
- **Tap empty day** → create **once** transaction on that date (amount + direction + name).
- **Drag-select date range** → open **Solve / plan** sheet with `S`/`E` prefilled; user picks what to solve (§4).
- **Transaction list panel** (side sheet or bottom sheet): all transactions for the pool, enable/disable, reorder (`transactionOrder`), edit fields manually without solver.

#### Chrome

- Pool name + current (today’s) closing balance in app bar.
- Back to the Pools home.
- Zoom controls; “Jump to today”; “Jump to seed”.

### 5.3 Transaction editor (shared)

Fields matching §2.4. Validation inline. Recurrence and end-rule controls mutually exclusive as specified. Preview next few occurrence dates.

---

## 6. Feature Scope

### v1 (must)

- [ ] Pools CRUD  
- [ ] Pools CRUD (name, currency, seed balance, seed date)  
- [ ] Transactions CRUD (once / every N units; end never / until date / count)  
- [ ] Skip single occurrence  
- [ ] Daily balance engine with same-day `transactionOrder`  
- [ ] Timeline: pan, zoom levels, today marker, occurrence markers  
- [ ] Create one-time transaction from day tap  
- [ ] Range-select → solver (fill any known variables, calculate the rest) as in §4.2  
- [ ] Browser-local persistence + survive refresh / restart  
- [ ] Web run target with hot reload in daily development  
- [ ] Basic confirmation on destructive delete  

### v1.1 (should)

- [ ] Target closing balance `B*` solver mode  
- [ ] Duplicate transaction / duplicate pool  
- [ ] Export/import transactions JSON  
- [ ] Soft color coding per transaction on the chart  

### Out of scope (for now)

- Bank / Plaid sync  
- Transfers between pools (model as paired transactions manually in v1)  
- Interest, fees, amortization schedules as first-class types  
- Multi-currency conversion  
- Auth / sync / multi-device  
- Categories, envelopes, reporting dashboards  

---

## 7. Technical Notes (guidance, not binding)

- **Flutter** web app; state via approach TBD (e.g. Riverpod + web-capable local store such as Drift/IndexedDB, Hive, or `shared_preferences` where sufficient).
- Keep balance engine **pure** and unit-tested (date math, order, solver rounding).
- Chart library TBD (e.g. `fl_chart`, custom `CustomPainter` for performance on long series).
- Material 3 for web; timeline is the distinctive surface.
- Develop and verify against **Chrome (web)** only; hot reload / hot restart are required for the inner loop.

---

## 8. Open Decisions

Resolved in this draft (change if wrong):

1. Chart plots **closing** balance per day.  
2. No drawing before `seedDate`.  
3. Direction and amount are separate fields (not signed amount).  
4. Same-day tiebreak = explicit `transactionOrder`.  
5. Local-only persistence for v1.  

Still open:

1. Exact chart visual (step line vs bars).  
2. Default currency source (device locale vs user setting at first launch).  
3. Whether deleting a pool is recoverable (trash vs hard delete).  
4. Max practical pan range for `endRule = never` (e.g. seed → seed+100 years clamp).  

---

## 9. Glossary

| Term | Definition |
|------|------------|
| Seed | Starting balance and date that anchor the series |
| Transaction | Recurring or one-time credit/debit pattern |
| Occurrence | One application of a transaction on a day |
| Closing balance | Balance after all of that day’s occurrences |
| Solver | UI/engine that computes a missing transaction variable from a goal |
