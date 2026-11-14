# 05 — Geospatial Design (PostGIS, H3, Redis GEO, OSRM)

> Covers prompt section 7.

---

## 1. Three different geo problems, three different tools

| Problem | Data shape | Write rate | Best tool | Why |
|---|---|---|---|---|
| "Which available drivers are within 3 km?" | Moving points | 3k/s at scale | **Redis GEO** (geohash in a sorted set) or in-memory H3 buckets | O(log N + M) lookups, no MVCC write amplification, data is disposable. |
| "Does B's trip lie along A's route?" | Lines vs. points | Low | **PostGIS** | Real geometry operations: buffers, intersections, linear referencing. |
| "How long does it take to drive X→Y?" | Road graph | Read-only | **OSRM / Valhalla** | Needs a road network; straight-line distance is wrong by 1.3–2× in cities. |

And a fourth, cross-cutting tool: **H3** (Uber's hexagonal grid, open source) for
bucketing: surge zones, matching shards, demand heatmaps, Kafka partition keys.

**Learning plan:** implement nearest-driver in **both** PostGIS and Redis, benchmark them with
Locust at 300 and 3,000 updates/s, and write an ADR with the numbers. That's a real
Principal-level exercise: decide with data, not dogma.

---

## 2. `geography` vs. `geometry`

| | `geography(Point,4326)` | `geometry(Point,4326)` | `geometry(Point, <UTM SRID>)` |
|---|---|---|---|
| Units | Meters (spheroid) | Degrees (meaningless for distance) | Meters (planar) |
| Accuracy | Exact anywhere | Wrong for distance | Exact within one UTM zone |
| Function coverage | Subset | Full | Full |
| Speed | Slower (spheroidal math) | Fast | Fast |

**Decision:**
- **Points** (pickup, dropoff, driver location): `geography`. Distance queries "just work" in meters, and city-scale queries are cheap enough.
- **Routes / analysis**: `geometry(LineString, 4326)` stored, and **`ST_Transform` to a metric
  SRID per city** for buffers and intersections (Hyderabad: EPSG:32644 / UTM 44N;
  Bengaluru: EPSG:32643 / UTM 43N). Put the SRID in a `cities` config table.

**The #1 PostGIS performance bug:** `ST_DWithin(geom_col::geography, ...)`. Casting the
*column* prevents index use. Index the type you query, or create an expression index:
`CREATE INDEX ON t USING gist ((geom_col::geography));`

---

## 3. GiST indexes, briefly but properly

- A GiST index on spatial data is an **R-tree**: each node stores a bounding box covering its children.
- Queries do a two-step process: **(1) index filter on bounding boxes** (`&&`, fast, approximate) → **(2) exact recheck** on the real geometry (slow, precise).
- Functions like `ST_DWithin`, `ST_Intersects`, `ST_Contains` *include* step 1 automatically. `ST_Distance(a,b) < r` does **not**, which means a full table scan. Always use `ST_DWithin` for radius filters.
- **KNN** (`ORDER BY geom <-> point LIMIT k`) walks the R-tree in distance order: true index-assisted nearest neighbor, no radius needed.
- **SP-GiST** (quad-tree/k-d tree) can beat GiST for points-only data with lots of updates. Benchmark it.
- **Partial indexes** (`WHERE availability = 'AVAILABLE'`) shrink the index to the rows the matcher actually searches.
- Index bloat: frequent updates bloat GiST indexes. Monitor with `pgstattuple`; `REINDEX CONCURRENTLY` periodically.

---

## 4. Nearest driver search

### 4.1 PostGIS: radius + KNN

```sql
-- :pickup is a geography point; :radius_m e.g. 3000; :k e.g. 10
SELECT d.driver_id,
       ST_Distance(d.location, :pickup) AS distance_m,
       d.heading_deg
FROM   tracking.driver_locations d
WHERE  d.availability = 'AVAILABLE'
  AND  d.city_code    = :city
  AND  d.received_at  > now() - interval '30 seconds'        -- ignore stale drivers
  AND  ST_DWithin(d.location, :pickup, :radius_m)            -- index filter
ORDER  BY d.location <-> :pickup                             -- KNN ordering via index
LIMIT  :k;
```

Expected plan: `Index Scan using driver_locations_available_gist`. Verify with
`EXPLAIN (ANALYZE, BUFFERS)` and paste the plan into the ADR.

### 4.2 Redis GEO (the production hot path)

```
GEOADD   drivers:avail:HYD  78.4867 17.3850  drv_42
GEOSEARCH drivers:avail:HYD FROMLONLAT 78.4867 17.3850 BYRADIUS 3 km ASC COUNT 20 WITHDIST
```

Staleness is handled with a companion sorted set `drivers:lastseen:HYD` (score = epoch);
a sweeper `ZRANGEBYSCORE ... -inf (now-30)` removes stale members from both sets (doc 10).

### 4.3 Then rank by **road ETA**, not distance

Straight-line nearest ≠ fastest pickup (rivers, one-way streets, flyovers). Take the top
10–20 by distance, call OSRM's **table** service (one many-to-one matrix call, not 20
route calls), and rank by ETA:

```
GET http://osrm:5000/table/v1/driving/{d1};{d2};...;{pickup}?sources=0;1;...&destinations=N
```

This "cheap filter → expensive rank" funnel is the universal pattern in matching, search,
and recommendation systems.

---

## 5. Nearby rider search (for Pool batching)

Find other riders currently waiting for a Pool match near this rider's pickup *and*
heading roughly the same way:

```sql
SELECT r.id, r.pickup, r.dropoff,
       ST_Distance(r.pickup, :pickup)   AS pickup_gap_m,
       ST_Distance(r.dropoff, :dropoff) AS dropoff_gap_m
FROM   rides.rides r
WHERE  r.status   = 'MATCHING'
  AND  r.product  = 'POOL'
  AND  r.city_code = :city
  AND  r.id <> :ride_id
  AND  ST_DWithin(r.pickup, :pickup, 1500)                   -- uses partial GiST
  AND  ST_DWithin(r.dropoff, :dropoff, 3000)                 -- recheck, no index needed (small set)
  -- direction similarity: bearing of (pickup→dropoff) within ±45°
  AND  abs(
         degrees(ST_Azimuth(r.pickup::geometry, r.dropoff::geometry))
       - degrees(ST_Azimuth(:pickup::geometry, :dropoff::geometry))
       ) % 360 BETWEEN 0 AND 45                              -- simplified; wraparound handled in app
LIMIT 50;
```

Simplify as a solo dev: do the bearing check in Python. It's cleaner and handles the
0°/360° wraparound properly. Shown in SQL here so you know it's possible.

---

## 6. Route matching / overlap detection

"Does rider B fit along A's route?" has three increasingly accurate formulations.

### 6.1 Corridor test (fast pre-filter): linear referencing

B is a candidate if B's pickup and drop-off are both within *w* meters of A's remaining
route **and in the right order** along it.

```sql
WITH a AS (
  SELECT ST_Transform(t.planned_route, 32644) AS route_m
  FROM rides.trips t WHERE t.id = :trip_id
), b AS (
  SELECT ST_Transform(:b_pickup::geometry, 32644)  AS p,
         ST_Transform(:b_dropoff::geometry, 32644) AS d
)
SELECT
  ST_Distance(a.route_m, b.p)            AS pickup_offset_m,
  ST_Distance(a.route_m, b.d)            AS dropoff_offset_m,
  ST_LineLocatePoint(a.route_m, b.p)     AS pickup_frac,    -- 0..1 along A's route
  ST_LineLocatePoint(a.route_m, b.d)     AS dropoff_frac
FROM a, b
WHERE ST_DWithin(a.route_m, b.p, 400)
  AND ST_DWithin(a.route_m, b.d, 400)
  AND ST_LineLocatePoint(a.route_m, b.p) < ST_LineLocatePoint(a.route_m, b.d);
```

`ST_LineLocatePoint` is **linear referencing**: it projects a point onto a line and returns its
fractional position. Ordering pickup_frac < dropoff_frac rejects riders going the opposite way
along the same road. That's the bug a naive "buffer intersects" check misses.

### 6.2 Overlap ratio (for scoring and for the "shared distance" in fares)

```sql
SELECT
  ST_Length(
    ST_Intersection(
      ST_Buffer(ST_Transform(a.route, 32644), 50),            -- 50 m corridor around A
      ST_Transform(b.route, 32644)
    )
  ) / NULLIF(ST_Length(ST_Transform(b.route, 32644)), 0)     AS overlap_ratio_of_b
FROM (SELECT :route_a::geometry AS route) a,
     (SELECT :route_b::geometry AS route) b;
```

An overlap ratio > 0.6 is a reasonable heuristic for "strongly shareable". But…

### 6.3 Detour cost (the actual decision criterion)

Geometry overlap is a **heuristic**. What riders feel is **time**. The real test is:

```
detour_A = ETA_A(with B inserted) − ETA_A(solo remaining)
detour_B = ETA_B(shared) − ETA_B(solo)
feasible iff detour_A ≤ budget_A and detour_B ≤ budget_B and capacity holds at every stop
```

Each ETA comes from OSRM. So the pipeline is:

```
H3/Redis bucketing (μs) → PostGIS corridor test (ms) → OSRM detour evaluation (10s of ms)
```

Each stage cuts the candidate set by ~10× so that the expensive stage only sees a handful.

**How Uber does this:** almost entirely in-memory in the dispatch service, sharded by
geography, with routing via their internal ETA service (road graph + ML correction for
traffic). They don't run PostGIS queries in the hot dispatch loop. PostGIS is your
learning tool and your analytics tool. If you shard the matcher later, its in-memory index
is the H3 bucket map.

---

## 7. H3

```python
import h3
cell = h3.latlng_to_cell(17.3850, 78.4867, 9)     # res 9 ≈ 0.1 km² (edge ≈ 174 m)
ring = h3.grid_disk(cell, 3)                       # ~37 cells ≈ 1 km radius neighborhood
```

| Use | Resolution |
|---|---|
| Matching shard / Kafka partition key / "region" | res 4–5 (city district scale) |
| Surge pricing zone | res 7–8 |
| Candidate bucketing ("drivers in my cell + neighbors") | res 8–9 |
| Pickup point snapping / demand heatmap | res 9–10 |

**Why hexagons:** all 6 neighbors are equidistant from the center (squares have 2 distances
for 8 neighbors), which makes k-ring searches and smoothing uniform. Store
`pickup_h3_r9` on rides and use it as a cheap equality filter and GROUP BY key.

---

## 8. Performance considerations

| Issue | Mitigation |
|---|---|
| GiST index write amplification under 3k updates/s | Keep the hot index in Redis; Postgres gets a throttled "last known" upsert (e.g. every 30 s per driver) or none at all. |
| Stale driver positions | Filter `received_at > now() - 30s`; sweep Redis. |
| `ST_Transform` cost on every query | Store a precomputed projected column (`route_m geometry(LineString, 32644)`) for hot paths. |
| Huge polylines | `ST_Simplify(route, 10)` (10 m tolerance) before storing the planning route. Keep full resolution only in history. |
| OSRM latency | Batch with `/table`; cache `(h3_r9_from, h3_r9_to, hour_bucket) → duration` in Redis with a 5-min TTL; run 2+ OSRM replicas. |
| Bounding-box inefficiency for long diagonal routes | A long diagonal LineString's bbox covers a huge area → many false positives. Segment routes into ~1 km pieces (`ST_Segmentize` + `ST_Subdivide`) for indexing. |
| Planner chooses seq scan | `ANALYZE` after bulk loads; check `EXPLAIN (ANALYZE, BUFFERS)`; ensure `work_mem` is adequate for sorts. |