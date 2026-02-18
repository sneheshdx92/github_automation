# CAR 1 Treatment Plan – Population Query Explanation

**Tranche:** 3d Associations  
**Period:** 01 Jan 2024 – 18 Feb 2026

---

## What Does This Query Do?

Tracks how many customers are active in a tranche at quarterly checkpoints, and counts how many entered or exited between each checkpoint.

**The reconciliation rule:**
> `previous_population + entered - exited = current_population`

---

## Step-by-Step Breakdown

---

### Step 1: `tranche_data` CTE

```sql
WITH tranche_data AS (
    SELECT cust_profile_id, change_action,
           CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) AS change_dttm
    FROM population_identified_hist
    WHERE tranche_name = '3d Associations'
)
```

**What it does:**  
Filters the full history table down to only records for `3d Associations`. Also cleans the `change_dttm` column from `2024-08-23T12.29.33` format into a proper timestamp `2024-08-23 12:29:33` that SQL can work with.

---

### Step 2: `snapshots` CTE

```sql
snapshots(snapshot_date) AS (
    VALUES
        (DATE '2024-01-01'),
        (DATE '2024-04-01'),
        ...
        (CURRENT_DATE)
)
```

**What it does:**  
Creates a small manual table of quarterly checkpoint dates. These are the moments in time where we take a "photo" of the population.

---

### Step 3: `snapshot_periods` CTE

```sql
snapshot_periods AS (
    SELECT
        snapshot_date,
        LAG(snapshot_date) OVER (ORDER BY snapshot_date) AS prev_snapshot_date
    FROM snapshots
)
```

**What it does:**  
For each checkpoint, adds a column showing the **previous checkpoint date** using `LAG`. This gives us a "from–to" window for each period.

| snapshot_date | prev_snapshot_date |
|---|---|
| 2024-01-01 | NULL |
| 2024-04-01 | 2024-01-01 |
| 2024-07-01 | 2024-04-01 |
| ... | ... |

---

### Step 4: `point_in_time` CTE

```sql
point_in_time AS (
    SELECT
        s.snapshot_date,
        t.cust_profile_id,
        t.change_action,
        ROW_NUMBER() OVER (
            PARTITION BY s.snapshot_date, t.cust_profile_id
            ORDER BY t.change_dttm DESC
        ) AS rn
    FROM snapshots s
    JOIN tranche_data t ON t.change_dttm <= s.snapshot_date
)
```

**What it does:**  
This is the core of the query. For every checkpoint date, it joins all customer records that happened **on or before** that date. Then it numbers each customer's records newest-first using `ROW_NUMBER`.

**Row 1 = the customer's most recent record at that point in time.**

Example for one customer at `2024-07-01`:

| rn | change_action | change_dttm |
|---|---|---|
| 1 | UPDATE | 2024-05-10 |
| 2 | INSERT | 2022-10-19 |

We only care about `rn = 1`.

---

### Step 5: `snapshot_active` CTE

```sql
snapshot_active AS (
    SELECT snapshot_date, cust_profile_id
    FROM point_in_time
    WHERE rn = 1 AND change_action IN ('INSERT', 'UPDATE')
)
```

**What it does:**  
Keeps only the most recent record (`rn = 1`) per customer per checkpoint, where the latest action is `INSERT` or `UPDATE` — meaning the customer is **currently active** in the tranche at that date.

If their latest action was `DELETE` → excluded (they've left).

---

### Step 6: `pop` CTE

```sql
pop AS (
    SELECT snapshot_date, COUNT(DISTINCT cust_profile_id) AS active_population
    FROM snapshot_active
    GROUP BY snapshot_date
)
```

**What it does:**  
Simple count of active customers per checkpoint. This is the `active_population` column in the final output.

---

### Step 7: `entered` CTE

```sql
entered AS (
    SELECT sp.snapshot_date, COUNT(DISTINCT t.cust_profile_id) AS entered
    FROM snapshot_periods sp
    JOIN tranche_data t
        ON t.change_dttm > sp.prev_snapshot_date
        AND t.change_dttm <= sp.snapshot_date
        AND t.change_action = 'INSERT'
    WHERE sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.snapshot_date
)
```

**What it does:**  
Counts customers who had an `INSERT` **within the period** (between previous and current checkpoint). This includes both brand new customers and those who transferred in from another tranche.

---

### Step 8: `exited` CTE

```sql
exited AS (
    SELECT sp.snapshot_date, COUNT(DISTINCT t.cust_profile_id) AS exited
    FROM snapshot_periods sp
    JOIN tranche_data t
        ON t.change_dttm > sp.prev_snapshot_date
        AND t.change_dttm <= sp.snapshot_date
        AND t.change_action = 'DELETE'
    WHERE sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.snapshot_date
)
```

**What it does:**  
Counts customers who had a `DELETE` within the period. This includes customers who truly left the program and those who moved to a different tranche. Every DELETE = an exit event, regardless of what happens afterwards.

---

### Step 9: Final SELECT

```sql
SELECT
    p.snapshot_date,
    p.active_population,
    COALESCE(e.entered, 0)                          AS entered,
    COALESCE(x.exited, 0)                           AS exited,
    COALESCE(e.entered, 0) - COALESCE(x.exited, 0)  AS net_movement
FROM pop p
LEFT JOIN entered e ON e.snapshot_date = p.snapshot_date
LEFT JOIN exited  x ON x.snapshot_date = p.snapshot_date
ORDER BY p.snapshot_date
```

**What it does:**  
Joins the three CTEs — population, entered, exited — into one clean row per checkpoint. `COALESCE(..., 0)` ensures periods with no movements show `0` instead of `NULL`.

---

## The Big Picture

Think of it like a **swimming pool**:

| Concept | Meaning |
|---|---|
| `active_population` | How many people are in the pool at each photo |
| `entered` | How many jumped in during the period |
| `exited` | How many climbed out during the period |
| `net_movement` | Jumped in minus climbed out |

And every period must satisfy:  
**previous photo + jumped in − climbed out = current photo** ✅

---

## Validation Queries

### 1. Spot check active population at a date
```sql
SELECT COUNT(DISTINCT cust_profile_id) AS active
FROM (
    SELECT cust_profile_id, change_action,
        ROW_NUMBER() OVER (
            PARTITION BY cust_profile_id
            ORDER BY CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) DESC
        ) AS rn
    FROM population_identified_hist
    WHERE tranche_name = '3d Associations'
    AND CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) <= '2024-01-01'
) WHERE rn = 1 AND change_action IN ('INSERT', 'UPDATE')
```

### 2. Spot check entered for a period
```sql
SELECT COUNT(DISTINCT cust_profile_id)
FROM population_identified_hist
WHERE tranche_name = '3d Associations'
AND change_action = 'INSERT'
AND CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) > '2024-07-01'
AND CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) <= '2024-10-01'
```

### 3. Spot check exited for a period
```sql
SELECT COUNT(DISTINCT cust_profile_id)
FROM population_identified_hist
WHERE tranche_name = '3d Associations'
AND change_action = 'DELETE'
AND CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) > '2024-07-01'
AND CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) <= '2024-10-01'
```

---

## Key Decisions Made

| Decision | Reason |
|---|---|
| `INSERT` and `UPDATE` = active | UPDATE means attribute changed but customer still in tranche |
| `DELETE` = exited regardless of future INSERT | Captures re-entries as separate events for full transparency |
| Quarterly snapshots | Balances granularity with readability for business stakeholders |
| `COUNT(DISTINCT cust_profile_id)` | Avoids double-counting customers with multiple records |
