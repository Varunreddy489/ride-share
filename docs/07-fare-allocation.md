# 07 — Fare Allocation Engine

> Covers prompt section 9. Five algorithms, each with formula, model, pros and cons, all
> worked on the **same example** so they can be compared directly.

---

## 0. Framing: two prices, not one

Production ride-sharing has **two independent money flows**:

```
Rider price  (what each rider pays)    → set by the PRICING engine (upfront, quoted)
Driver pay   (what the driver earns)   → set by the DRIVER PAY engine (from actual time+distance)
Platform take = Σ rider prices − driver pay − fees
```

The prompt's "Total Fare ₹450, split it" is the **cost-allocation** view. That's useful and
appears in Algorithms 1–4. But Uber stopped doing it for riders around 2016 and moved to
upfront pricing (Algorithm 5). Understanding *why* is the main lesson of this doc.

### Fairness properties to evaluate every algorithm against

| Property | Meaning |
|---|---|
| **Budget balance** | Σ rider shares = trip cost (or, for upfront: revenue ≥ cost on average) |
| **Individual rationality (IR)** | No rider pays more than their solo price. *Non-negotiable product rule.* |
| **Detour neutrality** | A rider who suffers a detour shouldn't pay more because of it |
| **Symmetry** | Riders with identical trips pay identically |
| **Monotonicity** | Riding further never makes you pay less |
| **Predictability** | The rider knows the price before booking |
| **Computability** | Cheap to compute and to explain on a receipt |
| **Manipulation resistance** | Riders can't game it (e.g. by fake drop-offs) |

---

## 1. The worked example

**Given:** Rider A travels 12 km, Rider B travels 7 km, 5 km is shared, trip cost to allocate = **₹450**.

Derived segment structure (vehicle travels 12 + 7 − 5 = **14 km**):

```
  pickup A ──── 7 km (A alone) ──── pickup B ──── 5 km (A+B) ──── drop A ──── 2 km (B alone) ──── drop B
  segment S1: 7 km, 16 min, {A}      segment S2: 5 km, 12 min, {A,B}      segment S3: 2 km, 6 min, {B}
```

| | Distance | In-vehicle time |
|---|---|---|
| A | 7 + 5 = 12 km | 16 + 12 = 28 min |
| B | 5 + 2 = 7 km | 12 + 6 = 18 min |

**Solo prices** (what each would have paid alone; needed for IR and savings). Rate card
for the example: `₹50 base + ₹22/km + ₹1/min`, solo routes 12 km/26 min and 7 km/15 min:

- Solo A = 50 + 264 + 26 = **₹340**
- Solo B = 50 + 154 + 15 = **₹219**
- Σ solo = ₹559 → pooling saves ₹109 in total vs. two separate cars.

All amounts below are computed in **paise** with largest-remainder rounding, so shares
always sum *exactly* to the total.

---

## 2. Algorithm 1: Distance-weighted split

**Formula:**

```
share_i = Total × d_i / Σ_j d_j
```

**Example:**

```
A = 450 × 12 / 19 = ₹284.21
B = 450 ×  7 / 19 = ₹165.79       (Σ = 450.00 ✓)
Savings: A = 340 − 284.21 = ₹55.79 (16%)   B = 219 − 165.79 = ₹53.21 (24%)
```

| Pros | Cons |
|---|---|
| Trivial to compute and explain | Ignores time: 7 km in traffic ≠ 7 km on a highway |
| Budget-balanced | Ignores the base-fare structure (short riders benefit less from sharing the base) |
| Monotone in distance | Not IR-guaranteed: a long rider paired with a very short rider can exceed solo price if trip cost includes a big detour |
| | Not detour-neutral: if serving B forces A on a 3 km detour, A's d_i grows and **A pays more** for B's convenience. That's the fatal flaw. |

**Fix for the fatal flaw:** use each rider's **solo-route distance** (from the quote) as d_i,
not the realized in-car distance. That alone makes it detour-neutral.

---

## 3. Algorithm 2: Distance + time weighted split

**Formula** (α = distance weight, e.g. 0.6):

```
w_i     = α · d_i / Σd + (1 − α) · t_i / Σt
share_i = Total × w_i
```

**Example** (α = 0.6; d: 12, 7; t: 28, 18):

```
w_A = 0.6 × 12/19 + 0.4 × 28/46 = 0.37895 + 0.24348 = 0.62243
w_B = 0.6 ×  7/19 + 0.4 × 18/46 = 0.22105 + 0.15652 = 0.37757
A = 450 × 0.62243 = ₹280.09
B = 450 × 0.37757 = ₹169.91       (Σ = 450.00 ✓)
```

| Pros | Cons |
|---|---|
| Mirrors how metered fares work (per-km + per-min) | Still not detour-neutral (both d and t grow with detour) unless solo values are used |
| Captures traffic | α is arbitrary. Derive it from the rate card instead: α = (per_km·Σd)/(per_km·Σd + per_min·Σt) |
| Simple | Still ignores *who caused* the cost and *who shared* it |

---

## 4. Algorithm 3: Segment-based shared cost allocation

**Model:** the trip is a sequence of segments. Each segment's cost is split **equally among the
riders onboard during that segment** (weighted by seats if party sizes differ).

```
cost(S_k)  = Total × len(S_k) / Σ len(S)          (or a per-segment km+min cost)
share_i    = Σ_{k : i ∈ onboard(S_k)}  cost(S_k) · seats_i / Σ_{j ∈ onboard(S_k)} seats_j
```

**Example** (distance-based segment cost, ₹450 / 14 km = ₹32.142857/km):

```
S1 (7 km, {A})   = ₹225.00  → A: 225.00
S2 (5 km, {A,B}) = ₹160.71  → A: 80.36, B: 80.36   (½ each)
S3 (2 km, {B})   = ₹ 64.29  → B: 64.29
A = 225.00 + 80.36 = ₹305.36
B =  64.29 + 80.36 = ₹144.64      (Σ = 450.00 ✓)
Savings: A = ₹34.64 (10%)   B = ₹74.36 (34%)
```

| Pros | Cons |
|---|---|
| Intuitive "you pay for the road you used, shared roads are split" | **Unequal benefit**: B saves 34%, A saves 10%. A, the rider who got detoured to pick B up, benefits least. Feels unfair. |
| Generalizes naturally to N riders and to the stored `trip_segments` table | Depends on the realized route → price unknown until the end → **not upfront** |
| Uses real data: auditable | Deadhead (driving to the first pickup) and detour segments need explicit attribution rules |
| | Manipulable: a rider can shift cost to others by choosing a drop-off that lengthens shared segments |

This is the model the `trip_segments` table supports directly, and it's a great one to
implement first because it exercises the data model end-to-end.

---

## 5. Algorithm 4: Cooperative game theory (Shapley value / equal savings)

**Model:** treat riders as players in a cost game. `c(S)` = cost of serving coalition S alone
(optimal route). Each rider pays their **Shapley value**: their average marginal cost over
all orderings in which the coalition could have formed.

```
φ_i = Σ_{S ⊆ N\{i}}  |S|! (|N|−|S|−1)! / |N|!  · [ c(S ∪ {i}) − c(S) ]
```

For **two riders** this reduces to splitting the *savings* equally:

```
φ_A = c(A) − ½·[c(A) + c(B) − c(AB)]
φ_B = c(B) − ½·[c(A) + c(B) − c(AB)]
```

To use the standalone costs on the same scale as the ₹450 trip cost, compute them with the
same cost basis (₹32.142857/km over each rider's solo distance): `c(A) = 12 km → ₹385.71`,
`c(B) = 7 km → ₹225.00`, `c(AB) = ₹450`.

**Example:**

```
Total savings = 385.71 + 225.00 − 450 = ₹160.71
φ_A = 385.71 − 80.36 = ₹305.36
φ_B = 225.00 − 80.36 = ₹144.64       (Σ = 450.00 ✓)
```

Notice that in *this* example the Shapley value equals Algorithm 3 exactly. That's not a
coincidence: when the shared route is a strict subset of both solo routes (no detour), the
segment model *is* the Shapley allocation. The two diverge when there is a **detour**. Add a
3 km detour to pick up B (trip = 17 km, cost rises to ₹546.43 at the same per-km rate):

```
Segment model:  the detour km are in S1 ({A} alone) → A pays for the detour.   ✗ unfair
Shapley:        savings = 385.71 + 225.00 − 546.43 = ₹64.28 → each saves ₹32.14
                φ_A = ₹353.57, φ_B = ₹192.86. The detour cost is shared because it's
                a cost of the *coalition*, not of A.                              ✓
```

Variant, **proportional-to-standalone**: `share_i = c(AB) · c(i) / Σ c(j)` → A = ₹284.21,
B = ₹165.79. Everyone saves the same *percentage* (26.3%).

| Pros | Cons |
|---|---|
| Axiomatically fair: the unique allocation that's efficient, symmetric, additive, and gives zero to a "null player" | Needs c(S) for **all 2ᴺ subsets** → 2ᴺ routing calls (fine for N ≤ 3: 8 calls) |
| Detour-neutral, in the coalition sense | Hard to explain on a receipt ("your Shapley value is…") |
| Equal savings for 2 riders, easy to message ("you each save ₹80") | Ex-post: still not upfront |
| Defensible in disputes and to regulators | Not always in the *core* for N ≥ 3 (a sub-coalition could prefer to leave), which is rarely a practical issue |

---

## 6. Algorithm 5: Production approach (upfront pricing + decoupled driver pay)

This is how Uber Pool, Lyft Shared, and Via actually price (conceptually, from public
statements and observable product behavior).

**Rider side: price is fixed at request time, independent of who you end up sharing with:**

```
pool_price_i = max( minimum_fare,
                    solo_price_i × surge_i × (1 − discount_i) + booking_fee )

discount_i   = clamp( d_base + d_match · P(match | cell, time) − d_risk · E[detour_i], d_min, d_max )
```

- `P(match)` is the predicted probability of finding a co-rider for this request, from the
  density of open pool trips and waiting requests in the H3 cell (start with a lookup table
  by cell × hour; later an ML model). A higher probability means the platform can afford a
  deeper discount, because expected cost is lower.
- The **guarantee:** the rider pays the quoted price whether matched or not. The platform carries the risk.

**Driver side:** pay for what was actually driven, plus a per-additional-pickup bonus:

```
driver_pay = (per_km_d × actual_km + per_min_d × actual_min) × surge_d + pool_pickup_bonus × (riders − 1)
```

**Example** (same trip; driver rates ₹14/km, ₹1.20/min, pickup bonus ₹20; solo prices ₹340 and ₹219; surge 1.0):

```
A requested when the cell was sparse:  P(match) = 0.4 → discount = 18% → A pays 340 × 0.82 = ₹278.80
B requested into an open pool trip:    P(match) ≈ 0.95 → discount = 30% → B pays 219 × 0.70 = ₹153.30
Rider revenue                          = ₹432.10
Driver pay = 14 × 14 + 1.20 × 34 + 20 = 196 + 40.80 + 20 = ₹256.80
Platform contribution                  = ₹175.30 (before payment fees and tax)

If A had NOT been matched:  A still pays ₹278.80; driver pay for 12 km / 26 min
                            = 168 + 31.20 = ₹199.20 → platform ₹79.60.
```

| Pros | Cons |
|---|---|
| **Predictable**: price known before booking → fewer disputes, higher conversion | Not "fair" in the cost-allocation sense: two riders in the same car can pay very different discounts |
| Matching becomes invisible to riders → no consent loop → higher match rate | Platform takes on match risk (needs good P(match) estimates) |
| Decouples marketplace levers (discount, driver pay, take rate) | Needs a prediction model and calibration, and constant A/B testing |
| Idempotent and auditable: price is a stored quote | Regulatory scrutiny of upfront pricing transparency in some markets |
| Lets surge be per-rider (each rider's own request-time surge) | |

---

## 7. Comparison

| | Budget-balanced | IR (≤ solo) | Detour-neutral | Upfront | Compute | Explainable |
|---|---|---|---|---|---|---|
| 1. Distance-weighted | ✓ | ✗ (risk) | ✗ (✓ with solo distances) | ✗ | O(N) | ★★★ |
| 2. Distance + time | ✓ | ✗ (risk) | ✗ (✓ with solo values) | ✗ | O(N) | ★★★ |
| 3. Segment-based | ✓ | ✗ (risk) | ✗ | ✗ | O(segments) | ★★ |
| 4. Shapley | ✓ | ✓ (with optimal c(S)) | ✓ | ✗ | O(2ᴺ) routing | ★ |
| 5. Upfront + decoupled | Ex-ante, on average | ✓ by construction | ✓ | ✓ | O(1) + model | ★★★ |

### Recommendation

- **Rider price:** Algorithm 5 (upfront). Use `P(match)` from a lookup table at first.
- **Reconciliation cap (hybrid):** after the trip, compute the Shapley allocation (Alg. 4) over
  the realized trip. If a rider's Shapley share × (1 + margin) < their upfront price because the
  match went unusually well, you *may* issue a credit. Never charge more than the quote. This
  gives you the predictability of 5 with a fairness backstop from 4.
- **Driver pay:** decoupled, from actual segments.
- **Implement all five** behind a `FareAllocationStrategy` interface and run them in **shadow
  mode** on every completed trip, storing results in `fares.algorithm_inputs`. Then build a
  Grafana panel comparing them. That's how real pricing teams evaluate changes.

---

## 8. Full receipt: surge, platform fee, tax

Line items for Rider A under Algorithm 5 (surge 1.2× at A's request time, GST 5%):

| Seq | Item | Amount |
|---|---|---|
| 1 | Base fare | ₹50.00 |
| 2 | Distance (12 km × ₹22) | ₹264.00 |
| 3 | Time (26 min × ₹1) | ₹26.00 |
| 4 | Surge (0.2 × ₹340.00) | ₹68.00 |
| 5 | Pool discount (−18% of ₹408.00) | −₹73.44 |
| 6 | Booking fee | ₹15.00 |
| | **Subtotal** | **₹349.56** |
| 7 | GST 5% | ₹17.48 |
| 8 | Rounding (to nearest ₹1) | −₹0.04 |
| | **Total** | **₹367.00** |

Rules encoded here:
- **Surge applies to the ride component, not to fees or tax.**
- **Booking/platform fee is per rider, never split.** It covers per-rider costs (insurance, support, payments).
- **Discounts apply before fees.**
- **Tax applies last**, on the subtotal. Rounding is its own explicit line item, so Σ line items == total, always.

---

## 9. Implementation sketch

```python
class FareAllocationStrategy(Protocol):
    name: str
    def allocate(self, trip: TripCostInput) -> dict[RideId, Money]: ...

@dataclass(frozen=True)
class TripCostInput:
    total_cost: Money
    segments: tuple[Segment, ...]        # distance_m, duration_s, onboard: frozenset[RideId], seats
    solo: Mapping[RideId, SoloRoute]     # from quotes: distance, duration, price
    coalition_cost: Callable[[frozenset[RideId]], Money]   # for Shapley; cached routing

class ShapleyAllocation:
    name = "shapley_v1"
    def allocate(self, trip):
        riders = list(trip.solo)
        n = len(riders)
        phi = defaultdict(Decimal)
        for i in riders:
            others = [r for r in riders if r != i]
            for k in range(n):
                for S in combinations(others, k):
                    w = Decimal(factorial(k) * factorial(n - k - 1)) / factorial(n)
                    S = frozenset(S)
                    phi[i] += w * (trip.coalition_cost(S | {i}).amount_minor
                                   - trip.coalition_cost(S).amount_minor)
        return dict(zip(riders, trip.total_cost.allocate([phi[r] for r in riders])))
```

**Property-based tests (Hypothesis)** to write for *every* strategy:
- `sum(allocation.values()) == total` (exactly, in paise)
- `all(a >= 0)`
- Symmetry: identical riders → identical shares (± 1 paisa)
- IR, for strategies that claim it: `share_i <= solo_price_i`
- Determinism: the same input gives the same output (required for audit replay)