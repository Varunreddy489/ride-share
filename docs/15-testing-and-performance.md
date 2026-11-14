# 15 — Testing Strategy and Performance Testing

> Covers prompt sections 17 and 18.

---

## Part A: Testing Strategy

### 1. Test pyramid

```
                 ▲  E2E (≈ 15 tests)            kind cluster / docker-compose; full user journeys
                ▲▲▲ Contract (≈ 50)             OpenAPI fuzzing, event schema compatibility
              ▲▲▲▲▲ Integration (≈ 150)         real Postgres/PostGIS, Redis, Kafka via testcontainers
         ▲▲▲▲▲▲▲▲▲▲ Unit (≈ 800+)               pure domain: aggregates, fare engines, insertion planner
```

The hexagonal architecture (doc 03) is what makes this pyramid possible: the domain has no
I/O, so most logic is unit-tested in milliseconds. If your tests drift toward an "ice-cream
cone" (mostly E2E), the domain has leaked into infrastructure.

### 2. Coverage goals

| Area | Line + branch coverage | Additional bar |
|---|---|---|
| `src/services/` (fare, matching, state machines) | **≥ 95%** | Property-based tests for every invariant; **mutation testing** (`mutmut`) score ≥ 80% on `pricing` and `matching` |
| `src/controller/` | ≥ 85% | Every use case has a happy path + each domain error path |
| `src/repositories/`, `src/clients/` | ≥ 70% (via integration tests) | Every repository query has an integration test against real PostGIS |
| `src/api/` | ≥ 80% | Every route covered by the authz matrix test |
| Overall gate in CI | **≥ 85%** | Coverage must not drop on a PR (diff-cover) |

Coverage is a floor, not a goal. Mutation testing tells you whether the tests actually *assert* anything.

### 3. Unit tests (pytest)

```python
# tests/unit/pricing/test_allocation_properties.py
from hypothesis import given, strategies as st

@given(trip=trip_cost_inputs(max_riders=3))
@pytest.mark.parametrize("strategy", ALL_STRATEGIES, ids=lambda s: s.name)
def test_allocation_is_budget_balanced(strategy, trip):
    shares = strategy.allocate(trip)
    assert sum(s.amount_minor for s in shares.values()) == trip.total_cost.amount_minor

@given(trip=trip_cost_inputs(max_riders=3))
def test_shapley_is_individually_rational(trip):
    shares = ShapleyAllocation().allocate(trip)
    for ride_id, share in shares.items():
        assert share.amount_minor <= trip.solo[ride_id].price.amount_minor

def test_worked_example_from_design_doc():                      # doc 07 §1, executable documentation
    trip = example_trip(a_km=12, b_km=7, shared_km=5, total=Money(45000))
    assert DistanceWeighted().allocate(trip) == {A: Money(28421), B: Money(16579)}
    assert SegmentBased().allocate(trip)     == {A: Money(30536), B: Money(14464)}
```

```python
# tests/unit/rides/test_trip_aggregate.py
def test_insertion_rejected_when_capacity_exceeded_mid_route():
    trip = TripBuilder().pool(capacity=3).with_onboard(seats=2).with_stops("P_A", "D_A").build()
    with pytest.raises(CapacityExceeded):
        trip.insert_ride(ride(seats=2), pickup_index=0, dropoff_index=1)

def test_illegal_state_transition():
    ride = RideBuilder().status(RideStatus.COMPLETED).build()
    with pytest.raises(InvalidStateTransition):
        ride.cancel(reason="CHANGED_MIND", actor=Actor.RIDER)
```

Also unit-test the **insertion planner against a brute-force oracle**: for random small
instances (≤ 4 stops), enumerate every insertion and assert the optimized planner finds the
same optimum. This catches slack-time bugs that example tests never will.

### 4. Mocking strategy

| Dependency | In unit tests | In integration tests | Rationale |
|---|---|---|---|
| Postgres/PostGIS | **Fake repository** (in-memory dict implementing the port) | **Real** (testcontainers `postgis/postgis`) | Never mock SQL. Spatial queries must run on real PostGIS. |
| Redis | Fake (in-memory) or `fakeredis` | Real container | GEO commands and Lua scripts need the real thing. |
| Kafka | In-memory event bus fake | Real container (KRaft) or Redpanda | Test the outbox → relay → consumer chain for real. |
| OSRM | **Fake travel-time oracle** (haversine × 1.3 or a fixed matrix) | Fake HTTP server (`respx`) with recorded responses; one smoke test against real OSRM with a tiny extract | Deterministic tests; real OSRM is slow to boot. |
| PSP (payments) | Fake gateway with scriptable failures (timeout, decline, duplicate) | Same fake as a container / PSP sandbox in staging only | Failure modes are the point. |
| Clock | **Injected `Clock` port** | Same | Timeouts, TTLs, proposal expiry are untestable with `datetime.now()` calls scattered around. |
| ID generation | Injected | Real | Deterministic snapshots. |

Rule: **mock at the port boundary you own, never mock libraries** (`mock.patch("sqlalchemy...")` is a smell).

### 5. Integration tests

```python
# tests/integration/conftest.py
@pytest.fixture(scope="session")
def postgis():
    with PostgresContainer("postgis/postgis:16-3.4", driver="psycopg") as pg:
        run_alembic_upgrade(pg.get_connection_url())
        yield pg

@pytest.fixture
async def session(postgis):
    async with engine.connect() as conn:          # each test in a rolled-back transaction → isolation + speed
        trans = await conn.begin()
        async with AsyncSession(bind=conn, join_transaction_mode="create_savepoint") as s:
            yield s
        await trans.rollback()
```

Must-have integration tests:
- Nearest-driver KNN returns correctly ordered results, and `EXPLAIN` shows an index scan (assert on the plan text).
- `one_active_ride_per_rider` rejects concurrent requests (two asyncio tasks racing → exactly one succeeds).
- **Optimistic locking:** two concurrent `commit_insertion` calls on the same trip → one wins, one gets `VersionConflict`.
- Outbox: state change + outbox row in the same tx. Simulate a relay crash after publish and before marking → the consumer dedupes.
- Consumer idempotency: deliver the same event twice → one fare row.
- Migration: upgrade → downgrade → upgrade on a populated DB.

### 6. Contract tests

- **API (provider side):** **Schemathesis** generates requests from the OpenAPI spec and checks responses conform (status codes, schemas, no 500s). Run it in CI against the app started with fakes.
- **API (consumer side):** if a frontend or mobile app exists, **Pact** consumer-driven contracts. Optional for a solo project.
- **Events:** for each topic, a test (a) validates producer output against `contracts/events/<topic>.v*.json`; (b) runs every *historical* schema version's example payloads through the current consumer; (c) checks compatibility between the new schema and the previous one (JSON Schema diff or the Schema Registry compatibility API).
- **Breaking-change gate:** `oasdiff breaking` in the PR pipeline (doc 12).

### 7. End-to-end tests

Against docker-compose (local) or kind (CI), black-box over HTTP + WebSocket, with a
**simulated driver client** (a Python bot that goes online, streams GPS along an OSRM route,
and accepts offers):

1. Rider registers → quote → solo ride → driver bot accepts → pickup → drop-off → fare → payment captured → receipt matches the quote.
2. Two pool riders with overlapping routes → matched into one trip → stop order correct → both fares ≤ quotes → Σ consistent with the ledger.
3. Proposal mode: A accepts, B declines → both back to MATCHING → no trip created.
4. Driver bot goes silent mid-offer → offer times out → re-dispatched to another bot.
5. Rider cancels after a pool insertion → driver's stop list updated → the remaining rider's fare isn't increased.
6. Payment PSP fake fails twice then succeeds → payment captured exactly once.

Keep the suite small, deterministic (fixed seeds, fake clock where possible), and under ~10 min.

### 8. Other test types worth learning

| Type | Tool | Purpose |
|---|---|---|
| Chaos | Chaos Mesh / `kubectl delete pod` / Toxiproxy | Kill Redis, add Kafka latency, partition Postgres. Verify degradation, not data loss. |
| Simulation | Custom discrete-event simulator | Replay synthetic demand to compare matching algorithms offline (doc 06 §7) |
| Migration safety | `squawk` (Postgres migration linter) | Block locking DDL |
| Security | OWASP ZAP baseline scan against staging | |

---

## Part B: Performance Testing with Locust

### 1. Workload model

Load tests are only meaningful if the **traffic mix** is realistic. Model user classes from
the capacity estimates in doc 01 §3.2:

| User class | Weight | Behavior (per user) |
|---|---|---|
| `RiderBrowsing` | 60% | Login once → 1–3 fare quotes → think 5–20 s → maybe leave |
| `RiderRequesting` | 15% | Quote → request (70% solo / 30% pool) → poll ride every 3 s or hold a WS → cancel 7% |
| `DriverOnline` | 20% | Go online → POST location batch every 4 s → accept offers (85%) → walk stops |
| `RiderHistory` | 4% | Trip history + payment history pagination |
| `Admin` | 1% | Analytics summary, ride search |

```python
# tests/load/locustfile.py
from locust import HttpUser, task, between, events
import random

HYD_BBOX = (17.36, 78.33, 17.47, 78.52)

def rand_point():
    lat = random.uniform(HYD_BBOX[0], HYD_BBOX[2]); lng = random.uniform(HYD_BBOX[1], HYD_BBOX[3])
    return {"lat": round(lat, 6), "lng": round(lng, 6)}

class RiderRequesting(HttpUser):
    weight = 15
    wait_time = between(3, 8)

    def on_start(self):
        tok = self.client.post("/v1/auth/login", json=seeded_rider_credentials()).json()
        self.client.headers["Authorization"] = f"Bearer {tok['access_token']}"

    @task
    def request_ride(self):
        q = self.client.post("/v1/fare-quotes", json={"pickup": rand_point(), "dropoff": rand_point()},
                             name="/v1/fare-quotes").json()
        product = "POOL" if random.random() < 0.3 and any(o["product"] == "POOL" for o in q["options"]) else "SOLO"
        with self.client.post("/v1/rides", json={"quote_id": q["quote_id"], "product": product,
                                                  "payment_method_id": "pm_test"},
                              headers={"Idempotency-Key": uuid7str()}, name="/v1/rides",
                              catch_response=True) as r:
            if r.status_code == 409 and r.json().get("code") == "ACTIVE_RIDE_EXISTS":
                r.success()                     # expected under load; not an error
                return
        ride_id = r.json()["ride_id"]
        for _ in range(10):                     # poll until matched (or use a WS client)
            s = self.client.get(f"/v1/rides/{ride_id}", name="/v1/rides/{id}").json()
            if s["status"] not in ("REQUESTED", "MATCHING"):
                break
            self.sleep(3)

class DriverOnline(HttpUser):
    weight = 20
    wait_time = between(4, 4)                    # one batch per 4 s

    def on_start(self):
        self.login_as_seeded_driver()
        self.pos = rand_point()
        self.client.post("/v1/drivers/me/availability", json={"status": "AVAILABLE", "location": self.pos})

    @task
    def send_location(self):
        self.pos = drift(self.pos, meters=40)
        self.client.post("/v1/drivers/me/locations", json={"pings": [ping(self.pos)]},
                         name="/v1/drivers/me/locations")
```

**Custom metric for match latency:** Locust measures HTTP times only. Emit a custom event
`events.request.fire(request_type="MATCH", name="time_to_match", response_time=ms, ...)`
from the polling loop. Better still, read the server-side `ride_match_latency_seconds`
histogram in Grafana during the run. **Server-side metrics are the source of truth;**
client-side numbers include the load generator's own overhead.

**Running at scale:** Locust distributed mode (1 master + N workers) on Kubernetes (the Locust
Helm chart or the `locust-k8s-operator`). One worker process ≈ 500–2,000 simple users
(gevent; depends on think time). Run load generators **outside** the app's node pool.

### 2. Test types

| Type | Shape | Purpose |
|---|---|---|
| Smoke | 10 users, 1 min | Script works |
| Load | Ramp to target, hold 30 min | SLOs met at expected peak |
| Stress | Ramp past target until SLO breach | Find the breaking point and *which component* breaks first |
| Spike | 0 → 3× target in 30 s | HPA/KEDA reaction time, cold starts, connection storms |
| Soak | Target load, 4–8 h | Memory leaks, connection leaks, partition/table bloat, Kafka retention |

### 3. Plans per scale

**Data seeding for all plans:** seed riders and drivers to the stage's counts (doc 01 §3.2)
with `faker`, plus ~3 months of synthetic ride history (so history and analytics queries hit
realistic table sizes). Testing against empty tables gives meaningless results.

#### Small: 1,000 concurrent users (≈ the 10k-registered-rider stage at peak, ×3 headroom)

| Item | Value |
|---|---|
| Mix | 600 browsing, 150 requesting, 200 drivers, 40 history, 10 admin |
| Expected load | ~150 RPS API, ~50 location updates/s, ~1 ride/s |
| Environment | docker-compose on one machine, or kind with 1 api replica |
| Pass criteria | p99 < 200 ms on sync APIs, p95 match < 2 s, error rate < 0.1%, 0 DLQ |
| **Expected bottlenecks** | (1) OSRM calls on every quote (no cache yet); (2) a sync DB driver or a blocking call in an async route (event loop stalls); (3) N+1 queries in trip history; (4) default SQLAlchemy pool (5 + 10 overflow) exhausted |
| **Optimizations** | ETA/route cache on H3 keys; run blocking code via `anyio.to_thread`; `selectinload` and keyset pagination; size pools explicitly; add missing indexes found in `pg_stat_statements` |

#### Medium: 10,000 concurrent users (≈ the 100k stage at peak, ×3)

| Item | Value |
|---|---|
| Mix | Same ratios: 2,000 drivers → ~500 location updates/s; ~10 rides/s |
| Expected load | ~1,500 RPS API |
| Environment | kind/k3d multi-node or a small cloud cluster (3 × 4 vCPU), HPA on |
| Pass criteria | Same SLOs; HPA scales without errors during ramp; consumer lag < 5 s |
| **Expected bottlenecks** | (1) **Postgres connections**: pods × pool size > `max_connections` → add PgBouncer; (2) **location writes** if any go to Postgres → GiST index churn, WAL volume, autovacuum lag; (3) **single-partition hot spot** for a dense region on `ride-requested`; (4) Python CPU in JSON serialization (use `orjson` via `ORJSONResponse`); (5) the outbox relay's single-row publishing |
| **Optimizations** | PgBouncer (transaction mode); move the hot location path fully to Redis; batch outbox publishing (`SELECT … LIMIT 500 FOR UPDATE SKIP LOCKED` + async produce + one `UPDATE`); finer region partition keys; `orjson`; read replica for history/admin; Redis pipelining |

#### Large: 100,000 concurrent users (≈ beyond the 1M stage; a stress target)

| Item | Value |
|---|---|
| Mix | 20,000 drivers → **5,000 location updates/s**; ~100 rides/s; ~30k WebSockets |
| Expected load | ~15,000 RPS |
| Environment | Cloud cluster (autoscaling node pool), Locust distributed with 20–50 workers, managed or operator-run Postgres/Kafka. Run it for a few hours and tear down (cost!). |
| Pass criteria | SLOs at 1M-stage peak; graceful degradation (429s, not 5xx) beyond it |
| **Expected bottlenecks** | (1) **WebSocket gateway** memory and fan-out (30k connections; Redis pub/sub channel explosion); (2) **matching per region**: OSRM throughput (each batch fans out ~100s of table calls); (3) **Kafka** partition count limiting consumer parallelism; (4) **Postgres write throughput** on rides/trips/outbox (WAL, checkpoints); (5) **Redis single-thread** CPU for GEO operations; (6) the load generator itself (verify Locust worker CPU < 80%) |
| **Optimizations** | Shard the matcher by region (KEDA up to the partition count); OSRM replicas + aggressive ETA caching + a contraction-hierarchies (CH) build; send location updates only to subscribed WS connections, delta-encoded; Redis Cluster sharded by city; partition `rides` by month and `outbox` by day (drop old partitions instead of DELETE); consider a Timescale hypertable or Kafka→Parquet for history; protobuf for location events; HTTP keep-alive tuning at ingress; review per-pod `uvicorn` concurrency limits |

### 4. Process (what makes it engineering, not just running a tool)

1. **Hypothesis first:** "at 500 location updates/s, Postgres CPU will exceed 70% because of GiST updates."
2. Run, with dashboards recording (annotate the Grafana timeline with test start/stop).
3. Find the **first saturated resource** (USE method: utilization, saturation, errors), using traces of slow requests and `pg_stat_statements`.
4. Change **one** thing. Re-run. Compare.
5. Write the result up in `docs/perf/YYYY-MM-DD-<topic>.md`: setup, numbers, graphs, conclusion, next bottleneck.
6. Add the test to a **nightly CI job** against staging (small scale) to catch performance regressions.

Five well-documented load test reports are worth more on a résumé than the whole codebase.
They show you can *measure, reason, and decide*.