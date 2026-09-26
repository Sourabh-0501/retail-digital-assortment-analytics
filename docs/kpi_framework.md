# KPI Framework – Digital Assortment Analytics

**Purpose:** one agreed definition for every metric used in the analysis, dashboards and A/B readouts, so every number means the same thing everywhere.
**Audience:** Product Manager (assortment), Merchandising, Insights / Analytics.
**Period:** eCommerce Oct–Nov 2019 · Instacart (no calendar dates) · A/B test Jan 2–24, 2017.
**Status:** v1.0 – baselines marked *TBD* are filled in during the analysis phase.

---

## 1. Measurement conventions (apply to every KPI)

| Rule | Definition |
|---|---|
| **Time zone** | All eCommerce timestamps are UTC. |
| **Session** | One `user_session`. Events with a null session (12 cart events) are excluded from session metrics. |
| **Views and carts** | Exclude `is_duplicate = true` (exact duplicate events). |
| **Purchases and revenue** | Include **all** purchase rows (duplicates may be multiple units). |
| **Revenue** | `SUM(price)` of purchase events. No zero-price purchases exist. |
| **Partial periods** | First and last weeks are partial; exclude or label them in weekly charts. |
| **Unknown values** | `unknown` = value never recorded; `n/a` = category level does not exist. |
| **Instacart orders** | `test` orders excluded (their products are hidden). |

---

## 2. North Star metric

| | |
|---|---|
| **Metric** | **Revenue per Session (RPS)** |
| **Why** | Captures both *whether* visitors buy and *how much*; directly moved by assortment (finding products, having the right products, price mix). Not inflated by traffic alone. |
| **Formula** | `SUM(revenue) / COUNT(sessions)` |
| **Source** | `gold.ec_fact_sessions` |
| **Baseline (Oct–Nov 2019)** | $505,152,392.77 / 23,016,650 = **$21.95** |
| **Direction** | Higher is better |
| **Owner** | Product Manager – Assortment |

### KPI tree (how the North Star breaks down)

```
Revenue per Session
├── Session Conversion Rate        (sessions with a purchase / all sessions)
│     ├── View → Cart rate          (sessions with cart / sessions with view)
│     └── Cart → Purchase rate      (sessions with cart & purchase / sessions with cart)
└── Revenue per Converting Session  (revenue / sessions with a purchase)
      ├── Items per converting session
      └── Average item price
```
`RPS = Session Conversion Rate × Revenue per Converting Session` – any change in the North Star can be traced to one of these branches.

---

## 3. Funnel KPIs (eCommerce, session level)

Source for all: `gold.ec_fact_sessions` · Owner: Product Manager – Assortment

| KPI | Definition | Formula | Baseline | Direction |
|---|---|---|---|---|
| **Session Conversion Rate** | Share of sessions that include a purchase | `COUNT_IF(has_purchase) / COUNT(*)` | TBD | ↑ |
| **View → Cart Rate** | Of sessions with a view, share that added to cart | `COUNT_IF(has_view AND has_cart) / COUNT_IF(has_view)` | TBD | ↑ |
| **Cart → Purchase Rate** | Of sessions with a cart, share that purchased | `COUNT_IF(has_cart AND has_purchase) / COUNT_IF(has_cart)` | TBD | ↑ |
| **Cart Abandonment Rate** | Of sessions with a cart, share that did not purchase | `1 − Cart → Purchase Rate` | TBD | ↓ |
| **Revenue per Converting Session** | Average revenue of sessions with a purchase | `SUM(revenue) / COUNT_IF(has_purchase)` | TBD | ↑ |
| **Items per Converting Session** | Purchases per converting session | `SUM(purchases) / COUNT_IF(has_purchase)` | TBD | ↑ |
| **Products Viewed per Session** | Breadth of browsing | `AVG(products_viewed)` | TBD | context |
| **Avg Session Duration (s)** | Time between first and last event | `AVG(duration_seconds)` | TBD | context |

> **Event-level vs session-level:** event ratios (e.g. total carts / total views ≈ 3.7%) describe *activity*; session rates describe *customers' visits*. Dashboards use **session-level** rates unless stated otherwise.

---

## 4. Assortment KPIs (eCommerce, product level)

Source: `gold.ec_fact_product_daily` + `gold.ec_dim_product` · Owner: Merchandising Lead

| KPI | Definition | Formula | Baseline | Direction |
|---|---|---|---|---|
| **Active SKUs** | Products with ≥ 1 view in the period | `COUNT(DISTINCT product_id) WHERE views > 0` | TBD | context |
| **Selling SKUs %** | Share of active SKUs with ≥ 1 purchase | `selling SKUs / active SKUs` | TBD | ↑ |
| **Revenue per Active SKU** | Average SKU productivity | `SUM(revenue) / active SKUs` | TBD | ↑ |
| **Top-20% Revenue Share** | Revenue concentration (Pareto) | revenue of top 20% SKUs by revenue / total revenue | TBD | context |
| **Long-Tail Share** | Share of active SKUs with zero purchases | `SKUs with views > 0 AND purchases = 0 / active SKUs` | TBD | ↓ |
| **Product View → Purchase Rate** | How well a product converts interest | `SUM(purchases) / SUM(views)` per product | TBD | ↑ |
| **Category Revenue Mix** | Share of revenue by category level 1 | `category revenue / total revenue` | TBD | context |
| **Catalog Completeness** | Share of products with a known category / brand | `products with known value / all products` | Category 42.9% · Brand 76.5% | ↑ |

---

## 5. Assortment KPIs (Instacart, grocery baskets)

Source: `gold.ic_fact_order_products` + `gold.ic_dim_product` + `gold.ic_dim_order` · Owner: Merchandising Lead

| KPI | Definition | Formula | Baseline | Direction |
|---|---|---|---|---|
| **Order Penetration** | Share of orders containing the product / aisle / department | `COUNT(DISTINCT order_id with item) / COUNT(DISTINCT order_id)` | TBD | ↑ |
| **Reorder Rate** | Share of purchases that were repeat purchases | `SUM(reordered) / COUNT(*)`, **excluding first orders** | TBD | ↑ |
| **Customer Reach** | Distinct customers who bought the item | `COUNT(DISTINCT user_id)` | TBD | ↑ |
| **Basket Size** | Products per order | `COUNT(*) / COUNT(DISTINCT order_id)` | TBD | context |
| **Avg Add-to-Cart Position** | How early an item is added (low = planned / staple) | `AVG(add_to_cart_order)` | TBD | context |
| **Basket Affinity (Lift)** | How much more often two items are bought together than by chance | `P(A and B) / (P(A) × P(B))` | analysis phase | > 1 = affinity |

> Reorder rate excludes first orders because a customer's first order cannot contain reorders; including it would understate loyalty for every product.

---

## 6. A/B test metrics

Source: `silver.ab_test`, `gold.ab_summary`, `gold.ab_daily` · Owner: Insights / Analytics

| Metric | Definition |
|---|---|
| **Primary metric** | User conversion rate = `SUM(converted) / COUNT(users)` per group |
| **Unit of analysis** | User (one row per user, first exposure) |
| **Sample Ratio Mismatch (SRM) check** | Chi-square test on group sizes; investigate if p < 0.01 |
| **Significance level** | Two-sided test, α = 0.05 |
| **Practical threshold** | Treatment must improve conversion by **≥ 0.5 percentage points** to justify a launch |
| **Decision rule** | Launch only if the result is statistically significant **and** the 95% confidence interval's lower bound is > 0 **and** the estimated lift meets the practical threshold |
| **Stability check** | Daily conversion by group (`gold.ab_daily`) for novelty or day-of-week effects |

---

## 7. Data quality KPIs (pipeline health)

Owner: Insights / Analytics (pipeline owner)

| KPI | Target | Current |
|---|---|---|
| Source-to-target row reconciliation (Bronze) | 100% match | ✅ 100% |
| Revenue reconciliation (events = sessions = product daily) | Exact match | ✅ $505,152,392.77 |
| Orphan foreign keys (all facts) | 0 | ✅ 0 |
| Failed timestamp parsing | 0 | ✅ 0 |
| Duplicate events (flagged) | Monitor | 130,750 (0.12%) |
| Null sessions | Monitor | 12 |

---

## Change log

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-09-25 | Initial KPI framework |
