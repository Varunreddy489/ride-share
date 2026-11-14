# 19 — Implementation Plan (core-first)

> Written for: you, the solo developer, starting to code now. It replaces the ordering in
> doc 18 for the first stretch: **core ride and pool logic first, auth and polish last.**
> Doc 18 remains the long-term skill roadmap; this is the concrete build sequence.

## 0. Ground rules

**Your layout stays as is** (doc 03 §2.3): `src/{api,controller,services,repositories,models,schemas,utils}`
plus two new folders, `clients/` and `workers/`. One file per feature in each layer, same filename
(`rides.py` in all of them).

**Auth is a stub until Stage 7.** A FastAPI dependency `current_user()` reads two headers:
`X-User-Id: <uuid>` and `X-Role: RIDER|DRIVER|ADMIN`. Every route already depends on it, so
real JWT later is a one-file swap (`src/api/deps.py`), not a rewrite. Never deploy this stub
beyond localhost. Ownership checks (rider can only read their own ride) are still enforced from
day one, because they're part of correctness, not auth ceremony.

**Deferred on purpose** (do not touch until the stage says so): JWT/refresh tokens, passwords,
OTP, rate limiting, Kubernetes, CI beyond lint+test, Kafka, Prometheus/Grafana, WebSockets.

**Definition of done for every stage:** (1) the exit demo runs, (2) the tests listed pass,
(3) one short note in `docs/adr/` or `docs/notes/` for any decision you made that the docs
didn't already make.

**Order of work inside a stage:** schema → `services/` (pure logic, tested first) →
`repositories/` → `controller/` → `api/`. Pure logic first because it's where the bugs are and
it needs no database.

## Stage overview

| Stage | Goal | Effort | Exit demo |
|---|---|---|---|
| 1 | Skeleton, DB, tooling | 3–4 days | `/healthz` works in compose; migration applies |
| 2 | Money, geo, pricing quotes | 1 week | `POST /v1/fare-quotes` returns solo + pool price |
| 3 | Drivers and locations | 4–5 days | Driver goes online; nearest-driver query returns them |
| 4 | Solo ride lifecycle | 1.5 weeks | Full solo ride via a bot script, fare computed |
| 5 | **Pool: insertion + matching** | 2–3 weeks | Two riders matched into one trip, stop order correct |
| 6 | **Pool: fare allocation** | 1 week | Five algorithms compared on the doc 07 example, receipts |
| 7 | Auth (minimal real) | 3–4 days | JWT replaces the header stub |
| 8 | Hardening: outbox, Redis, tests, load | 2–3 weeks | Locust report, concurrency tests green |

Stages 1–6 are the product (about 7–8 weeks at 10–15 h/week). Everything after is production
engineering from docs 09–17, done against a working system.

---

## Stage 1: Skeleton, database, tooling (3–4 days)

**Why first:** every later stage assumes a running app, a migration flow, and a test setup.

**Tasks**
1. Fix the build base. In `pyproject.toml` and `Dockerfile`, check that `asyncpg`, `psycopg`, and `bcrypt` install on Python 3.15. If any fail, pin Python 3.13 in both (doc 12 §1). Do this first, because it blocks everything.
2. Add dependencies: `h3`, `orjson`, `structlog`; dev: `pytest`, `pytest-asyncio`, `pytest-cov`, `hypothesis`, `testcontainers[postgres]`, `ruff`, `mypy`, `import-linter`, `respx`. Remove `isort` and `flake8` in favour of ruff.
3. Create `src/app.py` (the file `scripts/init.sh` already expects as `src.app:app`): app factory, `/healthz/live`, `/healthz/ready` (checks DB), problem+json error handler, `orjson` responses.
4. `src/utils/settings.py`: `pydantic-settings` class reading the env vars already in `docker-compose.yml` (`PG_HOST`, `PG_USER`, `PG_PASSWORD`, `DB_NAME`, `DB_PORT`).
5. `src/utils/db.py`: async engine and session factory (asyncpg), explicit pool size.
6. Wire `src/alembic/env.py` to `target_metadata` from `src/models` and to the settings URL. Check what `scripts/create_migration.py` does before relying on it; `init.sh` runs it on every start, so make sure it is idempotent and doesn't generate a new revision on each boot.
7. First migration: `CREATE EXTENSION postgis; citext; btree_gist;` plus `CREATE SCHEMA` for `rides`, `pricing`, `tracking`, `platform`.
8. Add to compose: Redis, and OSRM (see Stage 2). Keep them optional with compose profiles so the app still starts without them.
9. `pyproject` tool config: ruff, mypy (strict for `src/services` and `src/schemas`), pytest. Fill the empty `.pre-commit-config.yaml` with ruff + ruff-format.
10. `.importlinter` with the layers contract from doc 03 §2.4.

**Tests:** `/healthz/ready` integration test against a testcontainers PostGIS; a test that `alembic upgrade head` then `downgrade base` works.

**Exit demo:** `docker compose up`, `curl localhost:8000/healthz/ready` → 200.

---

## Stage 2: Money, geo, and fare quotes (1 week)

**Why now:** every other feature (rides, pool savings, fares) depends on correct money and a
way to get route distance and time.

**Tasks**
1. `src/schemas/money.py`: frozen `Money(amount_minor: int, currency)`, `+`, `-`, comparison, and `allocate(weights)` using the largest-remainder method (doc 02 §4). **Write the Hypothesis tests first**: allocation always sums exactly to the total, never negative, deterministic.
2. `src/schemas/geo.py`: `GeoPoint` with range validation; `utils/geo.py`: haversine, bearing, H3 cell helper.
3. OSRM: add a compose service with a small OSM extract (your city only, from Geofabrik; Hyderabad lies in the southern-zone India extract, so cut it down with `osmium extract` and a bounding box, otherwise preprocessing is slow and memory-hungry). `src/clients/osrm.py`: `route(a, b)` and `table(points)` behind a `TravelTimeOracle` protocol. **Also write `HaversineOracle`** (straight-line × 1.35, 25 km/h): used by every unit test and as the fallback.
4. Tables: `pricing.rate_cards` (with the EXCLUDE constraint) and `pricing.fare_quotes` (doc 04 §3.7). Seed one rate card per product.
5. `services/pricing.py` (pure): `quote(route, rate_card, surge, product) -> FareQuote`. Pool price in this stage = `solo × (1 - pool_discount_bps)`, a fixed discount. The smarter version arrives in Stage 6.
6. `repositories/pricing.py`, `controller/pricing.py`, `api/quotes.py`: `POST /v1/fare-quotes`, with the quote stored and an expiry.

**Tests:** unit tests for rate-card math with the doc 07 numbers (₹50 base + ₹22/km + ₹1/min → ₹340 for 12 km / 26 min); integration test for the EXCLUDE constraint rejecting overlapping cards.

**Exit demo:** quote request returns solo and pool prices, with a `quote_id` and `expires_at`.

---

## Stage 3: Drivers and locations (4–5 days)

**Tasks**
1. Tables: `drivers.drivers`, `drivers.vehicles` (with the partial unique index), `tracking.driver_locations` (doc 04 §3.2, §3.6). Skip documents/approval workflow: create drivers as `APPROVED` through a seed script.
2. `POST /v1/drivers/me/availability` and `POST /v1/drivers/me/locations` (batched pings). Validate coordinates and reject pings with impossible speed (> 50 m/s from the previous ping).
3. Out-of-order guard: upsert `WHERE excluded.recorded_at > driver_locations.recorded_at`.
4. `repositories/tracking.py`: **nearest available drivers via PostGIS** (`ST_DWithin` + `<->` KNN, doc 05 §4.1), filtered to pings under 30 s old. Check with `EXPLAIN` that the GiST partial index is used, and save the plan in a note.
5. `scripts/driver_bot.py`: a bot that logs in as a seeded driver, goes online, and moves along an OSRM route sending pings every 4 s. You'll reuse this in every later stage.

**Tests:** KNN ordering test; stale-driver exclusion; out-of-order ping ignored.

**Exit demo:** run two bots; a query returns the nearest one first.

*(Redis GEO replaces this in Stage 8, after you have a working baseline to benchmark against.)*

---

## Stage 4: Solo ride lifecycle (1.5 weeks)

**Why now:** this builds the Ride and Trip aggregates, state machines, and transactions that
Pool extends. Get these right before adding Pool.

**Tasks**
1. Tables: `rides.rides`, `rides.trips`, `rides.trip_stops`, `rides.trip_segments` (doc 04 §3.3–3.4), including the partial unique indexes (one active ride per rider, one active trip per driver).
2. `services/ride_state.py` (pure): explicit allowed-transition table for Ride and Trip. A Hypothesis state-machine test that applies random sequences of commands and asserts no illegal state is ever reachable.
3. `services/trip_plan.py` (pure): the `Trip` object holding ordered stops, `seats_occupied_after(i)`, `insert`, `remove`, and invariant checks (pickup before drop-off, capacity at every point, completed stops frozen). Solo only uses two stops, but write it for N now.
4. Dispatch (simple, synchronous in this stage): `controller/rides.py::request_ride` → create ride from `quote_id` → find nearest drivers → rank by OSRM ETA → create a Trip with `DISPATCHING` and a driver offer.
5. Offers: `rides.driver_offers` table with `expires_at`. Driver `accept` and `decline` endpoints. Timeout handling through a simple loop in `workers/` using `FOR UPDATE SKIP LOCKED` on expired offers → re-dispatch excluding that driver. After N attempts → `NO_DRIVERS`.
6. Stop endpoints: `arrive`, `complete` (pickup then drop-off). On each stop completion write the `trip_segments` row (distance, duration, onboard riders). Use the planned values for now and real odometer later.
7. Cancel with a simple policy (free before driver assigned, flat fee after).
8. Rider endpoints: get ride, active ride, history (keyset paginated).
9. **Idempotency:** `Idempotency-Key` on `POST /rides` and stop `complete` (doc 16 §7). Do it now, since retrofitting is awkward.
10. Concurrency tests: two simultaneous `request_ride` calls by one rider → exactly one succeeds; two riders racing for one driver → one wins, the other is re-dispatched.

**Tests:** state machine property tests; the concurrency tests above; an integration test driving the full flow through the controller layer.

**Exit demo:** `scripts/rider_bot.py` + `driver_bot.py` run a complete solo ride (quote → request → accept → pickup → drop-off), and the API shows `COMPLETED` with segments recorded.

---

## Stage 5: Pool matching (2–3 weeks): the core feature

**Why this order inside the stage:** the planner is pure and the hardest part, so it's built and
proven correct before anything touches the database.

### 5a. Insertion planner, pure (4–5 days)
1. `services/matching/insertion.py`: `best_insertion(trip, request, oracle) -> Plan | None` (doc 06 §3 Phase 3 and §4 pseudocode): try every (pickup index, drop-off index), check capacity, each rider's deadline, compute added vehicle time.
2. Start with the **naive O(n³)** version (recompute arrival times per candidate). Get it correct.
3. **Brute-force oracle test:** generate random small trips (≤ 4 stops) with Hypothesis, enumerate every insertion independently, assert the planner picks an optimal feasible one (or `None` when none exists).
4. Then add **slack times** (doc 06) and re-run the same oracle test unchanged: this proves the optimization didn't change results.
5. Use `HaversineOracle` throughout so tests are deterministic and need no OSRM.

### 5b. Candidate filtering (3 days)
1. `services/matching/filters.py` (pure): direction check (bearing within 60°), corridor check, detour lower bound.
2. `repositories/matching.py`: open Pool trips near a pickup (partial GiST on `planned_route`, doc 04 §3.3) and waiting Pool rides (`rides_matching_pickup_gist`). Keep H3 for later; PostGIS is enough at this scale and one tool at a time is easier to learn.
3. `trips.planned_route` is kept up to date whenever stops change (OSRM route through remaining stops, simplified).

### 5c. Matching and commit (5–6 days)
1. `controller/matching.py::match_batch(region)`: gather waiting Pool rides, run filters → planner for each (existing trip, other waiting ride, idle driver) option, score, pick a non-conflicting set greedily (doc 06 §4).
2. **Commit with optimistic concurrency:** `UPDATE rides.trips SET ..., version = version + 1 WHERE id = :id AND version = :expected`. Zero rows → conflict → re-plan (max 3 tries) → fall back to solo dispatch.
3. `workers/matching_worker.py`: a simple loop, every `MATCH_BATCH_WINDOW_MS` (default 3 s) pick up `MATCHING` pool rides. No Kafka yet; the DB is the queue (`FOR UPDATE SKIP LOCKED`). This is the same loop you'll later feed from Kafka.
4. Pool request flow: `request_ride(product=POOL)` sets the ride to `MATCHING`; the worker either inserts it into a trip, pairs it with another waiting ride + driver, or after `max_wait` falls back to solo dispatch (rider keeps the pool price, doc 07 Alg. 5).
5. Insertion side effects: re-sequence stops (the deferrable unique constraint, doc 04 §3.4), recompute `planned_eta`s, update the driver's stop list.
6. Cancellation of one pool rider: remove their two stops, re-plan, keep the other rider's fare from rising.
7. Detour guarantee: store `max_dropoff_at` per ride at request time; the planner enforces it against both the new rider and everyone already onboard.

**Tests (the important ones)**
- Oracle test from 5a.
- Two concurrent matchers inserting different riders into the same trip → exactly one wins, no seat is double-booked.
- Capacity: a 2-seat party plus a 2-seat party in a 4-seat car OK; a third party rejected.
- Opposite-direction rider on the same road is rejected (the `ST_LineLocatePoint` ordering case, doc 05 §6.1).
- Detour budget violation for an *onboard* rider rejects the insertion.

**Exit demo:** `rider_bot` × 2 with overlapping routes and one `driver_bot`: both end up on one trip, stop order is `P_A, P_B, D_A, D_B` (or the cheaper order), and the API shows each rider their own ETAs and the co-rider's first name.

**Proposal mode (your original two-party consent flow):** do it *after* the exit demo works,
as an optional 5d (4–5 days), behind `POOL_PROPOSAL_MODE_PERCENT`. It reuses the same planner;
the new work is `matching.ride_matches` + participants tables, the accept/decline endpoints, a
durable timeout (reuse the offer-timeout loop), and compensation on decline (doc 06 §3 Phase 6).

---

## Stage 6: Pool fare allocation (1 week)

**Tasks**
1. `services/fare_engines/base.py`: the `FareAllocationStrategy` protocol and `TripCostInput` (doc 07 §9).
2. Implement `distance_weighted.py`, `distance_time.py`, `segment_based.py`, `shapley.py`. Each is a small pure function over `Money.allocate`.
3. **Executable documentation:** a unit test per algorithm that asserts the doc 07 worked example to the paisa (A=₹284.21/B=₹165.79; ₹280.09/₹169.91; ₹305.36/₹144.64).
4. Hypothesis properties for all strategies: sums exactly to total, non-negative, symmetric for identical riders; Shapley additionally never exceeds the solo price.
5. Algorithm 5 (the upfront price): improve Stage 2's fixed discount using a lookup `P(match)` by area and hour (start with a constant per city; the hook is what matters). Add `services/driver_pay.py`.
6. `pricing.fares` + `fare_breakdowns` written when a ride completes (synchronously in the `complete drop-off` controller for now; becomes event-driven in Stage 8). `UNIQUE(ride_id)` makes it idempotent.
7. **Shadow mode:** on every completed pool trip, also compute the other four algorithms and store their results in `fares.algorithm_inputs`. Add `GET /v1/admin/trips/{id}/fare-comparison`.
8. Receipt endpoint with line items (doc 07 §8).

**Exit demo:** complete a two-rider pool trip; the receipt shows each rider's upfront price, and the comparison endpoint shows what each algorithm would have charged.

---

## Stage 7: Authentication, minimal real version (3–4 days)

Only now, and only the minimum.

1. `identity.users` table, `POST /auth/register`, `POST /auth/login` with argon2id (`pwdlib`).
2. Access JWT (ES256, 15 min) via `pyjwt`. **Skip refresh tokens, OTP, MFA, logout-all** for now; note them in a TODO in `docs/notes/auth.md` (design is in doc 14 for when you want them).
3. Replace the header stub in `src/api/deps.py` with real verification, with `alg`/`aud`/`iss`/`exp` pinned. Roles come from the token.
4. Update bots to log in. Keep a `DEV_AUTH_STUB=true` setting for local debugging, **off by default and refused when `APP_ENV=prod`**.
5. Route-by-role test that walks every route as anonymous / rider A / rider B / driver / admin (doc 14 §3).

---

## Stage 8: Hardening (2–3 weeks), pick in this order

Each item has its design in an existing doc; here is only the order and the reason.

1. **Test and CI baseline** (doc 12, 15): GitHub Actions `pr.yml` with lint, types, import-linter, unit, integration. Reason: protects everything built so far.
2. **Redis GEO for driver locations** (doc 10): keep the PostGIS path, add Redis behind the same repository interface, benchmark both with Locust at 300 and 3,000 updates/s, write the ADR with numbers.
3. **Outbox** (doc 16 §5): write events to `platform.outbox` in the same transactions as state changes; a relay that just logs them first, Kafka after.
4. **Kafka**: replace the matching worker's DB polling with a `ride-requested` consumer; inbox-based idempotent consumers; DLQ (doc 09).
5. **Observability** (doc 13): structlog JSON, OTel traces, RED metrics, the match-latency and match-rate dashboard.
6. **Load tests** (doc 15): small scale first, write the report, fix the first bottleneck, repeat.
7. **Kubernetes + deploy pipeline** (docs 11–12).
8. **WebSocket tracking gateway** (doc 08 §2.6), instead of polling.
9. **Reliability extras** (doc 16): circuit breakers with fallbacks, reconciliation jobs.
10. **Security hardening** (doc 14) and the production checklist (doc 17).

---

## Recommended repository changes, in order

```
Stage 1:  src/app.py  src/utils/{settings,db,clock,ids}.py  src/models/base.py
          tests/{unit,integration}/conftest.py  .importlinter  new alembic revision
Stage 2:  src/schemas/{money,geo,pricing}.py  src/clients/osrm.py  src/services/pricing.py
          src/repositories/pricing.py  src/controller/pricing.py  src/api/quotes.py
Stage 3:  src/{models,repositories,controller,api}/{drivers,tracking}.py  scripts/driver_bot.py
Stage 4:  src/services/{ride_state,trip_plan}.py  src/{models,repositories,controller,api}/{rides,trips}.py
          src/workers/offer_timeouts.py  scripts/rider_bot.py
Stage 5:  src/services/matching/{insertion,filters}.py  src/repositories/matching.py
          src/controller/matching.py  src/workers/matching_worker.py
Stage 6:  src/services/fare_engines/*.py  src/services/driver_pay.py  src/{models,repositories,controller,api}/fares.py
```

## Risks to watch

| Risk | Mitigation |
|---|---|
| Spending weeks on OSRM setup | Use `HaversineOracle` for all logic and tests; wire real OSRM only for the demos. A small city extract preprocesses in minutes. |
| Planner bugs that only show up under odd stop orders | The brute-force oracle test (5a) is non-negotiable. |
| Scope creep into auth, UI, notifications | Stage 7 is the only auth work until Stage 6 is demoed. Test with bots and Swagger, not a UI. |
| Pool never matches in manual tests (not enough traffic) | The simulator idea from doc 06 §7: a script that spawns N synthetic riders and drivers along real routes. Build a minimal one at the end of Stage 5. |
| `init.sh` runs migrations on every app start | Fine for dev. Before running more than one replica, move migrations to a separate step (doc 11 §3.7). |

## What to build first, concretely (this week)

1. Stage 1 task 1 (Python version check), then tasks 3–7.
2. Then `Money` with its Hypothesis tests (Stage 2, task 1). It's small, self-contained, and the first piece of the core.