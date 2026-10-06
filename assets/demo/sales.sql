-- Demo data for the parquet viewer:  duckdb < sales.sql
COPY (
  SELECT
    i AS order_id,
    DATE '2025-01-01' + (i % 365)::INTEGER AS order_date,
    ['Ava Chen', 'Noah Patel', 'Mia Garcia', 'Liam Okafor', 'Zoe Müller', 'Kenji Sato'][1 + (i * 5) % 6] AS customer,
    ['Tampa', 'Austin', 'Denver', 'Boston', 'Seattle', 'Chicago'][1 + (i * 3) % 6] AS city,
    ['North', 'South', 'East', 'West'][1 + i % 4] AS region,
    ['Laptop', 'Monitor', 'Keyboard', 'Mouse', 'Dock', 'Headset'][1 + (i * 7) % 6] AS product,
    1 + (i * 13) % 9 AS units,
    round(19.99 + ((i * 37) % 2000) / 3.0, 2)::DECIMAL(10, 2) AS unit_price,
    (((i * 11) % 4) * 0.05)::DOUBLE AS discount,
    round(units * unit_price * (1 - discount), 2)::DECIMAL(12, 2) AS revenue,
    TIMESTAMP '2025-01-01 08:00:00' + to_minutes(i * 7 % 525600) AS shipped_at,
    ['Ground', 'Express', 'Overnight'][1 + i % 3] AS ship_mode,
    (i * 31) % 17 = 0 AS returned,
    CASE WHEN i % 5 = 0 THEN NULL
         ELSE ['Left at the front desk, customer asked for a call before delivery',
               'Gift wrap requested', 'Expedite: replacement for a damaged unit',
               'Delivered to the loading dock, signed by J. Rivera'][1 + i % 4]
    END AS note,
    ['priority', 'web', 'b2b', 'promo'][1 + i % 4:2 + (i * 3) % 4] AS tags
  FROM range(1, 1250001) t(i)
) TO 'sales.parquet' (FORMAT parquet);
