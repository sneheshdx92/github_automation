WITH

-- Define tranche commencement dates here
tranche_config(tranche_name, commencement_date) AS (
    VALUES
        ('3d Associations',  DATE '2024-01-01'),
        ('SME Banking',      DATE '2024-04-01'),
        ('Private Banking',  DATE '2023-07-01'),
        ('Business Lending', DATE '2024-07-01')
),

-- Clean timestamp once
base AS (
    SELECT 
        cust_profile_id,
        tranche_name,
        change_action,
        CAST(REPLACE(REPLACE(change_dttm, 'T', ' '), '.', ':') AS TIMESTAMP) AS change_dttm
    FROM population_identified_hist
    WHERE tranche_name IN (SELECT tranche_name FROM tranche_config)
),

-- Generate quarterly snapshots per tranche from its commencement date to today
snapshots AS (
    SELECT 
        tc.tranche_name,
        UNNEST(GENERATE_SERIES(
            tc.commencement_date,
            CURRENT_DATE,
            INTERVAL '3 months'
        ))::DATE AS snapshot_date
    FROM tranche_config tc
    UNION ALL
    -- Always include current date as final snapshot
    SELECT tranche_name, CURRENT_DATE FROM tranche_config
),

snapshot_periods AS (
    SELECT
        tranche_name,
        snapshot_date,
        LAG(snapshot_date) OVER (
            PARTITION BY tranche_name 
            ORDER BY snapshot_date
        ) AS prev_snapshot_date
    FROM snapshots
),

-- Latest record per customer per tranche per snapshot
point_in_time AS (
    SELECT
        s.tranche_name,
        s.snapshot_date,
        b.cust_profile_id,
        b.change_action,
        ROW_NUMBER() OVER (
            PARTITION BY s.tranche_name, s.snapshot_date, b.cust_profile_id
            ORDER BY b.change_dttm DESC
        ) AS rn
    FROM snapshots s
    JOIN base b 
        ON b.tranche_name = s.tranche_name
        AND b.change_dttm <= s.snapshot_date
),

snapshot_active AS (
    SELECT tranche_name, snapshot_date, cust_profile_id
    FROM point_in_time
    WHERE rn = 1 AND change_action IN ('INSERT', 'UPDATE')
),

pop AS (
    SELECT tranche_name, snapshot_date, COUNT(DISTINCT cust_profile_id) AS active_population
    FROM snapshot_active
    GROUP BY tranche_name, snapshot_date
),

entered AS (
    SELECT sp.tranche_name, sp.snapshot_date, COUNT(DISTINCT b.cust_profile_id) AS entered
    FROM snapshot_periods sp
    JOIN base b
        ON b.tranche_name = sp.tranche_name
        AND b.change_dttm > sp.prev_snapshot_date
        AND b.change_dttm <= sp.snapshot_date
        AND b.change_action = 'INSERT'
    WHERE sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.tranche_name, sp.snapshot_date
),

exited AS (
    SELECT sp.tranche_name, sp.snapshot_date, COUNT(DISTINCT b.cust_profile_id) AS exited
    FROM snapshot_periods sp
    JOIN base b
        ON b.tranche_name = sp.tranche_name
        AND b.change_dttm > sp.prev_snapshot_date
        AND b.change_dttm <= sp.snapshot_date
        AND b.change_action = 'DELETE'
    WHERE sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.tranche_name, sp.snapshot_date
),

-- Tranche level result
tranche_level AS (
    SELECT
        p.tranche_name,
        p.snapshot_date,
        p.active_population,
        COALESCE(e.entered, 0)                           AS entered,
        COALESCE(x.exited, 0)                            AS exited,
        COALESCE(e.entered, 0) - COALESCE(x.exited, 0)  AS net_movement
    FROM pop p
    LEFT JOIN entered e ON e.tranche_name = p.tranche_name AND e.snapshot_date = p.snapshot_date
    LEFT JOIN exited  x ON x.tranche_name = p.tranche_name AND x.snapshot_date = p.snapshot_date
),

-- CAR 1 summary rollup
car1_summary AS (
    SELECT
        'CAR 1 TOTAL'      AS tranche_name,
        snapshot_date,
        SUM(active_population) AS active_population,
        SUM(entered)           AS entered,
        SUM(exited)            AS exited,
        SUM(net_movement)      AS net_movement
    FROM tranche_level
    GROUP BY snapshot_date
)

-- Final output: tranche detail + CAR1 rollup
SELECT * FROM tranche_level
UNION ALL
SELECT * FROM car1_summary
ORDER BY snapshot_date, tranche_name
