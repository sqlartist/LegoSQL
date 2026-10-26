/*  07_Brain.sql  --  grow a Lego brain inside the Lego head
    --------------------------------------------------------
    The head is hollow (that's the onion peel), which on video makes it look like I have
    no brain. So: three shapes, placed relative to the head's own bounding box so they
    work at any scale, clipped to the inside of the skull with a one-brick gap
      * the cerebrum   - an ellipsoid
      * the cerebellum - a smaller ellipsoid, low at the back
      * the brain stem - a cylinder that carries on down the neck as the spinal cord
    Then the folds: wherever a wiggly 3D wave crosses zero, the surface brick is removed,
    leaving a groove with a darker floor. And a slot down the middle for the two halves.
*/
USE LegoSQL;
GO
/* Brain colours. InPalette = 0, so they're never picked when colouring skin */
MERGE lego.Colour AS t
USING (VALUES (13,  'Pink',             'F6A9BB'),
              (351, 'Medium Dark Pink', 'F785B1'),
              (5,   'Dark Pink',        'D3359D'),
              (77,  'Light Pink',       'FECCCF')) AS s (ColourID, Name, Hex)
   ON t.ColourID = s.ColourID
WHEN NOT MATCHED THEN INSERT (ColourID, Name, Hex, InPalette) VALUES (s.ColourID, s.Name, s.Hex, 0);

UPDATE c SET Lab = x.Lab
FROM lego.Colour AS c
CROSS APPLY lego.RgbToLab(c.R, c.G, c.B) AS x
WHERE c.Lab IS NULL;
GO

/* Three sine waves, each wobbled by another: a cheap, organic-looking 3D pattern */
CREATE OR ALTER FUNCTION lego.BrainWave (@X float, @Y float, @Z float, @Scale float, @k float)
RETURNS float
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @px float = @X * 8.0 / @Scale, @py float = @Y * 9.6 / @Scale, @pz float = @Z * 8.0 / @Scale;
    RETURN SIN(@k * @px + 1.7 * SIN(0.6 * @k * @pz))
         + SIN(@k * @pz + 1.7 * SIN(0.6 * @k * @py))
         + SIN(@k * @py + 1.7 * SIN(0.6 * @k * @px));
END;
GO

CREATE OR ALTER PROCEDURE lego.GrowBrain
    @HeadModelID   int,
    @Name          nvarchar(100) = N'Brain',
    @Gap           int   = 1,        -- empty bricks between skull and brain (cerebrospinal fluid)
    @Fold          float = 36.0,     -- life-size mm per wave: sets the size of the folds
    @BrainModelID  int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @x0 float, @x1 float, @y0 float, @y1 float, @z0 float, @z1 float, @Scale float;
    SELECT @x0 = MIN(X), @x1 = MAX(X), @y0 = MIN(Y), @y1 = MAX(Y), @z0 = MIN(Z), @z1 = MAX(Z)
    FROM lego.Voxel WHERE ModelID = @HeadModelID;
    SELECT @Scale = Scale FROM lego.Model WHERE ModelID = @HeadModelID;

    INSERT lego.Model (Name, MeshID, Scale, MmPerUnit, OriginX, OriginY, OriginZ)
    SELECT @Name, MeshID, Scale, MmPerUnit, OriginX, OriginY, OriginZ
    FROM lego.Model WHERE ModelID = @HeadModelID;
    SET @BrainModelID = SCOPE_IDENTITY();

    /* 1. The shapes, in head-relative coordinates: u across, v up, w front (0..1 over the head) */
    DROP TABLE IF EXISTS #Brain;
    SELECT h.X, h.Y, h.Z, s.Part
    INTO #Brain
    FROM lego.Voxel AS h
    CROSS APPLY (SELECT u = (h.X - @x0) / (@x1 - @x0),
                        v = (h.Y - @y0) / (@y1 - @y0),
                        w = (h.Z - @z0) / (@z1 - @z0)) AS p
    CROSS APPLY (SELECT Part = CASE
        WHEN SQUARE((p.u - 0.50) / 0.41) + SQUARE((p.v - 0.74) / 0.19) + SQUARE((p.w - 0.45) / 0.38) <= 1 THEN 'cerebrum'
        WHEN SQUARE((p.u - 0.50) / 0.27) + SQUARE((p.v - 0.57) / 0.08) + SQUARE((p.w - 0.17) / 0.12) <= 1 THEN 'cerebellum'
        WHEN SQUARE((p.u - 0.50) / 0.07) + SQUARE((p.w - 0.29) / 0.05) <= 1 AND p.v BETWEEN 0.07 AND 0.62 THEN 'stem'
        END) AS s
    WHERE h.ModelID = @HeadModelID
      AND h.Depth > 2 + @Gap                  -- inside the 2-brick skull, plus the gap
      AND s.Part IS NOT NULL;

    INSERT lego.Voxel (ModelID, X, Y, Z) SELECT @BrainModelID, X, Y, Z FROM #Brain;
    EXEC lego.PeelModel @BrainModelID;

    /* 2. The folds: a wiggly 3D wave, and a groove wherever it crosses zero. "Crosses zero"
          means it's positive here and negative next door, which always gives an unbroken
          line one brick wide. Positions in life-size mm, so the folds are the same at any scale. */
    DECLARE @k float = 2 * PI() / @Fold;
    DELETE v
    FROM lego.Voxel AS v
    JOIN #Brain AS b ON b.X = v.X AND b.Y = v.Y AND b.Z = v.Z AND b.Part <> 'stem'
    CROSS APPLY (SELECT f = lego.BrainWave(v.X, v.Y, v.Z, @Scale, @k)) AS here
    WHERE v.ModelID = @BrainModelID
      AND v.Depth = 1
      AND here.f >= 0
      AND EXISTS (SELECT 1
                  FROM (VALUES (1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)) AS d(dx, dy, dz)
                  WHERE lego.BrainWave(v.X + d.dx, v.Y + d.dy, v.Z + d.dz, @Scale, @k) < 0);

    /* ...and the slot between the two halves, down the middle of the top */
    DELETE v
    FROM lego.Voxel AS v
    JOIN #Brain AS b ON b.X = v.X AND b.Y = v.Y AND b.Z = v.Z AND b.Part = 'cerebrum'
    WHERE v.ModelID = @BrainModelID
      AND v.X = ROUND((@x0 + @x1) / 2, 0)
      AND v.Depth <= 2
      AND (v.Y - @y0) / (@y1 - @y0) >= 0.70;

    /* 3. Colour: pink, with dark pink groove floors (a Depth 2 brick that can now see daylight),
          and a paler brain stem                                                            */
    UPDATE v SET ColourID = IIF(b.Part = 'stem', 77, 13)
    FROM lego.Voxel AS v
    JOIN #Brain AS b ON b.X = v.X AND b.Y = v.Y AND b.Z = v.Z
    WHERE v.ModelID = @BrainModelID;

    UPDATE v SET ColourID = 5
    FROM lego.Voxel AS v
    WHERE v.ModelID = @BrainModelID
      AND v.Depth = 2
      AND v.ColourID = 13
      AND EXISTS (SELECT 1
                  FROM (VALUES (1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)) AS d(dx, dy, dz)
                  WHERE NOT EXISTS (SELECT 1 FROM lego.Voxel AS n
                                    WHERE n.ModelID = v.ModelID
                                      AND n.X = v.X + d.dx AND n.Y = v.Y + d.dy AND n.Z = v.Z + d.dz));

    SELECT b.Part, Voxels = COUNT(*), Surface = SUM(IIF(v.Depth <= 2, 1, 0))
    FROM lego.Voxel AS v
    JOIN #Brain AS b ON b.X = v.X AND b.Y = v.Y AND b.Z = v.Z
    WHERE v.ModelID = @BrainModelID
    GROUP BY b.Part;
END;
GO
