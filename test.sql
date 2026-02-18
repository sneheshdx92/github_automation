-- After snapshot_active CTE, replace the final SELECT with:

snapshot_with_prev AS (
    SELECT 
        snapshot_date,
        LAG(snapshot_date) OVER (ORDER BY snapshot_date) AS prev_snapshot_date
    FROM (SELECT DISTINCT snapshot_date FROM snapshot_active)
),

-- Entered: in current, not in prev
entered AS (
    SELECT sp.snapshot_date, COUNT(DISTINCT curr.cust_profile_id) AS entered
    FROM snapshot_with_prev sp
    JOIN snapshot_active curr ON curr.snapshot_date = sp.snapshot_date
    LEFT JOIN snapshot_active prev 
        ON prev.cust_profile_id = curr.cust_profile_id
        AND prev.snapshot_date = sp.prev_snapshot_date
    WHERE prev.cust_profile_id IS NULL
      AND sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.snapshot_date
),

-- Exited: in prev, not in current
exited AS (
    SELECT sp.snapshot_date, COUNT(DISTINCT prev.cust_profile_id) AS exited
    FROM snapshot_with_prev sp
    JOIN snapshot_active prev ON prev.snapshot_date = sp.prev_snapshot_date
    LEFT JOIN snapshot_active curr
        ON curr.cust_profile_id = prev.cust_profile_id
        AND curr.snapshot_date = sp.snapshot_date
    WHERE curr.cust_profile_id IS NULL
    GROUP BY sp.snapshot_date
),

pop AS (
    SELECT snapshot_date, COUNT(DISTINCT cust_profile_id) AS active_population
    FROM snapshot_active
    GROUP BY snapshot_date
)

SELECT
    p.snapshot_date,
    p.active_population,
    COALESCE(e.entered, 0)                        AS entered,
    COALESCE(x.exited, 0)                         AS exited,
    COALESCE(e.entered, 0) - COALESCE(x.exited,0) AS net_movement
FROM pop p
LEFT JOIN entered e ON e.snapshot_date = p.snapshot_date
LEFT JOIN exited  x ON x.snapshot_date = p.snapshot_date
ORDER BY p.snapshot_date
