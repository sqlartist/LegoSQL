/*  00_TwoBricks.sql  --  how many ways can you join two 2x4 bricks?
    ----------------------------------------------------------------
    Fix the bottom brick at the origin, 2 studs wide (X) by 4 long (Z), and slide the
    top brick over it, either parallel or turned 90 degrees, keeping at least one stud
    in contact. That's 46 placements.

    But spin the whole thing 180 degrees and some placements turn into others, so they
    aren't really different builds. Burnside's lemma: the number of distinct builds is
    the average number of placements each rotation leaves unchanged:
        identity leaves all 46 alone; the 180 degree turn leaves only the 2 centred ones
        (46 + 2) / 2 = 24
*/
WITH TopBrick AS
(
    SELECT w = 2, l = 4             -- parallel
    UNION ALL SELECT 4, 2           -- turned 90 degrees
),
Placement AS
(
    SELECT b.w, b.l, dx = x.value, dz = z.value
    FROM TopBrick AS b
    CROSS JOIN GENERATE_SERIES(-3, 3) AS x
    CROSS JOIN GENERATE_SERIES(-3, 3) AS z
    WHERE x.value < 2 AND x.value + b.w > 0     -- the footprints overlap in X...
      AND z.value < 4 AND z.value + b.l > 0     -- ...and in Z (the "date range overlap" test)
)
SELECT RawPlacements  = COUNT(*),                                             -- 46
       FixedBy180     = SUM(IIF(2 * dx + w = 2 AND 2 * dz + l = 4, 1, 0)),    -- 2: centred on the bottom brick
       DistinctBuilds = (COUNT(*) + SUM(IIF(2 * dx + w = 2 AND 2 * dz + l = 4, 1, 0))) / 2   -- 24
FROM Placement;
