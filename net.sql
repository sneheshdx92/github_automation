-- Last action per customer per period
last_action_per_customer AS (
    SELECT
        sp.tranche_name,
        sp.snapshot_date,
        b.cust_profile_id,
        b.change_action AS last_action
    FROM snapshot_periods sp
    JOIN base b
        ON b.tranche_name = sp.tranche_name
        AND b.change_dttm > sp.prev_snapshot_date
        AND b.change_dttm <= sp.snapshot_date
    WHERE sp.prev_snapshot_date IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY sp.tranche_name, sp.snapshot_date, b.cust_profile_id
        ORDER BY b.change_dttm DESC
    ) = 1
),

net_movements AS (
    SELECT
        sp.tranche_name,
        sp.snapshot_date,
        b.cust_profile_id,
        SUM(CASE
            WHEN b.change_action = 'INSERT' THEN 1
            WHEN b.change_action = 'DELETE' THEN -1
            ELSE 0
        END) AS net
    FROM snapshot_periods sp
    JOIN base b
        ON b.tranche_name = sp.tranche_name
        AND b.change_dttm > sp.prev_snapshot_date
        AND b.change_dttm <= sp.snapshot_date
    WHERE sp.prev_snapshot_date IS NOT NULL
    GROUP BY sp.tranche_name, sp.snapshot_date, b.cust_profile_id
),

entered AS (
    SELECT nm.tranche_name, nm.snapshot_date, COUNT(nm.cust_profile_id) AS entered
    FROM net_movements nm
    JOIN last_action_per_customer la
        ON la.tranche_name = nm.tranche_name
        AND la.snapshot_date = nm.snapshot_date
        AND la.cust_profile_id = nm.cust_profile_id
    WHERE nm.net > 0 OR (nm.net = 0 AND la.last_action = 'INSERT')
    GROUP BY nm.tranche_name, nm.snapshot_date
),

exited AS (
    SELECT tranche_name, snapshot_date, COUNT(cust_profile_id) AS exited
    FROM net_movements
    WHERE net < 0
    GROUP BY tranche_name, snapshot_date
)
