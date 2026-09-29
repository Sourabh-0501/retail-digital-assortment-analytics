# Findings Log – Digital Assortment Analytics

Each finding records **what** we found, the **evidence**, the **business implication**, and the **next step**.
Metric definitions follow `docs/kpi_framework.md`. Source tables are in the `gold` schema.

**Status legend:** ✅ Confirmed · 🔍 Hypothesis (needs testing) · ❌ Retracted

---

## Module 1 – KPI baselines

### #1 One-third of purchasing sessions have no cart event ✅
- **Evidence:** 462,538 of 1,402,758 converting sessions (32.97%) contain a purchase but no cart event (`gold.ec_fact_sessions`).
- **Implication:** the view → cart → purchase funnel misses one in three buyers. Cart → Purchase (40.59%) and Cart Abandonment (59.41%) describe only the 67% of buyers who used the cart in-session.
- **Next step:** 🔍 test whether these users added to cart in an *earlier* session (multi-session journeys) vs. a direct "buy now" path.

**Baseline snapshot (Oct–Nov 2019, all days):** Revenue per Session **$21.95** · Session Conversion **6.09%** · View → Cart **10.04%** · Revenue per Converting Session **$360.11** · Items per Converting Session **1.18** · Median Session **61 s** (mean 1,100 s, skewed) · Bounce Rate **35.92%**.
> ⚠️ These period averages include the Nov 14–17 anomaly window (see #3).

---

## Module 2 – Trends

### #2 Black Friday lifted revenue through traffic and conversion, not basket size ✅
- **Evidence:** vs. the same week's Mon–Thu average: sessions +15.7%, conversion +0.82 pp (5.32% → 6.14%), revenue +36.2% ($7.07M → $9.63M). Revenue per converting session was nearly unchanged (~$336 → ~$349).
- **Implication:** the promotion brought more buyers, not bigger baskets. Bundles and cross-sell were not part of the uplift.
- **Note:** Black Friday was **not** the top revenue day of the period (see #3).

### #3 Nov 14–17 is an anomaly window: sale event + likely checkout / tracking incident ✅
- **Evidence:**

| Date | Sessions | Conversion | Revenue |
|---|---|---|---|
| Nov 14 (Thu) | 560K | 3.34% | $6.9M |
| **Nov 15 (Fri)** | **764K** | **0.00%** | **$40** |
| Nov 16 (Sat) | 992K | 5.71% | $23.4M |
| **Nov 17 (Sun)** | 975K | **15.53%** | **$57.8M** |

- Revenue per converting session and items per converting session were normal on all days → the spike is driven by the **number of buyers**, not duplicated or inflated purchases.
- **Likely cause:** a major store sale drove traffic up to ~2.7× normal; purchases were blocked or not recorded on Nov 15; demand shifted to Nov 16–17.
- **Implication:** the window inflates period averages and creates false signals in day-of-week and week-over-week comparisons.
- **Action:** window is flagged as `is_anomaly_window` in `gold.kpi_daily`; confirm root cause with engineering; if checkout failed, quantify lost revenue.

### #4 No meaningful day-of-week effect ✅ (replaces a retracted finding)
- ❌ **Retracted:** "weekend days generate +53% more revenue." This was driven entirely by Nov 16–17.
- **Evidence (excluding Nov 14–17):** weekday vs. weekend median daily revenue $7.16M vs. $6.92M; conversion 5.92% vs. 6.08%; revenue per session $21.16 vs. $21.09.
- **Implication:** weekly performance is driven by events, not by weekday/weekend patterns.

### #5 November traffic grew 35% but value did not ✅
- **Evidence (Oct vs. Nov, excluding Nov 14–17, per-day comparison):** sessions/day +35.2% (298K → 403K); conversion 6.81% → 5.21% (−1.60 pp); revenue per session $24.88 → $17.84 (−28.3%); revenue/day −3.1% ($7.42M → $7.19M).
- **Implication:** growth in traffic did not translate into value; visitor intent or quality declined. Performance must be judged on revenue per session (North Star), not traffic.
- **Next step:** 🔍 Module 3 – is the decline broad or concentrated in specific categories?

### #6 Steady decline in revenue per session from mid-October to mid-November ✅
- **Evidence:** weekly revenue per session fell from $26.55 (week of Oct 14) to $16.91 (week of Nov 18), partially recovering to $19.24 in Black Friday week. 7-day averages show traffic rising (~268K → ~433K sessions/day) while revenue stayed flat (~$6.8–7.1M/day).
- **Also noted:** 🔍 a mid-October revenue bump (Oct 13–17, $8.5–9.8M/day with normal traffic) suggests a smaller promotion worth investigating.

---

## Module 3 – eCommerce assortment

### #7 Revenue is extremely concentrated ✅
- **Evidence:** ~676 SKUs (0.33% of all SKUs, ~1% of selling SKUs) drive 80% of revenue. The top 10 SKUs – all smartphones, 7 Apple and 3 Samsung – drive $130.5M (25.8%). The #1 SKU alone drives $33.0M (6.5%).
- **Two hero roles:** premium Apple models drive revenue (e.g. ~$921, 3.8% view→purchase); affordable Samsung models drive volume (e.g. ~$128, 61K units, 6.5% view→purchase).
- **Implication:** high dependency on a few products and one brand – protect availability and pricing of the head; supplier-concentration risk.

### #8 Missing categories are a broad catalog issue, not a driver of non-selling ✅
- **Evidence:** missing category for 58.6% of zero-sellers vs. 54.1% of selling SKUs. Weighted by products 57%, by events 32%, by revenue **10.45% ($52.8M)**.
- **Implication:** fund catalog tagging using the revenue-weighted gap. Association ≠ causation – measuring the sales effect of adding categories would need a controlled test.

### #9 The long tail splits into fix, watch and review groups ✅
- **Evidence:** 138,800 SKUs (67%) were viewed but never sold. 85% of them had < 100 views in two months; 15% had 100–999; **278 SKUs had 1,000+ views and zero purchases**.
- **Action:** prioritize the 278 for a fix review (price, stock, content). Limitation: no inventory data, so stockouts cannot be separated from lack of demand.

### #10 Category performance differs sharply ✅
- **Evidence:** electronics = 75.6% of revenue with the best conversion (2.48% view→purchase, $10.31 revenue/view). Apparel has the most SKUs of any named category (18,794) but 0.36% of revenue, 0.50% conversion and ~$96 revenue per SKU (vs. ~$22,860 in electronics).
- **Implication:** protect electronics; rationalize low-productivity categories (apparel, furniture, construction); test – don't assume – expansion of small efficient niches (medicine, stationery: tiny samples).

### #11 The November decline is site-wide ✅ (answers #5)
- **Evidence (Oct vs. Nov, excluding Nov 14–17):** view→purchase fell in **all 14 categories** (electronics 2.81% → 2.32%, computers 1.23% → 0.84%). Traffic also shifted toward low-converting categories (apparel +52%, computers +41% vs. electronics +22%).
- **Interpretation:** a rate effect (worse conversion everywhere) plus a mix effect (traffic moving to harder-to-convert categories). Likely site-wide causes: seasonal browsing, deal-waiting, lower-intent campaign traffic.
- **Impact estimate (what-if):** electronics would have earned ~$1.2M/day more at October's conversion rate, assuming comparable traffic intent.

### #12 SKU segmentation mart ✅
- **Table:** `gold.sku_segments` – every SKU with a segment and recommended action.

| Segment | SKUs | SKU share | Revenue share | Action |
|---|---|---|---|---|
| Hero | 676 | 0.33% | 80% | Protect availability and pricing |
| Core | 67,400 | 32.58% | 20% | Maintain |
| Fix | 278 | 0.13% | 0% | Review price, stock and content |
| Watch | 20,993 | 10.15% | 0% | Investigate by category |
| Tail review | 117,529 | 56.81% | 0% | Delist or discoverability review |

---

## Method notes (lessons applied)
- Time series are **driven from `dim_date` with a LEFT JOIN**, so days with no activity still appear.
- Rates are **weighted** (total numerator ÷ total denominator), never averages of daily percentages.
- Periods of different length are compared **per day**, not as raw totals.
- Moving averages are **null until the window is full** and **smear outliers** across 7 days.
- Every average-based conclusion is re-checked with **medians** and **with outliers excluded**.
- Data quality gaps are reported **weighted by products, events and revenue** – the weighting changes the story.
- Extreme results are **sanity-checked** (e.g. Pareto on selling SKUs only) before interpretation.