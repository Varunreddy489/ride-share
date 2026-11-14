# 01 — Product Requirements, Functional & Non-Functional Requirements

> Covers prompt sections 1–3. This is the "architecture review" of the idea itself:
> before designing the system, we challenge the product.

---

## 1. Product Requirement Refinement (Critical Review)

### 1.1 The biggest issue: the consent model

The proposed flow is:


> Rider 1 is told "Ride with James and save ₹95" → **both** riders accept → shared ride is created.

This is the most important product decision in the system, and as written it is the
wrong default for production. Here's why:

| Problem | Why it hurts |
|---|---|
| **Two-party synchronous consent** | Match success = P(A accepts) × P(B accepts) × P(neither cancels while waiting). At 70% each you lose ~50% of viable matches. |
| **Latency** | You can't dispatch a driver until both answer. The "< 2 s matching" NFR becomes "< 2 s + human think time (5–30 s)". |
| **Driver idle / supply waste** | Either you hold a driver while people decide, or you dispatch and then re-route. |
| **Gaming** | Riders learn they can decline to fish for a better offer. |
| **Privacy** | Showing "James" before the ride starts leaks PII to a stranger. |

**What Uber Pool / Lyft Shared actually did:** the rider opts in *at request time* and
gets a **guaranteed upfront discounted price**. Matching happens silently in the background
during a short window. Co-riders are revealed (first name only) only after the match
locks. There is no per-match consent. The platform takes on the risk: if no match is found,
the rider still pays the discounted price and the platform eats the margin.

**Recommendation (decision):**

1. **Default mode — "Opt-in Pool":** the rider chooses Share at request time, sees a
   guaranteed upfront price (`pool_price ≤ solo_price × (1 − d)`), and is matched
   automatically. This is the production path.
2. **Learning mode — "Proposal Pool"** (behind a feature flag): the flow you described,
   with a strict TTL (e.g. 20 s), auto-decline on timeout, and a fallback to solo or
   auto-pool. **Build this too.** It's the best learning exercise in the project: it
   forces you to build a distributed state machine with timeouts, sagas, and
   compensating actions.

Keep both modes. The feature flag itself (per city, per % of users) is also worth learning.

### 1.2 Missing requirements

| Area | Missing requirement |
|---|---|
| **Routing** | A road-network routing engine is required. Route overlap, ETAs and detours **cannot** be computed from straight-line geometry. Use **OSRM** or **Valhalla** self-hosted with an OpenStreetMap extract (e.g. a southern-India extract from Geofabrik). |
| **Upfront pricing** | Need to define whether price is **upfront** (fixed at request) or **metered** (computed at the end). Production uses upfront for riders and metered for driver pay. These are two different engines. |
| **Driver pay model** | Driver earnings are **decoupled** from rider fares. Pool trips must pay drivers for actual time+distance, not the sum of the discounted fares. |
| **Capacity** | Max seats per vehicle, max riders per pool (start with 2, design for N ≤ 3), and party size per request (1–2 seats). |
| **Detour bounds** | Max added time per rider (e.g. +8 min or +40% of solo ETA, whichever is smaller). This is the real quality constraint, not "route overlap". |
| **Cancellation policy** | Who pays when one pool rider cancels after the driver detoured? Grace windows, fees, and re-pricing for the remaining rider. |
| **No-show** | Wait timer at pickup (Pool: 1–2 min, stricter than solo) and then auto-cancel with a fee. |
| **Walking pickups** | Uber's "Express Pool" moved riders to a corner pickup point to reduce detours. Optional V2. |
| **Geofencing / service areas** | Cities, airports (queues), restricted zones. |
| **Multi-currency / tax** | GST on rides in India, invoices, rounding rules. Store money in **integer minor units (paise)**, never floats. |
| **Payments** | Cash vs. card vs. UPI; wallet; refunds; chargebacks; payment failure after trip. |
| **Ratings & safety** | Ratings, SOS button, trip sharing with contacts, women-only pool preference, driver background-check status. |
| **Support** | Lost item, fare disputes, and an admin "re-price trip" tool. |
| **Audit** | Every fare must be reproducible: store the pricing inputs (rate card version, surge multiplier, route snapshot) with the fare. |
| **Notifications** | Push (FCM/APNs), SMS fallback, in-app WebSocket. |
| **Data retention / DPDP Act** | India's Digital Personal Data Protection Act 2023 applies: location history is personal data. Define retention (e.g. raw GPS 90 days) and erasure. |

### 1.3 Edge cases (design must handle these explicitly)

**Matching and dispatch**
- Rider B is matched into Rider A's trip *after* A is already in the car. That's "en-route insertion", the normal case for Pool.
- Two matchers try to insert different riders into the same trip at the same time (race → double-booking of seats). Needs optimistic locking / version column on the trip.
- A driver accepts and then goes offline (app crash, tunnel). Needs heartbeat timeout → re-dispatch.
- A driver's GPS jumps 2 km (multipath in dense cities). Needs map matching / outlier rejection.
- Rider requests while their own previous ride is still active. Enforce one active ride per rider.
- The pickup point is on the wrong side of a divided road (U-turn adds 6 min). The routing engine handles this; straight-line distance doesn't.
- Identical origin/destination, or destination outside the service area.

**Shared ride**
- Rider A cancels after B is picked up. B's fare must be **re-priced down or held** (never up) and the driver re-routed.
- Rider B's drop-off makes A's trip exceed the detour guarantee because of traffic. Do you compensate? (Production: a credit.)
- Destination C is "the same" for both riders, but C1 and C2 are 600 m apart. You need a drop-off ordering policy.
- Party size 2 + party size 2 in a 4-seat car: legal, but no room for a third.
- Pool request at 2 AM with low density: the match probability is near 0, so maybe don't offer Pool at all (dynamic offering).

**Payments**
- Payment authorization succeeds, the trip completes, then capture fails.
- Duplicate "complete trip" taps from a flaky driver network. Needs idempotency keys.
- Surge changes between estimate and request. You need a **quote with an expiry** (quote_id, valid 2–5 min).

### 1.4 Business and product risks

| Risk | Impact | Mitigation |
|---|---|---|
| Pool unit economics | Discounted rider fare + full driver pay = negative margin if match rate < X% | Track **match rate × average discount** per city; offer Pool only where density supports it. |
| Cannibalization | Solo riders switch to Pool and revenue drops | Price the discount to the expected match probability; A/B test. |
| Rider experience | Long detours → churn | Hard detour caps, ETA guarantees, credits. |
| Driver experience | Pool trips are more stops for similar pay | Per-pickup bonus in driver pay. |
| Safety | Strangers sharing a car at night | Reveal first name only, rating threshold for Pool, gender preference option, SOS. |
| Regulatory | Some cities restrict pooling or require specific licensing | Per-city feature flags. |

### 1.5 Abuse scenarios

| Abuse | Detection / prevention |
|---|---|
| **Fake Pool requests to get discount, then ride solo** | That's by design (upfront price). Limit it with dynamic Pool offering. |
| **Collusion**: two accounts request Pool for the same route to get both discounts and a guaranteed match | Device fingerprinting, same payment instrument, same device id, graph analysis. |
| **GPS spoofing by drivers** to inflate distance | Server-side route recomputation; pay on *planned route* ± tolerance; detect impossible speeds. |
| **Driver cancels after pickup** to re-match a better fare | Cancellation rate monitoring and penalties. |
| **Promo / referral abuse** | Multi-account detection (phone, device, payment). |
| **Proposal fishing** (decline until a better offer comes) | Proposal mode: rate-limit declines and degrade the offers. |
| **API scraping of surge / driver positions** | Rate limiting; never expose exact driver ids or positions before match (fuzz to H3 cell). |
| **Credential stuffing** | Rate limiting on /login, OTP, breached-password checks. |

### 1.6 Revenue implications

```
Platform contribution per trip = Σ rider_fares − driver_payout − payment_fees − promos − insurance
```

For Pool:

```
Solo:             rider pays 300; driver gets 225 → platform 75 (25%)
Pool (matched):   A pays 225, B pays 150 = 375; driver gets 280 (longer trip) → platform 95
Pool (unmatched): A pays 225; driver gets 225 → platform 0
```

So Pool is **profitable only when matched**. The key business metric is
**match rate**, and the system must surface it in real time per city/H3 cell. That's why
the observability doc treats `match_success_rate` as a business SLI.

### 1.7 Suggested improvements

1. Upfront pricing with a `quote_id` (TTL) → removes "price changed" disputes and makes payments idempotent.
2. Batch matching windows (2–10 s) instead of greedy first-come matching. Higher match quality (this is what Uber does).
3. Dynamic Pool offering: only show Pool when P(match) is above a threshold for that H3 cell and time of day.
4. Detour guarantees as first-class constraints in the matcher.
5. Money as integers, fares as immutable, versioned documents.
6. "Wait & Save": the rider accepts a longer pickup window for a bigger discount, giving the matcher more time to batch.

---

## 2. Functional Requirements

Priority: **P0** = MVP, **P1** = V1, **P2** = later.

### 2.1 Rider

| ID | Requirement | Pri |
|---|---|---|
| R-1 | Register with phone + OTP (email/password acceptable for learning) | P0 |
| R-2 | Login; receive access + refresh tokens; logout; logout all devices | P0 |
| R-3 | Manage profile, saved places, payment methods | P1 |
| R-4 | Get a **fare quote** for origin → destination for each product (Solo, Pool) with ETA; quote has `quote_id` and expiry | P0 |
| R-5 | Request a ride using a `quote_id` (idempotent with `Idempotency-Key`) | P0 |
| R-6 | Choose **Pool** mode with seat count (1–2) | P0 |
| R-7 | (Proposal mode) Receive a share proposal with co-rider first name, savings, and added ETA | P1 |
| R-8 | (Proposal mode) Accept / decline proposal within TTL | P1 |
| R-9 | Cancel ride (fee rules depend on state and time) | P0 |
| R-10 | Live tracking of driver location and ETA via WebSocket | P0 |
| R-11 | See the co-rider's pickup/drop-off sequence (not their exact addresses) | P1 |
| R-12 | Trip receipt with fare breakdown | P0 |
| R-13 | Trip history and payment history (paginated) | P0 |
| R-14 | Rate driver; report issue | P1 |
| R-15 | SOS / share trip status | P2 |

### 2.2 Driver

| ID | Requirement | Pri |
|---|---|---|
| D-1 | Register, upload documents, register vehicle (admin approval) | P0 |
| D-2 | Go online / offline (only if approved and the vehicle is active) | P0 |
| D-3 | Send location updates every 4 s while online (batched allowed) | P0 |
| D-4 | Receive ride offers (with timeout, e.g. 15 s) and accept/decline | P0 |
| D-5 | Receive Pool insertions (new pickup added to an active trip) | P0 |
| D-6 | Navigate an ordered **stop list** (pickup A, pickup B, drop B, drop A) | P0 |
| D-7 | Arrive at pickup, start the rider's leg (per rider, not per trip), complete drop-off | P0 |
| D-8 | Mark no-show after wait timer | P1 |
| D-9 | See earnings per trip and per day | P1 |
| D-10 | Rate riders | P2 |

### 2.3 Admin / Ops

| ID | Requirement | Pri |
|---|---|---|
| A-1 | Search/view/suspend riders and drivers | P0 |
| A-2 | Approve drivers and vehicles | P0 |
| A-3 | Live map of active rides and online drivers per city | P1 |
| A-4 | Analytics: rides/hour, match rate, average detour, cancellation rate, revenue | P1 |
| A-5 | Manage rate cards (versioned) and surge overrides | P1 |
| A-6 | Feature flags (Pool on/off per city, proposal mode %) | P1 |
| A-7 | Refund / re-price trip with an audit trail | P1 |
| A-8 | View the audit log of all admin actions | P1 |

---

## 3. Non-Functional Requirements

### 3.1 Targets

| NFR | Target | Notes |
|---|---|---|
| Availability (ride request path) | **99.9%** monthly (43.8 min of error budget) | Read paths (history) can be 99.5%. |
| API latency | p99 < 200 ms, p50 < 50 ms for sync APIs | Excludes WebSocket streams and matching. |
| Match latency | p95 < 2 s from `ride-requested` to `ride-matched` for Solo | Pool: matching *window* is a product parameter (e.g. ≤ 10 s); measure the algorithm separately (< 500 ms per batch). |
| Location ingest | p99 < 100 ms ack; ≤ 5 s staleness in the driver index | |
| Durability | Zero loss of accepted rides, fares, payments | RPO = 0 for the payments DB (sync replica); RPO ≤ 5 min for analytics. |
| RTO | ≤ 30 min for region failure (learning: document it; don't build multi-region) | |
| Consistency | Strong for seat assignment and payments; eventual (seconds) for locations, analytics | |
| Security | OWASP ASVS L2 | |

### 3.2 Back-of-envelope capacity

Assumptions: "N riders" = **registered** users; DAU = 30%; 1 ride per active rider per
day; peak hour = 15% of daily rides; driver:rider DAU ratio = 1:10; 40% of drivers online at
peak; location update every 4 s; 30% of rides are Pool.

| Metric | 10k riders | 100k riders | 1M riders |
|---|---|---|---|
| Rides/day | 3,000 | 30,000 | 300,000 |
| Peak rides/s | 0.13 | 1.25 | **12.5** |
| Online drivers at peak | 120 | 1,200 | 12,000 |
| Location updates/s | 30 | 300 | **3,000** |
| Location rows/day (if all stored) | ~1M | ~10M | **~100M** |
| Concurrent WebSockets (peak) | ~300 | ~3k | ~30k |
| API RPS (polling, quotes, etc. ≈ 50× rides) | ~7 | ~65 | ~650 |

**Takeaway:** the request path is *small* even at 1M users. A single well-tuned Postgres
handles 12 rides/s easily. The real scaling pressure comes from:

1. **Location ingestion** (write-heavy, high-frequency, mostly disposable data).
2. **WebSocket fan-out** (stateful connections).
3. **Matching compute** (combinatorial, per-city hot spots).
4. **Location history storage growth** (100M rows/day → partitioning or tiering).

Design the system so these four scale **independently** of the CRUD path. That's the
reason for the event-driven core and the separate tracking/matching components.

### 3.3 Scaling plan per stage

**Stage 1 — 10k riders: "one box is fine"**
- Modular monolith (1–2 replicas), Postgres+PostGIS (single primary), Redis, single-broker Kafka (KRaft).
- Driver locations: Redis GEO for the hot index plus Postgres for "last known" position.
- Learning focus: correctness, domain model, tests, observability baked in from day one.

**Stage 2 — 100k riders: "split the hot paths"**
- Monolith at 3+ replicas behind HPA; **separate deployments of the same codebase** for `api`, `matching-worker`, `tracking-gateway` (WebSockets), and `outbox-relay`. Same image, different entrypoint. This is the cheapest "microservice" you can build.
- Postgres: add a read replica for history/admin; PgBouncer (transaction pooling); partition `driver_location_history` by day.
- Kafka: 3 brokers, replication factor 3, `min.insync.replicas=2`.
- Redis: primary + replica with Sentinel (or a managed service).

**Stage 3 — 1M riders: "partition by geography"**
- Extract Matching, Tracking, and Payments as true services (own data store, own deploy cadence).
- **Shard matching by city / H3 resolution-4 region**: each matcher instance owns a set of regions (Kafka partition key = region). That gives you natural horizontal scaling and data locality.
- Location history → TimescaleDB hypertable, or Kafka → object storage (Parquet) for analytics. Postgres keeps only the latest position.
- Redis Cluster for geo-index sharded by city.
- WebSocket gateway scaled horizontally, with Redis pub/sub or Kafka for fan-out.
- Multi-AZ everything.

**What Uber does beyond this (for context, don't build it):** per-city sharded
dispatch, consistent-hash rings for state ownership (Ringpop), H3 everywhere,
Schemaless/Docstore on MySQL, Cadence (now Temporal) for workflows, multi-region
active-active with geo-partitioned ownership.