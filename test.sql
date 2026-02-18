WITH 
tranche_data AS (
    SELECT cust_profile_id, change_action, CAST(change_dttm AS TIMESTAMP) AS change_dttm
    FROM population_identified_hist
    WHERE tranche_name = '3d Associations'
),

snapshots(snapshot_date) AS (
    VALUES 
        (DATE '2024-01-01'),
        (DATE '2024-04-01'),
        (DATE '2024-07-01'),
        (DATE '2024-10-01'),
        (DATE '2025-01-01'),
        (DATE '2025-04-01'),
        (DATE '2025-07-01'),
        (DATE '2025-10-01'),
        (DATE '2026-01-01'),
        (CURRENT_DATE)
),

snapshot_periods AS (
    SELECT 
        snapshot_date,
        LAG(snapshot_date) OVER (ORDER BY snapshot_date) AS prev_snapshot_date
    FROM snapshots
),

-- Point-in-time active population (unchanged)
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
),

snapshot_active AS (
    SELECT snapshot_date, cust_profile_id
    FROM point_in_time
    WHERE rn = 1 AND change_action IN ('INSERT', 'UPDATE')
),

pop AS (
    SELECT snapshot_date, COUNT(DISTINCT cust_profile_id) AS active_population
    FROM snapshot_active
    GROUP BY snapshot_date
),

-- Entered: first INSERT per customer falls within the period
entered AS (
    SELECT sp.snapshot_date, COUNT(DISTINCT t.cust_profile_id) AS entered
    FROM snapshot_periods sp
    JOIN tranche_data t 
        ON t.change_dttm > sp.prev_snapshot_date
        AND t.change_dttm <= sp.snapshot_date
        AND t.change_action = 'INSERT'
    -- Only count if customer had NO record before this period (truly new)
    WHERE NOT EXISTS (
        SELECT 1 FROM tranche_data t2
        WHERE t2.cust_profile_id = t.cust_profile_id
        AND t2.change_dttm < sp.prev_snapshot_date
    )
    AND sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.snapshot_date
),

-- Exited: last DELETE per customer falls within the period AND no INSERT after
exited AS (
    SELECT sp.snapshot_date, COUNT(DISTINCT t.cust_profile_id) AS exited
    FROM snapshot_periods sp
    JOIN tranche_data t
        ON t.change_dttm > sp.prev_snapshot_date
        AND t.change_dttm <= sp.snapshot_date
        AND t.change_action = 'DELETE'
    -- Confirm no INSERT after this DELETE (truly gone)
    WHERE NOT EXISTS (
        SELECT 1 FROM tranche_data t2
        WHERE t2.cust_profile_id = t.cust_profile_id
        AND t2.change_action = 'INSERT'
        AND t2.change_dttm > t.change_dttm
    )
    AND sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.snapshot_date
)

SELECT
    p.snapshot_date,
    p.active_population,
    COALESCE(e.entered, 0)                         AS entered,
    COALESCE(x.exited, 0)                          AS exited,
    COALESCE(e.entered, 0) - COALESCE(x.exited, 0) AS net_movement
FROM pop p
LEFT JOIN entered e ON e.snapshot_date = p.snapshot_date
LEFT JOIN exited  x ON x.snapshot_date = p.snapshot_date
ORDER BY p.snapshot_date




-- Customers active on 2024-01-01 but NOT active on 2024-04-01
-- that are NOT in our exited count
SELECT t.cust_profile_id, t.change_action, t.change_dttm
FROM population_identified_hist t
WHERE tranche_name = '3d Associations'
AND cust_profile_id IN (
    -- Active on 2024-01-01
    SELECT cust_profile_id FROM (
        SELECT cust_profile_id, change_action,
            ROW_NUMBER() OVER (PARTITION BY cust_profile_id ORDER BY CAST(change_dttm AS TIMESTAMP) DESC) AS rn
        FROM population_identified_hist
        WHERE tranche_name = '3d Associations'
        AND CAST(change_dttm AS TIMESTAMP) <= '2024-01-01'
    ) WHERE rn = 1 AND change_action IN ('INSERT','UPDATE')
)
AND cust_profile_id NOT IN (
    -- Active on 2024-04-01
    SELECT cust_profile_id FROM (
        SELECT cust_profile_id, change_action,
            ROW_NUMBER() OVER (PARTITION BY cust_profile_id ORDER BY CAST(change_dttm AS TIMESTAMP) DESC) AS rn
        FROM population_identified_hist
        WHERE tranche_name = '3d Associations'
        AND CAST(change_dttm AS TIMESTAMP) <= '2024-04-01'
    ) WHERE rn = 1 AND change_action IN ('INSERT','UPDATE')
)
ORDER BY cust_profile_id, CAST(change_dttm AS TIMESTAMP)
