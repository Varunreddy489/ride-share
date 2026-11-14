# 04 — Database Design (PostgreSQL + PostGIS)

> Covers prompt section 6. The prompt's table list is kept, with two renames that
> follow the Ride/Trip split from doc 02:
> `shared_rides` → **`trips`** (a shared ride *is* a trip with `mode = 'POOL'`; a view
> named `shared_rides` is provided for readability), and `route_segments` → **`trip_stops`**
> plus **`trip_segments`**.

---

## 1. Cross-cutting conventions (and why)

| Convention | Rationale |
|---|---|
| **Schema per module** (`identity`, `drivers`, `rides`, `matching`, `pricing`, `payments`, `tracking`, `platform`) | Ownership boundary; a schema can be moved to its own DB at extraction time. |
| **UUID v7 primary keys** (`uuid` type, generated in app) | Time-ordered → B-tree-friendly inserts (unlike v4). Globally unique → safe across services and events. Not guessable → no IDOR enumeration. |
| **`timestamptz` everywhere**, stored in UTC | Never `timestamp without time zone`. |
| **Money as `bigint` minor units + `char(3)` currency** | Exact, fast, no `numeric` rounding surprises. |
| **Status as `text` + `CHECK` constraint** (not Postgres `ENUM`) | Adding an enum value needs a migration that can't run in a transaction on older PG versions and is awkward to remove. `CHECK` is trivially alterable. |
| **`created_at`, `updated_at`, `version`** on mutable aggregates | Auditing and optimistic locking. |
| **No cross-schema FKs** except to `identity.users(id)` | Cross-module FKs block future extraction. Integrity across modules is maintained by events + reconciliation jobs. *Within* a module, use FKs aggressively. |
| **`geography(Point, 4326)`** for points; `geometry(LineString, 4326)` for routes | See doc 05 for the geography vs. geometry tradeoff. |
| **Soft delete only where legally needed** (users) | Soft delete everywhere pollutes every query and every index. |

---

## 2. ER Diagram

```mermaid
erDiagram
  USERS ||--o| RIDERS : "is a"
  USERS ||--o| DRIVERS : "is a"
  USERS ||--o{ REFRESH_TOKENS : has
  DRIVERS ||--o{ VEHICLES : owns
  DRIVERS ||--o| DRIVER_LOCATIONS : "latest position"
  DRIVERS ||--o{ DRIVER_LOCATION_HISTORY : pings
  RIDERS ||--o{ FARE_QUOTES : requests
  RIDERS ||--o{ RIDES : books
  FARE_QUOTES ||--o| RIDES : "used by"
  DRIVERS ||--o{ TRIPS : drives
  VEHICLES ||--o{ TRIPS : "used in"
  TRIPS ||--|{ TRIP_STOPS : "ordered stops"
  TRIPS ||--o{ TRIP_SEGMENTS : "realized legs"
  TRIPS ||--o{ RIDES : serves
  RIDES ||--|{ TRIP_STOPS : "pickup + dropoff"
  RIDE_MATCHES ||--|{ RIDE_MATCH_PARTICIPANTS : has
  RIDES ||--o{ RIDE_MATCH_PARTICIPANTS : "offered in"
  RIDES ||--o| FARES : "charged by"
  FARES ||--|{ FARE_BREAKDOWNS : "line items"
  RATE_CARDS ||--o{ FARE_QUOTES : "priced with"
  FARES ||--o{ PAYMENTS : "settled by"
  PAYMENTS ||--o{ PAYMENT_ATTEMPTS : "tries"

  USERS { uuid id PK; text email UK; text phone UK; text password_hash; text[] roles; text status }
  RIDERS { uuid user_id PK,FK; numeric rating; jsonb preferences }
  DRIVERS { uuid user_id PK,FK; text status; text availability; text city_code; numeric rating }
  VEHICLES { uuid id PK; uuid driver_id FK; text plate UK; smallint seats; bool is_active }
  RIDES { uuid id PK; uuid rider_id; uuid trip_id FK; text product; text status; geography pickup; geography dropoff; uuid quote_id FK }
  TRIPS { uuid id PK; uuid driver_id FK; uuid vehicle_id FK; text mode; text status; smallint capacity; int version }
  TRIP_STOPS { uuid id PK; uuid trip_id FK; uuid ride_id FK; text kind; smallint seq; text status; geography location }
  TRIP_SEGMENTS { uuid id PK; uuid trip_id FK; smallint seq; int distance_m; int duration_s; uuid[] onboard_ride_ids }
  RIDE_MATCHES { uuid id PK; text status; timestamptz expires_at; jsonb plan }
  RIDE_MATCH_PARTICIPANTS { uuid match_id PK,FK; uuid ride_id PK,FK; text response; bigint savings_minor }
  FARE_QUOTES { uuid id PK; uuid rider_id; uuid rate_card_id FK; bigint solo_minor; bigint pool_minor; timestamptz expires_at }
  FARES { uuid id PK; uuid ride_id FK,UK; bigint total_minor; text algorithm; text status }
  FARE_BREAKDOWNS { uuid id PK; uuid fare_id FK; text item_type; bigint amount_minor }
  PAYMENTS { uuid id PK; uuid fare_id FK; text status; bigint amount_minor; text idempotency_key UK }
```

---

## 3. Tables

### 3.1 `identity.users`

```sql
CREATE SCHEMA identity;

CREATE TABLE identity.users (
    id              uuid PRIMARY KEY,
    email           citext UNIQUE,
    phone_e164      text UNIQUE,
    password_hash   text,                         -- argon2id via pwdlib
    full_name       text NOT NULL,
    roles           text[] NOT NULL DEFAULT '{RIDER}',
    status          text NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','SUSPENDED','DELETED')),
    token_version   int  NOT NULL DEFAULT 0,      -- bump → invalidates all refresh tokens
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    CHECK (email IS NOT NULL OR phone_e164 IS NOT NULL),
    CHECK (roles <@ ARRAY['RIDER','DRIVER','ADMIN','SUPPORT']::text[])
);

CREATE TABLE identity.refresh_tokens (
    id           uuid PRIMARY KEY,               -- the token's jti
    user_id      uuid NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
    family_id    uuid NOT NULL,                  -- rotation family (reuse detection)
    token_hash   bytea NOT NULL,                 -- sha256 of the opaque token, never the token
    expires_at   timestamptz NOT NULL,
    revoked_at   timestamptz,
    replaced_by  uuid,
    user_agent   text,
    ip           inet,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON identity.refresh_tokens (user_id) WHERE revoked_at IS NULL;
CREATE INDEX ON identity.refresh_tokens (family_id);
```

- `citext` email avoids case-variant duplicates (needs `CREATE EXTENSION citext`).
- Roles as an array is fine at this scale. A `user_roles` join table is the normalized alternative once you need per-role metadata.

### 3.2 `riders` and `drivers`, `vehicles`

```sql
CREATE TABLE identity.riders (
    user_id      uuid PRIMARY KEY REFERENCES identity.users(id),
    rating       numeric(3,2) NOT NULL DEFAULT 5.00 CHECK (rating BETWEEN 1 AND 5),
    rating_count int NOT NULL DEFAULT 0,
    preferences  jsonb NOT NULL DEFAULT '{}'      -- e.g. {"pool_gender_pref": "SAME"}
);

CREATE SCHEMA drivers;

CREATE TABLE drivers.drivers (
    user_id         uuid PRIMARY KEY,             -- references identity.users logically
    city_code       text NOT NULL,                -- 'HYD', 'BLR'
    license_number  text NOT NULL UNIQUE,
    status          text NOT NULL DEFAULT 'PENDING_APPROVAL'
                    CHECK (status IN ('PENDING_APPROVAL','APPROVED','SUSPENDED','REJECTED')),
    availability    text NOT NULL DEFAULT 'OFFLINE'
                    CHECK (availability IN ('OFFLINE','AVAILABLE','ON_TRIP')),
    rating          numeric(3,2) NOT NULL DEFAULT 5.00,
    approved_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (availability = 'OFFLINE' OR status = 'APPROVED')
);
CREATE INDEX ON drivers.drivers (city_code, availability);

CREATE TABLE drivers.vehicles (
    id          uuid PRIMARY KEY,
    driver_id   uuid NOT NULL REFERENCES drivers.drivers(user_id),
    plate       text NOT NULL UNIQUE,
    make        text NOT NULL,
    model       text NOT NULL,
    color       text NOT NULL,
    seats       smallint NOT NULL CHECK (seats BETWEEN 1 AND 8),
    category    text NOT NULL CHECK (category IN ('HATCHBACK','SEDAN','SUV')),
    is_active   boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now()
);
-- One active vehicle per driver, enforced by the DB, not just app code:
CREATE UNIQUE INDEX one_active_vehicle_per_driver
    ON drivers.vehicles (driver_id) WHERE is_active;
```

**Partial unique indexes** are the pattern to learn here: they encode business invariants
("at most one active X per Y") that application code alone can't enforce under concurrency.

### 3.3 `rides.trips` (= shared_rides) and `rides.rides`

```sql
CREATE SCHEMA rides;

CREATE TABLE rides.trips (
    id              uuid PRIMARY KEY,
    driver_id       uuid NOT NULL,
    vehicle_id      uuid NOT NULL,
    city_code       text NOT NULL,
    mode            text NOT NULL CHECK (mode IN ('SOLO','POOL')),
    status          text NOT NULL CHECK (status IN
                    ('DISPATCHING','EN_ROUTE','IN_PROGRESS','COMPLETED','CANCELLED')),
    capacity        smallint NOT NULL CHECK (capacity BETWEEN 1 AND 8),
    accepts_insertions boolean NOT NULL DEFAULT false,   -- Pool and not closed for matching
    planned_route   geometry(LineString, 4326),          -- current remaining plan (from OSRM)
    version         int NOT NULL DEFAULT 0,              -- optimistic locking
    started_at      timestamptz,
    completed_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
-- A driver can be on at most one active trip:
CREATE UNIQUE INDEX one_active_trip_per_driver ON rides.trips (driver_id)
    WHERE status IN ('DISPATCHING','EN_ROUTE','IN_PROGRESS');
-- Pool candidate search: only open pool trips, spatially indexed.
CREATE INDEX trips_open_pool_route_gist ON rides.trips USING gist (planned_route)
    WHERE mode = 'POOL' AND accepts_insertions;

CREATE VIEW rides.shared_rides AS
    SELECT * FROM rides.trips WHERE mode = 'POOL';

CREATE TABLE rides.rides (
    id                uuid PRIMARY KEY,
    rider_id          uuid NOT NULL,
    trip_id           uuid REFERENCES rides.trips(id),
    quote_id          uuid NOT NULL,                -- pricing.fare_quotes (logical ref)
    city_code         text NOT NULL,
    product           text NOT NULL CHECK (product IN ('SOLO','POOL')),
    seats             smallint NOT NULL DEFAULT 1 CHECK (seats BETWEEN 1 AND 2),
    status            text NOT NULL CHECK (status IN
                      ('REQUESTED','MATCHING','PROPOSED','DRIVER_OFFERED','DRIVER_ASSIGNED',
                       'DRIVER_ARRIVED','IN_PROGRESS','COMPLETED','CANCELLED','NO_SHOW','NO_DRIVERS')),
    pickup            geography(Point, 4326) NOT NULL,
    dropoff           geography(Point, 4326) NOT NULL,
    pickup_h3_r9      text NOT NULL,                -- precomputed cell for bucketing/surge
    solo_distance_m   int NOT NULL,                 -- from quote's route snapshot
    solo_duration_s   int NOT NULL,
    max_pickup_at     timestamptz,                  -- service guarantees for the matcher
    max_dropoff_at    timestamptz,
    cancelled_by      text CHECK (cancelled_by IN ('RIDER','DRIVER','SYSTEM','ADMIN')),
    cancel_reason     text,
    requested_at      timestamptz NOT NULL DEFAULT now(),
    picked_up_at      timestamptz,
    dropped_off_at    timestamptz,
    version           int NOT NULL DEFAULT 0,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK (NOT ST_Equals(pickup::geometry, dropoff::geometry))
);
-- One active ride per rider (business rule + abuse prevention):
CREATE UNIQUE INDEX one_active_ride_per_rider ON rides.rides (rider_id)
    WHERE status NOT IN ('COMPLETED','CANCELLED','NO_SHOW','NO_DRIVERS');
CREATE INDEX rides_rider_history ON rides.rides (rider_id, requested_at DESC);  -- trip history
CREATE INDEX rides_trip ON rides.rides (trip_id);
-- Matcher backlog (small, hot): partial index keeps it tiny.
CREATE INDEX rides_matching_pickup_gist ON rides.rides USING gist (pickup)
    WHERE status = 'MATCHING';
```

**Index rationale:**
- `rides_rider_history (rider_id, requested_at DESC)` serves `WHERE rider_id = ? ORDER BY requested_at DESC LIMIT 20` with keyset pagination, an index-only range scan.
- Partial GiST on `MATCHING` rides: the full table grows forever, but at most a few hundred rides are in MATCHING at once. A partial index stays tiny and hot in memory.

### 3.4 `rides.trip_stops` and `rides.trip_segments` (= route_segments)

```sql
CREATE TABLE rides.trip_stops (
    id            uuid PRIMARY KEY,
    trip_id       uuid NOT NULL REFERENCES rides.trips(id) ON DELETE CASCADE,
    ride_id       uuid NOT NULL REFERENCES rides.rides(id),
    kind          text NOT NULL CHECK (kind IN ('PICKUP','DROPOFF')),
    seq           smallint NOT NULL,
    status        text NOT NULL DEFAULT 'PLANNED'
                  CHECK (status IN ('PLANNED','ARRIVED','COMPLETED','SKIPPED')),
    location      geography(Point, 4326) NOT NULL,
    planned_eta   timestamptz,
    arrived_at    timestamptz,
    completed_at  timestamptz,
    UNIQUE (ride_id, kind),
    -- seq unique per trip, deferrable so a re-sequence can swap values in one tx:
    CONSTRAINT trip_stop_seq_unique UNIQUE (trip_id, seq) DEFERRABLE INITIALLY DEFERRED
);

-- Immutable record of each realized leg between consecutive stops. The fare engine's input.
CREATE TABLE rides.trip_segments (
    id                uuid PRIMARY KEY,
    trip_id           uuid NOT NULL REFERENCES rides.trips(id),
    seq               smallint NOT NULL,
    from_stop_id      uuid,                         -- null for the deadhead leg to the first pickup
    to_stop_id        uuid NOT NULL REFERENCES rides.trip_stops(id),
    distance_m        int NOT NULL CHECK (distance_m >= 0),
    duration_s        int NOT NULL CHECK (duration_s >= 0),
    onboard_ride_ids  uuid[] NOT NULL,              -- riders in the car during this leg
    path              geometry(LineString, 4326),   -- map-matched actual path
    UNIQUE (trip_id, seq)
);
CREATE INDEX ON rides.trip_segments USING gin (onboard_ride_ids);
```

Why `DEFERRABLE` on `(trip_id, seq)`: inserting B between existing stops means shifting
`seq` values. With an immediate unique constraint, `UPDATE ... SET seq = seq + 1` can collide
mid-statement. Deferring the check to commit time makes the re-sequence atomic.

Why segments are stored rather than recomputed: the fare must be **reproducible** from
immutable facts even if the routing engine's map data changes next month.

### 3.5 `matching.ride_matches` (proposal mode)

```sql
CREATE SCHEMA matching;

CREATE TABLE matching.ride_matches (
    id              uuid PRIMARY KEY,
    trip_id         uuid,                          -- existing trip (insertion) or null (new pair)
    status          text NOT NULL CHECK (status IN ('PENDING','ACCEPTED','DECLINED','EXPIRED','SUPERSEDED')),
    plan            jsonb NOT NULL,                -- proposed stop sequence + ETAs (snapshot)
    algorithm       text NOT NULL,                 -- 'insertion_v2', for experiments
    score           numeric NOT NULL,
    expires_at      timestamptz NOT NULL,
    resolved_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pending_matches_expiry ON matching.ride_matches (expires_at) WHERE status = 'PENDING';

CREATE TABLE matching.ride_match_participants (
    match_id         uuid NOT NULL REFERENCES matching.ride_matches(id) ON DELETE CASCADE,
    ride_id          uuid NOT NULL,
    response         text NOT NULL DEFAULT 'PENDING' CHECK (response IN ('PENDING','ACCEPTED','DECLINED')),
    savings_minor    bigint NOT NULL CHECK (savings_minor >= 0),
    added_duration_s int NOT NULL CHECK (added_duration_s >= 0),
    responded_at     timestamptz,
    PRIMARY KEY (match_id, ride_id)
);
-- A ride can be in at most one PENDING proposal at a time. Enforced via a tiny lock table:
CREATE TABLE matching.ride_proposal_lock (
    ride_id   uuid PRIMARY KEY,
    match_id  uuid NOT NULL REFERENCES matching.ride_matches(id) ON DELETE CASCADE
);
```

`pending_matches_expiry` is what the expiry sweeper polls (`WHERE status='PENDING' AND expires_at < now() FOR UPDATE SKIP LOCKED`).

### 3.6 `tracking.driver_locations` (latest) and history

```sql
CREATE SCHEMA tracking;

-- One row per driver: the "last known position". UPSERT target. Kept small on purpose.
CREATE TABLE tracking.driver_locations (
    driver_id    uuid PRIMARY KEY,
    city_code    text NOT NULL,
    location     geography(Point, 4326) NOT NULL,
    heading_deg  smallint CHECK (heading_deg BETWEEN 0 AND 359),
    speed_mps    real,
    accuracy_m   real,
    availability text NOT NULL,
    recorded_at  timestamptz NOT NULL,    -- device time
    received_at  timestamptz NOT NULL DEFAULT now()
) WITH (fillfactor = 70);                 -- room for HOT updates
CREATE INDEX driver_locations_available_gist ON tracking.driver_locations
    USING gist (location) WHERE availability = 'AVAILABLE';

-- History: append-only, partitioned by day, dropped after retention.
CREATE TABLE tracking.driver_location_history (
    driver_id    uuid NOT NULL,
    trip_id      uuid,
    location     geography(Point, 4326) NOT NULL,
    speed_mps    real,
    recorded_at  timestamptz NOT NULL
) PARTITION BY RANGE (recorded_at);
CREATE INDEX ON tracking.driver_location_history (driver_id, recorded_at);
CREATE INDEX ON tracking.driver_location_history USING brin (recorded_at);
-- Partitions are created ahead of time by pg_partman (or a cron job):
-- CREATE TABLE tracking.driver_location_history_20261113 PARTITION OF ... FOR VALUES FROM ('2026-11-13') TO ('2026-11-14');
```

**Important design point:** in production, the *hot* nearest-driver query should be served
from **Redis GEO**, not this table (doc 10). This table exists so you can (a) compare
PostGIS KNN vs. Redis GEO in a benchmark, which is an excellent learning exercise, (b) serve as
the durable fallback if Redis is lost, and (c) power admin queries.

- `fillfactor = 70`: each update is a new tuple version in Postgres (MVCC). Leaving free
  space in each page allows **HOT (heap-only tuple) updates** when no indexed column changes.
  Since `location` *is* indexed, HOT won't apply to location updates. That's precisely why
  high-frequency location writes belong in Redis. Measure it: watch `n_tup_hot_upd` vs
  `n_tup_upd` in `pg_stat_user_tables`.
- History uses **BRIN** on time: tiny index, perfect for append-only time-correlated data.
- Dropping a day partition is O(1) vs. `DELETE` of 100M rows (which causes vacuum hell).

### 3.7 Pricing: `rate_cards`, `fare_quotes`, `fares`, `fare_breakdowns`

```sql
CREATE SCHEMA pricing;

CREATE TABLE pricing.rate_cards (
    id                 uuid PRIMARY KEY,
    city_code          text NOT NULL,
    product            text NOT NULL CHECK (product IN ('SOLO','POOL')),
    vehicle_category   text NOT NULL,
    version            int NOT NULL,
    base_minor         bigint NOT NULL,
    per_km_minor       bigint NOT NULL,
    per_min_minor      bigint NOT NULL,
    minimum_minor      bigint NOT NULL,
    booking_fee_minor  bigint NOT NULL,
    pool_discount_bps  int NOT NULL DEFAULT 0 CHECK (pool_discount_bps BETWEEN 0 AND 9000),
    tax_bps            int NOT NULL DEFAULT 500,          -- 5% GST
    effective_from     timestamptz NOT NULL,
    effective_to       timestamptz,
    UNIQUE (city_code, product, vehicle_category, version)
);
-- No overlapping active rate cards for the same key (needs btree_gist):
ALTER TABLE pricing.rate_cards ADD CONSTRAINT no_overlap EXCLUDE USING gist (
    city_code WITH =, product WITH =, vehicle_category WITH =,
    tstzrange(effective_from, effective_to) WITH &&);

CREATE TABLE pricing.fare_quotes (
    id                 uuid PRIMARY KEY,
    rider_id           uuid NOT NULL,
    city_code          text NOT NULL,
    rate_card_id       uuid NOT NULL REFERENCES pricing.rate_cards(id),
    pickup             geography(Point, 4326) NOT NULL,
    dropoff            geography(Point, 4326) NOT NULL,
    route_distance_m   int NOT NULL,
    route_duration_s   int NOT NULL,
    route_polyline     text NOT NULL,             -- encoded polyline snapshot
    surge_multiplier   numeric(4,2) NOT NULL CHECK (surge_multiplier >= 1),
    solo_total_minor   bigint NOT NULL,
    pool_total_minor   bigint,                    -- null if pool not offered here/now
    currency           char(3) NOT NULL DEFAULT 'INR',
    expires_at         timestamptz NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON pricing.fare_quotes (expires_at);   -- cleanup job

CREATE TABLE pricing.fares (
    id               uuid PRIMARY KEY,
    ride_id          uuid NOT NULL UNIQUE,          -- one final fare per ride (idempotency!)
    trip_id          uuid NOT NULL,
    quote_id         uuid NOT NULL,
    algorithm        text NOT NULL,                 -- 'upfront_v1', 'segment_shapley_v1'
    algorithm_inputs jsonb NOT NULL,                -- segments, weights: makes it reproducible
    subtotal_minor   bigint NOT NULL,
    tax_minor        bigint NOT NULL,
    total_minor      bigint NOT NULL CHECK (total_minor >= 0),
    currency         char(3) NOT NULL,
    status           text NOT NULL CHECK (status IN ('FINALIZED','ADJUSTED','VOIDED')),
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pricing.fare_breakdowns (
    id            uuid PRIMARY KEY,
    fare_id       uuid NOT NULL REFERENCES pricing.fares(id),
    item_type     text NOT NULL CHECK (item_type IN
                  ('BASE','DISTANCE','TIME','SURGE','POOL_DISCOUNT','BOOKING_FEE',
                   'CANCELLATION_FEE','WAIT_TIME','TAX','PROMO','ADJUSTMENT','ROUNDING')),
    amount_minor  bigint NOT NULL,                  -- negative for discounts
    description   text,
    seq           smallint NOT NULL,
    UNIQUE (fare_id, seq)
);
```

`UNIQUE (ride_id)` on `fares` is an **idempotency guarantee at the storage layer**: if the
`ride-completed` consumer processes a message twice, the second insert fails cleanly.
Defense in depth on top of the consumer inbox table.

The `EXCLUDE` constraint is an advanced Postgres feature worth learning: it guarantees no two
rate cards are active at the same time for the same key, a correctness rule that's
nearly impossible to enforce safely in app code.

### 3.8 Payments

```sql
CREATE SCHEMA payments;

CREATE TABLE payments.payments (
    id                uuid PRIMARY KEY,
    fare_id           uuid NOT NULL,
    ride_id           uuid NOT NULL,
    rider_id          uuid NOT NULL,
    amount_minor      bigint NOT NULL CHECK (amount_minor >= 0),
    currency          char(3) NOT NULL,
    method            text NOT NULL CHECK (method IN ('CARD','UPI','WALLET','CASH')),
    status            text NOT NULL CHECK (status IN
                      ('PENDING','AUTHORIZED','CAPTURED','FAILED','REFUNDED','PARTIALLY_REFUNDED')),
    psp               text,                         -- 'razorpay' | 'stripe' | 'fake'
    psp_payment_id    text,
    idempotency_key   text NOT NULL UNIQUE,
    version           int NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (psp, psp_payment_id)
);
CREATE INDEX ON payments.payments (rider_id, created_at DESC);   -- payment history

CREATE TABLE payments.payment_attempts (
    id             uuid PRIMARY KEY,
    payment_id     uuid NOT NULL REFERENCES payments.payments(id),
    operation      text NOT NULL CHECK (operation IN ('AUTHORIZE','CAPTURE','REFUND','VOID')),
    status         text NOT NULL CHECK (status IN ('SUCCEEDED','FAILED','TIMEOUT')),
    error_code     text,
    request_id     text NOT NULL,
    latency_ms     int,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- Double-entry ledger: the "real" source of truth for money movement.
CREATE TABLE payments.ledger_entries (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id        uuid NOT NULL,                 -- groups debit+credit legs
    account       text NOT NULL,                 -- 'rider:{id}', 'driver:{id}', 'platform:revenue', 'psp:clearing'
    amount_minor  bigint NOT NULL,               -- +debit / -credit
    currency      char(3) NOT NULL,
    ride_id       uuid,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON payments.ledger_entries (account, created_at);
-- Invariant (checked by a nightly job and a deferred constraint trigger): SUM(amount) per txn_id = 0
```

A double-entry ledger is the industry standard (Uber's "Gulfstream", Stripe, every bank).
It turns "where did ₹95 go?" into a query. Implement it, even simplified.

### 3.9 Platform tables: outbox, inbox, idempotency, audit

```sql
CREATE SCHEMA platform;

CREATE TABLE platform.outbox (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id        uuid NOT NULL UNIQUE,
    topic           text NOT NULL,
    partition_key   text NOT NULL,
    event_type      text NOT NULL,
    payload         jsonb NOT NULL,
    headers         jsonb NOT NULL DEFAULT '{}',   -- traceparent, schema version
    created_at      timestamptz NOT NULL DEFAULT now(),
    published_at    timestamptz
);
CREATE INDEX outbox_unpublished ON platform.outbox (id) WHERE published_at IS NULL;

CREATE TABLE platform.processed_events (            -- consumer-side "inbox" dedupe
    consumer_group  text NOT NULL,
    event_id        uuid NOT NULL,
    processed_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer_group, event_id)
);

CREATE TABLE platform.idempotency_keys (             -- HTTP Idempotency-Key storage
    key             text NOT NULL,
    user_id         uuid NOT NULL,
    request_hash    bytea NOT NULL,                  -- reject same key + different body
    status          text NOT NULL CHECK (status IN ('IN_PROGRESS','COMPLETED')),
    response_code   int,
    response_body   jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, key)
);

CREATE TABLE platform.scheduled_jobs (               -- durable timers (offer/proposal expiry)
    id          uuid PRIMARY KEY,
    job_type    text NOT NULL,
    payload     jsonb NOT NULL,
    run_at      timestamptz NOT NULL,
    status      text NOT NULL DEFAULT 'PENDING',
    attempts    int NOT NULL DEFAULT 0
);
CREATE INDEX ON platform.scheduled_jobs (run_at) WHERE status = 'PENDING';

CREATE TABLE platform.audit_log (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_id    uuid NOT NULL,
    action      text NOT NULL,
    entity      text NOT NULL,
    entity_id   uuid,
    before      jsonb,
    after       jsonb,
    ip          inet,
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

---

## 4. Operational database concerns

| Concern | Recommendation |
|---|---|
| **Connection pooling** | Async SQLAlchemy pool per pod (size 5–10) + **PgBouncer** in transaction mode in front of Postgres. Total pods × pool size must stay below `max_connections`. With asyncpg + PgBouncer transaction mode, disable prepared statement caching (`statement_cache_size=0`) or use PgBouncer ≥ 1.21 with `max_prepared_statements`. |
| **Isolation level** | `READ COMMITTED` (default) + explicit `SELECT ... FOR UPDATE` / version checks on contended aggregates. Use `SERIALIZABLE` only for the ledger. |
| **Migrations** | Alembic, **expand → migrate → contract** pattern for zero-downtime: add nullable column → backfill in batches → deploy code using it → add constraint `NOT VALID` → `VALIDATE CONSTRAINT`. Always `CREATE INDEX CONCURRENTLY` (needs `autocommit_block()` in Alembic). Set `lock_timeout = '5s'` in migrations. |
| **Read replicas** | Trip history, admin analytics, payment history → replica. Anything followed by a write → primary (read-your-writes). |
| **Vacuum** | Tune autovacuum per hot table (`autovacuum_vacuum_scale_factor = 0.01` on `driver_locations`, `outbox`). |
| **Observability** | `pg_stat_statements` enabled; export via `postgres_exporter`; log queries > 100 ms (`log_min_duration_statement`). |
| **Backups** | Base backups + WAL archiving (pgBackRest or a cloud-native operator like CloudNativePG) → point-in-time recovery. **Test restores monthly.** |
| **On Kubernetes** | Use the **CloudNativePG** operator (primary + replicas, failover, backups to S3). Or a managed DB (RDS/Cloud SQL), which is what most companies do. Running stateful DBs on K8s is a learning goal here, not a production recommendation for a small team. |