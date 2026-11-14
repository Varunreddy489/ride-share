10-redis.md

\# 10 — Redis Design

\> Covers prompt section 12.

\---

\## 1. Principle: Redis is a cache and a coordination layer, never the system of record

Everything in Redis must be either \*\*reconstructible\*\* (from Postgres or from the next event)
or \*\*ephemeral by nature\*\* (rate-limit counters, locks). If losing Redis would lose a ride,
fare, or payment, the design is wrong.

Test it: kill Redis in staging during a Locust run (doc 15). The system should degrade
(slower matching, no surge, no rate limits) but not lose data or crash.

\---

\## 2. Key catalog

\| Purpose | Key | Type | TTL | Written by | Read by |
\|---|---|---|---|---|---|
\| Available-driver geo index | \`geo:drivers:avail:{city}\` | GEO (sorted set) | none (swept) | Location ingest | Matching, quote ETA |
\| Driver last-seen (staleness) | \`drivers:lastseen:{city}\` | ZSET (score = epoch s) | none (swept) | Location ingest | Sweeper |
\| Driver live state | \`driver:{id}:state\` | HASH {lat, lng, heading, availability, trip_id, ts} | 120 s | Location ingest | Tracking gateway, matching |
\| Open pool trips by cell | \`pool:open:{city}:{h3_r8}\` | SET of trip_id | 60 s, refreshed | Matching | Matching |
\| Trip plan snapshot | \`trip:{id}:plan\` | STRING (msgpack) | 30 min | Ride module (on commit) | Matching |
\| Active ride per rider | \`rider:{id}:active_ride\` | STRING | 6 h | Ride module | API (fast 409 check) |
\| Surge multiplier | \`surge:{city}:{h3_r7}\` | STRING (decimal) | 120 s | Surge job | Pricing |
\| ETA cache | \`eta:{h3_r9_from}:{h3_r9_to}:{hour}\` | STRING (seconds) | 5 min | Routing adapter | Quote, matching |
\| Route cache | \`route:{h3_r10_from}:{h3_r10_to}\` | STRING (polyline+dist+dur) | 10 min | Routing adapter | Quote |
\| Quote cache | \`quote:{id}\` | STRING (json) | until \`expires_at\` | Pricing | Ride request |
\| Matching exclusions | \`match:excl:{ride_id}\` | SET of ride_ids | 10 min | Proposal saga | Matching |
\| Driver offer lock | \`offer:driver:{id}\` | STRING \`SET NX PX 15000\` | 15 s | Dispatch | Dispatch (one offer at a time) |
\| Rate limiting | \`rl:{scope}:{id}:{window}\` | STRING counter / ZSET | window | API middleware | API middleware |
\| WebSocket routing | channel \`ws:user:{id}\` | Pub/Sub | — | Consumers | Tracking gateway |
\| Rate card cache | \`ratecard:{city}:{product}:{cat}\` | STRING | 10 min | Pricing | Pricing |
\| User auth state | \`user:{id}:token_version\` | STRING | 15 min | Identity | Auth dependency |
\| Feature flags | \`flags:{key}\` | HASH | 30 s | Admin | All |

Key naming convention: \`{domain}:{entity}:{id}:{facet}\`. Put the city in hash tags
(\`geo:drivers:avail:{HYD}\`) when moving to Redis Cluster, so multi-key operations for one city
land on one slot.

\---

\## 3. Patterns per use case

\### 3.1 Driver locations (write-heavy, reconstructible)

\`\`\`python
async def ingest(*ping*: Ping, *driver*: DriverState):
    *async* *with* redis.pipeline(*transaction*=False) *as* p:      *# 1 round trip*
        *if* driver.availability == "AVAILABLE":
            p.geoadd(f"geo:drivers:avail:{driver.city}", (ping.lng, ping.lat, driver.id))
        *else*:
            p.zrem(f"geo:drivers:avail:{driver.city}", driver.id)
        p.zadd(f"drivers:lastseen:{driver.city}", {driver.id: ping.recorded_at_epoch})
        p.hset(f"driver:{driver.id}:state", *mapping*=ping.as_state())
        p.expire(f"driver:{driver.id}:state", 120)
        *await* p.execute()
\`\`\`

\*\*Invalidation:\*\* no invalidation; it's \*\*write-through by the event itself\*\*. Staleness is handled by a sweeper every 10 s:

\`\`\`lua
*-- sweep_stale.lua (atomic): remove drivers not seen for 30 s from the available index*
local stale = redis.call('ZRANGEBYSCORE', KEYS[2], '-inf', ARGV[1])
for \_, id in ipairs(stale) do
  redis.call('ZREM', KEYS[1], id)
  redis.call('ZREM', KEYS[2], id)
end
return #stale
\`\`\`

\*\*Availability transitions\*\* (AVAILABLE ↔ ON_TRIP) must update the geo index \*\*in the same
code path\*\* as the Postgres state change. Otherwise the matcher can offer a ride to a driver
who just accepted another one. The \`offer:driver:{id}\` lock (\`SET NX\`) and the
\`one_active_trip_per_driver\` unique index are the safety nets, in that order.

\### 3.2 Active rides / trip plans (read-heavy, Postgres is truth)

\*\*Pattern:\*\* cache-aside on read + \*\*explicit invalidation on write via the outbox relay\*\*:

\`\`\`
write path: tx(update trip, version=8, outbox: trip-stops-changed) → commit
            relay publishes → cache-invalidator consumer → DEL trip:{id}:plan
read path:  GET trip:{id}:plan → miss → SELECT … → SET trip:{id}:plan EX 1800
\`\`\`

Why invalidate from the event and not right after \`commit()\` in the handler? Because the
handler can crash between commit and DEL, leaving stale data for the full TTL. The event
path is retried until it succeeds. (Doing *\*both\** is fine: an immediate best-effort DEL, plus
an event-driven DEL as the guarantee.)

\*\*Stale-read guard:\*\* the matcher reads a trip plan *\*with its version\** and commits with
\`expected_version\`. A stale cache produces a version conflict, never a wrong insertion.
\*\*Optimistic concurrency makes cache staleness safe.\*\* That's the deep reason the version
column exists.

\### 3.3 Surge pricing (computed, time-bucketed)

\- A surge job runs every 30–60 s per city. It counts open requests (demand) and available drivers (supply) per H3 res-7 cell over a sliding window, computes \`multiplier = f(demand/supply)\`, \*\*smooths\*\* it (EWMA, max change per step), and writes \`SET surge:{city}:{cell} 1.4 EX 120\`.
\- \*\*Invalidation:\*\* TTL-based. If the job dies, keys expire → pricing reads a miss → \*\*default 1.0\*\*. Fail *\*open\** on surge, so riders are never overcharged when the system is broken.
\- The quote stores the surge it used, so a later change never alters a quoted price.

\### 3.4 Matching candidates (derived, short-lived)

\- \`pool:open:{city}:{h3_r8}\` is a SET of open pool trips, maintained by the matcher from \`ride-matched\` and location events. TTL 60 s, refreshed continuously, so a missed removal ages out on its own.
\- \*\*Self-healing over strict invalidation\*\*: for derived, high-churn indexes, short TTLs plus continuous refresh beat precise invalidation logic.

\### 3.5 Rate limiting

Sliding-window log or GCRA (\`redis-cell\`), or the simple fixed window:

\`\`\`lua
*-- fixed window: KEYS[1] = rl:login:{ip}:{minute}; ARGV[1] = limit; ARGV[2] = window_s*
local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('EXPIRE', KEYS[1], ARGV[2]) end
return n <= tonumber(ARGV[1]) and 1 or 0
\`\`\`

Limits: \`/auth/login\` 5/min per IP+account; \`/fare-quotes\` 30/min per user; \`/rides\` 5/min per
user; \`/drivers/me/locations\` 30/min per driver. \*\*Fail open\*\* if Redis is down (log and count
it), except on \`/auth/\*\`, where you fall back to a coarse in-process limiter.

\### 3.6 ETA/route cache

Key on H3 cells (not raw coordinates). Raw coordinates almost never repeat, so the hit rate
would be \~0%. Snapping to res-9 (\~170 m) gives high hit rates with a bounded error that's
acceptable for estimates. Never use the cached ETA for *\*billing\**, only for ranking and quotes.

\---

\## 4. Cache invalidation strategy summary

\| Data | Strategy | Staleness tolerated | Failure mode if Redis is down |
\|---|---|---|---|
\| Driver locations | Write-through by event + sweeper | \~5 s | Fall back to PostGIS \`driver_locations\` KNN (slower) |
\| Trip plans | Cache-aside + event-driven DEL + version check | 0 (guarded by version) | Read from Postgres |
\| Active ride per rider | Write-through + DB unique index | 0 (DB is the guard) | Rely on the DB constraint |
\| Surge | TTL only | 2 min | Default 1.0 |
\| Matching candidates | TTL + continuous refresh | 60 s | Matcher rebuilds from Postgres query (degraded) |
\| ETA / route | TTL only | 5–10 min | Call OSRM directly (higher latency) |
\| Quotes | TTL = quote expiry | 0 | Read from Postgres |
\| Rate cards / flags | TTL + pub/sub "flush" message on admin change | 30 s – 10 min | Read from Postgres |
\| Token version | TTL 15 min + DEL on logout-all | ≤ access-token lifetime | Skip the check (access tokens are short-lived anyway) |

\*\*Thundering herd / cache stampede:\*\* for hot keys (rate cards, surge per busy cell), use
\*\*single-flight\*\* (\`SET lock:{key} NX PX 2000\`; losers wait briefly and re-read) or
\*\*probabilistic early expiration\*\* (XFetch). Add \*\*TTL jitter\*\* (±10%) so keys created
together don't expire together.

\---

\## 5. Deployment and operations

\| Concern | Decision |
\|---|---|
\| Topology | Stage 1: single instance. Stage 2: primary + replica + Sentinel (or Bitnami/Valkey Helm chart). Stage 3: Redis Cluster (shard by city hash tag). |
\| Persistence | AOF \`everysec\` on (faster recovery of geo index); not relied on for correctness. |
\| Memory policy | \`maxmemory-policy volatile-lru\` (evict only keys with TTL; geo index has none and must not be evicted, so size memory for it). |
\| Memory sizing | \~12k drivers × \~200 B ≈ 2.4 MB for geo + state. ETA cache dominates; cap it with TTLs. |
\| Client | \`redis.asyncio\` with a connection pool; timeouts (\`socket_timeout=0.2\`) so a slow Redis can't stall the API; a circuit breaker around it (doc 16). |
\| Monitoring | \`redis_exporter\`: memory, evictions, hit ratio (\`keyspace_hits/misses\`), latency, connected clients, slowlog. |
\| Valkey | The Linux Foundation fork after Redis's 2024 license change. API-compatible. Fine for this project either way. |