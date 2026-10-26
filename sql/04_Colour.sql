/*  04_Colour.sql  --  paint the voxels from the mesh's texture image
    -----------------------------------------------------------------
    SQL Server can't decode a JPEG or PNG, but a 24-bit BMP is just a 54-byte header
    and then raw pixels, bottom row first, 3 bytes each in the order Blue, Green, Red
    (each row padded to a multiple of 4 bytes). So OPENROWSET(... SINGLE_BLOB) plus
    SUBSTRING is a perfectly good image decoder.

    Then, for every triangle of the mesh:
      * its centre's texture coordinate (u, v) picks a pixel   -> a colour
      * its centre's position picks a grid cell                -> a voxel
      * its area is the weight
    Each surface voxel's colour is the area-weighted average (in Lab) of the triangles
    that land on it, snapped to the nearest real Lego colour with VECTOR_DISTANCE
    ('average'), or the Lego colour that covers most of its area ('dominant').
*/
USE LegoSQL;
GO
CREATE OR ALTER PROCEDURE obj.ImportTexture
    @MeshID  int,
    @Path    nvarchar(400)       -- a 24-bit .bmp
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bmp varbinary(max);
    DECLARE @sql nvarchar(max) =
        N'SELECT @bmp = BulkColumn FROM OPENROWSET(BULK ' + QUOTENAME(@Path, '''') + N', SINGLE_BLOB) AS f;';
    EXEC sys.sp_executesql @sql, N'@bmp varbinary(max) OUTPUT', @bmp = @bmp OUTPUT;

    /* Header fields are little-endian: byte0 + byte1*256 + byte2*65536 + ... */
    DECLARE @Offset int, @W int, @H int, @Bits int;
    WITH Field AS
    (
        SELECT f.Name, Val = SUM(CAST(SUBSTRING(@bmp, f.Pos + n.value, 1) AS int) * POWER(256, n.value))
        FROM (VALUES ('Offset', 11, 4), ('Width', 19, 4), ('Height', 23, 4), ('Bits', 29, 2)) AS f(Name, Pos, Len)
        JOIN GENERATE_SERIES(0, 3) AS n ON n.value < f.Len
        GROUP BY f.Name
    )
    SELECT @Offset = MAX(IIF(Name = 'Offset', Val, 0)),
           @W      = MAX(IIF(Name = 'Width',  Val, 0)),
           @H      = MAX(IIF(Name = 'Height', Val, 0)),
           @Bits   = MAX(IIF(Name = 'Bits',   Val, 0))
    FROM Field;

    IF SUBSTRING(@bmp, 1, 2) <> 0x424D OR @Bits <> 24 OR @H <= 0
        THROW 50001, 'Expected a bottom-up 24-bit BMP.', 1;

    DECLARE @Stride int = (@W * 3 + 3) / 4 * 4;      -- each row is padded to 4 bytes

    DELETE obj.Texel   WHERE MeshID = @MeshID;
    DELETE obj.Texture WHERE MeshID = @MeshID;
    INSERT obj.Texture (MeshID, SourceFile, Width, Height, Bmp) VALUES (@MeshID, @Path, @W, @H, @bmp);

    INSERT obj.Texel (MeshID, PX, PY, R, G, B)
    SELECT @MeshID, p.PX, p.PY,
           CAST(SUBSTRING(@bmp, p.Byte0 + 3, 1) AS tinyint),     -- stored B, G, R
           CAST(SUBSTRING(@bmp, p.Byte0 + 2, 1) AS tinyint),
           CAST(SUBSTRING(@bmp, p.Byte0 + 1, 1) AS tinyint)
    FROM GENERATE_SERIES(0, @W * @H - 1) AS g
    CROSS APPLY (SELECT PX = g.value % @W, PY = g.value / @W) AS xy
    CROSS APPLY (SELECT xy.PX, xy.PY, Byte0 = @Offset + xy.PY * @Stride + xy.PX * 3) AS p;

    SELECT Width = @W, Height = @H, Texels = @@ROWCOUNT;
END;
GO

CREATE OR ALTER PROCEDURE lego.ColourModel
    @ModelID   int,
    @Method    varchar(10) = 'average',   -- or 'dominant'
    @Exposure  float = 1.0                -- scales Lab lightness: the scan's shadows are baked in
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @MeshID int, @mm float, @OX float, @OY float, @OZ float, @W int, @H int;
    SELECT @MeshID = m.MeshID, @mm = m.MmPerUnit, @OX = m.OriginX, @OY = m.OriginY, @OZ = m.OriginZ,
           @W = t.Width, @H = t.Height
    FROM lego.Model AS m
    JOIN obj.Texture AS t ON t.MeshID = m.MeshID
    WHERE m.ModelID = @ModelID;

    /* 1. One colour sample per triangle: the texel under its centre, weighted by its area.
          Positions are in grid units (studs / layers) so FLOOR() gives the cell.          */
    DROP TABLE IF EXISTS #Sample;
    SELECT s.CellX, s.CellY, s.CellZ, s.PX_, s.PY_, s.PZ_, s.Area, e.L, lab.a, lab.b,
           Lab = CAST(JSON_ARRAY(e.L, lab.a, lab.b) AS vector(3)),
           ColourID = CAST(NULL AS int)
    INTO #Sample
    FROM obj.Face AS f
    JOIN obj.Vertex   AS v1 ON v1.MeshID = f.MeshID AND v1.VertexID   = f.V1
    JOIN obj.Vertex   AS v2 ON v2.MeshID = f.MeshID AND v2.VertexID   = f.V2
    JOIN obj.Vertex   AS v3 ON v3.MeshID = f.MeshID AND v3.VertexID   = f.V3
    JOIN obj.TexCoord AS t1 ON t1.MeshID = f.MeshID AND t1.TexCoordID = f.T1
    JOIN obj.TexCoord AS t2 ON t2.MeshID = f.MeshID AND t2.TexCoordID = f.T2
    JOIN obj.TexCoord AS t3 ON t3.MeshID = f.MeshID AND t3.TexCoordID = f.T3
    CROSS APPLY (SELECT cx = (v1.X + v2.X + v3.X) / 3 * @mm,                -- centre, in mm
                        cy = (v1.Y + v2.Y + v3.Y) / 3 * @mm,
                        cz = (v1.Z + v2.Z + v3.Z) / 3 * @mm,
                        u  = (t1.U + t2.U + t3.U) / 3,                      -- centre, on the image
                        v  = (t1.V + t2.V + t3.V) / 3,
                        -- half the length of the cross product of two edges = the area (mm^2)
                        e1x = (v2.X - v1.X) * @mm, e1y = (v2.Y - v1.Y) * @mm, e1z = (v2.Z - v1.Z) * @mm,
                        e2x = (v3.X - v1.X) * @mm, e2y = (v3.Y - v1.Y) * @mm, e2z = (v3.Z - v1.Z) * @mm) AS c
    CROSS APPLY (SELECT PX_  = (c.cx - @OX) / 8.0,
                        PY_  = (c.cy - @OY) / 9.6,
                        PZ_  = (c.cz - @OZ) / 8.0,
                        CellX = CAST(FLOOR((c.cx - @OX) / 8.0) AS int),
                        CellY = CAST(FLOOR((c.cy - @OY) / 9.6) AS int),
                        CellZ = CAST(FLOOR((c.cz - @OZ) / 8.0) AS int),
                        TexX  = CAST(FLOOR((c.u - FLOOR(c.u)) * @W) AS int),   -- wrap u, v into 0..1
                        TexY  = CAST(FLOOR((c.v - FLOOR(c.v)) * @H) AS int),
                        Area  = 0.5 * SQRT(SQUARE(c.e1y * c.e2z - c.e1z * c.e2y)
                                         + SQUARE(c.e1z * c.e2x - c.e1x * c.e2z)
                                         + SQUARE(c.e1x * c.e2y - c.e1y * c.e2x))) AS s
    JOIN obj.Texel AS px ON px.MeshID = f.MeshID AND px.PX = s.TexX AND px.PY = s.TexY
    CROSS APPLY lego.RgbToLab(px.R, px.G, px.B) AS lab
    CROSS APPLY (SELECT L = LEAST(100e0, lab.L * @Exposure)) AS e
    WHERE f.MeshID = @MeshID;

    /* 2. Pool the samples by grid cell, and find where each cell's bit of surface sits */
    DROP TABLE IF EXISTS #Cell;
    SELECT CellX, CellY, CellZ,
           PX_ = SUM(Area * PX_) / SUM(Area), PY_ = SUM(Area * PY_) / SUM(Area), PZ_ = SUM(Area * PZ_) / SUM(Area)
    INTO #Cell
    FROM #Sample
    WHERE Area > 0
    GROUP BY CellX, CellY, CellZ;

    /* 3. The surface runs between voxel centres, so a cell's samples may belong to the
          voxel next door: hand each cell to the nearest surface voxel among its 27.       */
    DROP TABLE IF EXISTS #CellVoxel;
    SELECT c.CellX, c.CellY, c.CellZ, nv.X, nv.Y, nv.Z
    INTO #CellVoxel
    FROM #Cell AS c
    CROSS APPLY (SELECT TOP (1) v.X, v.Y, v.Z
                 FROM GENERATE_SERIES(-1, 1) AS dx
                 CROSS JOIN GENERATE_SERIES(-1, 1) AS dy
                 CROSS JOIN GENERATE_SERIES(-1, 1) AS dz
                 JOIN lego.Voxel AS v
                   ON v.ModelID = @ModelID
                  AND v.X = c.CellX + dx.value AND v.Y = c.CellY + dy.value AND v.Z = c.CellZ + dz.value
                 WHERE v.Depth = 1
                 ORDER BY SQUARE((v.X + 0.5 - c.PX_) * 8.0) + SQUARE((v.Y + 0.5 - c.PY_) * 9.6)
                        + SQUARE((v.Z + 0.5 - c.PZ_) * 8.0)) AS nv;

    UPDATE lego.Voxel SET ColourID = NULL WHERE ModelID = @ModelID;

    IF @Method = 'average'
    BEGIN
        /* 4a. Average the colour over the voxel (in Lab), then snap to the nearest Lego colour.
               Smooth, but stubble + skin averages to a muddy in-between colour.            */
        WITH VoxelLab AS
        (
            SELECT cv.X, cv.Y, cv.Z,
                   Lab = CAST(JSON_ARRAY(SUM(s.Area * s.L) / SUM(s.Area),
                                         SUM(s.Area * s.a) / SUM(s.Area),
                                         SUM(s.Area * s.b) / SUM(s.Area)) AS vector(3))
            FROM #Sample AS s
            JOIN #CellVoxel AS cv ON cv.CellX = s.CellX AND cv.CellY = s.CellY AND cv.CellZ = s.CellZ
            WHERE s.Area > 0
            GROUP BY cv.X, cv.Y, cv.Z
        )
        UPDATE v
        SET ColourID = best.ColourID
        FROM lego.Voxel AS v
        JOIN VoxelLab AS vl ON vl.X = v.X AND vl.Y = v.Y AND vl.Z = v.Z
        CROSS APPLY (SELECT TOP (1) c.ColourID
                     FROM lego.Colour AS c
                     WHERE c.InPalette = 1
                     ORDER BY VECTOR_DISTANCE('euclidean', c.Lab, vl.Lab)) AS best
        WHERE v.ModelID = @ModelID;
    END
    ELSE
    BEGIN
        /* 4b. Snap every sample to its nearest Lego colour first, then let the colours vote,
               weighted by area. Each brick is whatever covers most of it: crisper edges.  */
        UPDATE s
        SET ColourID = best.ColourID
        FROM #Sample AS s
        CROSS APPLY (SELECT TOP (1) c.ColourID
                     FROM lego.Colour AS c
                     WHERE c.InPalette = 1
                     ORDER BY VECTOR_DISTANCE('euclidean', c.Lab, s.Lab)) AS best;

        WITH Vote AS
        (
            SELECT cv.X, cv.Y, cv.Z, s.ColourID,
                   Pick = ROW_NUMBER() OVER (PARTITION BY cv.X, cv.Y, cv.Z ORDER BY SUM(s.Area) DESC, s.ColourID)
            FROM #Sample AS s
            JOIN #CellVoxel AS cv ON cv.CellX = s.CellX AND cv.CellY = s.CellY AND cv.CellZ = s.CellZ
            WHERE s.Area > 0
            GROUP BY cv.X, cv.Y, cv.Z, s.ColourID
        )
        UPDATE v
        SET ColourID = vt.ColourID
        FROM lego.Voxel AS v
        JOIN Vote AS vt ON vt.X = v.X AND vt.Y = v.Y AND vt.Z = v.Z AND vt.Pick = 1
        WHERE v.ModelID = @ModelID;
    END;

    /* 5. Voxels no triangle landed on (and the hidden ones inside) copy a coloured
          neighbour, shallowest first, one layer of the onion at a time.               */
    DECLARE @n int = 1;
    WHILE @n > 0
    BEGIN
        UPDATE v
        SET ColourID = nb.ColourID
        FROM lego.Voxel AS v
        CROSS APPLY (SELECT TOP (1) n.ColourID
                     FROM (VALUES (1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)) AS d(dx, dy, dz)
                     JOIN lego.Voxel AS n
                       ON n.ModelID = v.ModelID
                      AND n.X = v.X + d.dx AND n.Y = v.Y + d.dy AND n.Z = v.Z + d.dz
                     WHERE n.ColourID IS NOT NULL
                     ORDER BY n.Depth, d.dy, d.dx, d.dz) AS nb
        WHERE v.ModelID = @ModelID AND v.ColourID IS NULL;
        SET @n = @@ROWCOUNT;
    END;

    SELECT c.Name, c.ColourID, SurfaceVoxels = COUNT(*)
    FROM lego.Voxel AS v
    JOIN lego.Colour AS c ON c.ColourID = v.ColourID
    WHERE v.ModelID = @ModelID AND v.Depth = 1
    GROUP BY c.Name, c.ColourID
    ORDER BY COUNT(*) DESC;
END;
GO
