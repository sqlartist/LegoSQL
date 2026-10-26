/*  04_Bricks.sql  --  merge 1x1 voxels into real bricks
    ----------------------------------------------------
    Greedy, biggest part first. For each part, every free spot where it fits is a
    "candidate". Candidates overlap each other, so we keep only those with no
    better-ranked overlapping candidate (a maximal independent set, built in rounds):
    the best candidate on each layer always wins, so every round makes progress.

    Overlap is the same test as two date ranges overlapping, once per axis:
        a.X < b.X + b.SizeX  AND  b.X < a.X + a.SizeX     (and the same for Z)

    Even layers prefer bricks running along X, odd layers along Z, so the joints of
    one layer are bridged by the layer above (a brick-wall bond).
*/
USE LegoSQL;
GO
CREATE OR ALTER PROCEDURE lego.BuildBricks
    @ModelID        int,
    @Wall           int = 2,      -- keep voxels this deep from the surface; NULL = solid
    @DefaultColour  int = 78      -- Light Nougat, for voxels not yet coloured
AS
BEGIN
    SET NOCOUNT ON;
    DELETE lego.Brick WHERE ModelID = @ModelID;

    DROP TABLE IF EXISTS #Free, #Cand, #New;
    SELECT X, Y, Z, ColourID = COALESCE(ColourID, @DefaultColour)
    INTO #Free
    FROM lego.Voxel
    WHERE ModelID = @ModelID AND (@Wall IS NULL OR Depth <= @Wall);
    CREATE UNIQUE CLUSTERED INDEX CX ON #Free (Y, Z, X);

    CREATE TABLE #Cand (Y smallint, X smallint, Z smallint, SizeX tinyint, SizeZ tinyint,
                        ColourID int, Pri int, PRIMARY KEY (Y, Pri));
    CREATE TABLE #New  (Y smallint, X smallint, Z smallint, SizeX tinyint, SizeZ tinyint);

    DECLARE @PartID varchar(20), @Rounds int = 0;
    DECLARE parts CURSOR LOCAL FAST_FORWARD FOR
        SELECT PartID FROM lego.Part ORDER BY Length * Width DESC, Width DESC;
    OPEN parts;
    FETCH NEXT FROM parts INTO @PartID;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        WHILE 1 = 1
        BEGIN
            /* every anchor where this part fits: all its cells free and the same colour */
            TRUNCATE TABLE #Cand;
            INSERT #Cand (Y, X, Z, SizeX, SizeZ, ColourID, Pri)
            SELECT a.Y, a.X, a.Z, o.SizeX, o.SizeZ, a.ColourID,
                   ROW_NUMBER() OVER (PARTITION BY a.Y ORDER BY
                       IIF(IIF(o.SizeX >= o.SizeZ, 0, 1) = a.Y % 2, 0, 1),    -- preferred direction first
                       IIF(a.Y % 2 = 0, a.Z, a.X), IIF(a.Y % 2 = 0, a.X, a.Z)) -- then scan order
            FROM #Free AS a
            CROSS APPLY (SELECT DISTINCT SizeX, SizeZ
                         FROM lego.Part AS p
                         CROSS APPLY (VALUES (p.Length, p.Width), (p.Width, p.Length)) AS v(SizeX, SizeZ)
                         WHERE p.PartID = @PartID) AS o
            WHERE (SELECT COUNT(*)
                   FROM #Free AS c
                   WHERE c.Y = a.Y
                     AND c.X BETWEEN a.X AND a.X + o.SizeX - 1
                     AND c.Z BETWEEN a.Z AND a.Z + o.SizeZ - 1
                     AND c.ColourID = a.ColourID) = o.SizeX * o.SizeZ;
            IF @@ROWCOUNT = 0 BREAK;
            SET @Rounds += 1;

            /* keep the candidates that no better-ranked candidate overlaps */
            TRUNCATE TABLE #New;
            INSERT lego.Brick (ModelID, PartID, ColourID, X, Y, Z, SizeX, SizeZ)
            OUTPUT inserted.Y, inserted.X, inserted.Z, inserted.SizeX, inserted.SizeZ INTO #New
            SELECT @ModelID, @PartID, c.ColourID, c.X, c.Y, c.Z, c.SizeX, c.SizeZ
            FROM #Cand AS c
            WHERE NOT EXISTS (SELECT 1
                              FROM #Cand AS o
                              WHERE o.Y = c.Y AND o.Pri < c.Pri
                                AND o.X < c.X + c.SizeX AND c.X < o.X + o.SizeX
                                AND o.Z < c.Z + c.SizeZ AND c.Z < o.Z + o.SizeZ);

            DELETE f
            FROM #Free AS f
            JOIN #New  AS n ON n.Y = f.Y
                           AND f.X BETWEEN n.X AND n.X + n.SizeX - 1
                           AND f.Z BETWEEN n.Z AND n.Z + n.SizeZ - 1;
        END;
        FETCH NEXT FROM parts INTO @PartID;
    END;
    CLOSE parts; DEALLOCATE parts;

    SELECT Rounds = @Rounds,
           Bricks = (SELECT COUNT(*) FROM lego.Brick WHERE ModelID = @ModelID),
           Studs  = (SELECT SUM(SizeX * SizeZ) FROM lego.Brick WHERE ModelID = @ModelID);
END;
GO

/* The shopping list */
CREATE OR ALTER VIEW lego.PartsList
AS
SELECT b.ModelID, b.PartID, p.Name AS Part, c.Name AS Colour, b.ColourID, Qty = COUNT(*)
FROM lego.Brick  AS b
JOIN lego.Part   AS p ON p.PartID   = b.PartID
JOIN lego.Colour AS c ON c.ColourID = b.ColourID
GROUP BY b.ModelID, b.PartID, p.Name, c.Name, b.ColourID;
GO
