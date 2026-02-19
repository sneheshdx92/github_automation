SELECT entered, exited 
FROM (
    SELECT 
        SUM(CASE WHEN nm.net > 0 OR (nm.net = 0 AND la.last_action = 'INSERT') THEN 1 ELSE 0 END) AS entered,
        SUM(CASE WHEN nm.net < 0 THEN 1 ELSE 0 END) AS exited
    FROM net_movements nm
    JOIN last_action_per_customer la
        ON la.tranche_name = nm.tranche_name
        AND la.snapshot_date = nm.snapshot_date
        AND la.cust_profile_id = nm.cust_profile_id
    WHERE nm.tranche_name = 'MAOS Child Profiles'
    AND nm.snapshot_date = '2025-01-01'
)
