/*  03_Voxelise.sql  --  turn a closed mesh into a grid of 1x1 Lego bricks
    ----------------------------------------------------------------------
    A 1x1 brick is 8 x 9.6 x 8 mm, not a cube, so the grid is too.

    The idea: fire a ray along X through the centre of every row of voxels. Each time
    the ray crosses the surface it goes inside -> outside -> inside..., so if we sort
    the crossings along the ray, the 1st-2nd, 3rd-4th, ... pairs bound the solid parts.
    Every voxel centre between a pair is a brick.

    Grid coordinates: voxel (i, j, k) has its centre at t = i, u = j, w = k, where
        t = (x - OriginX) / 8   - 0.5     (studs,  across the face)
        u = (y - OriginY) / 9.6 - 0.5     (layers, up)
        w = (z - OriginZ) / 8   - 0.5     (studs,  front-back; the face looks along +w)
*/
USE LegoSQL;
GO
/*  Onion-peel a model: Depth 1 = voxels with an empty face-neighbour, Depth 2 = touching a
    Depth 1, ... (a discrete distance transform). A hollow shell is then WHERE Depth <= 2.  */
CREATE OR ALTER PROCEDURE lego.PeelModel
    @ModelID int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE lego.Voxel SET Depth = NULL WHERE ModelID = @ModelID;

    DECLARE @d int = 1, @n int = 1;
    WHILE @n > 0
    BEGIN
        UPDATE v SET Depth = @d
        FROM lego.Voxel AS v
        WHERE v.ModelID = @ModelID
          AND v.Depth IS NULL
          AND EXISTS
          (
              SELECT 1
              FROM (VALUES (1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)) AS d(dx, dy, dz)
              OUTER APPLY (SELECT n.Depth, Found = 1
                           FROM lego.Voxel AS n
                           WHERE n.ModelID = v.ModelID
                             AND n.X = v.X + d.dx AND n.Y = v.Y + d.dy AND n.Z = v.Z + d.dz) AS nb
              WHERE (@d = 1 AND nb.Found IS NULL)            -- next to empty space
                 OR (@d > 1 AND nb.Depth = @d - 1)           -- next to the previous peel
          );
        SET @n = @@ROWCOUNT;
        SET @d += 1;
    END;
END;
GO

CREATE OR ALTER PROCEDURE lego.VoxeliseMesh
    @MeshID     int,
    @Name       nvarchar(100),
    @Scale      float = 1.0,       -- 1 = life size
    @UnitsToMm  float = 1000.0,    -- the OBJ is in metres
    @ModelID    int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @mm   float = @UnitsToMm * @Scale,
            @Stud float = 8.0,
            @Lay  float = 9.6;

    /* 1. Size the grid around the mesh, with the slack split evenly on each side */
    DECLARE @MinX float, @MinY float, @MinZ float, @MaxX float, @MaxY float, @MaxZ float;
    SELECT @MinX = MIN(X) * @mm, @MaxX = MAX(X) * @mm,
           @MinY = MIN(Y) * @mm, @MaxY = MAX(Y) * @mm,
           @MinZ = MIN(Z) * @mm, @MaxZ = MAX(Z) * @mm
    FROM obj.Vertex WHERE MeshID = @MeshID;

    DECLARE @NX int = CEILING((@MaxX - @MinX) / @Stud),
            @NY int = CEILING((@MaxY - @MinY) / @Lay),
            @NZ int = CEILING((@MaxZ - @MinZ) / @Stud);

    INSERT lego.Model (Name, MeshID, Scale, MmPerUnit, OriginX, OriginY, OriginZ)
    VALUES (@Name, @MeshID, @Scale, @mm,
            @MinX - (@NX * @Stud - (@MaxX - @MinX)) / 2,
            @MinY - (@NY * @Lay  - (@MaxY - @MinY)) / 2,
            @MinZ - (@NZ * @Stud - (@MaxZ - @MinZ)) / 2);
    SET @ModelID = SCOPE_IDENTITY();

    DECLARE @OX float, @OY float, @OZ float;
    SELECT @OX = OriginX, @OY = OriginY, @OZ = OriginZ FROM lego.Model WHERE ModelID = @ModelID;

    /* 2. Every triangle in grid coordinates. The rays are nudged a hair off the exact
          grid so one can never run exactly through a vertex or along an edge, where it
          would be counted twice (or not at all).                                      */
    DECLARE @NudgeU float = 0.000137, @NudgeW float = 0.000071;

    DROP TABLE IF EXISTS #Tri;
    SELECT f.FaceID,
           t1 = (a.X * @mm - @OX) / @Stud - 0.5, u1 = (a.Y * @mm - @OY) / @Lay - 0.5 - @NudgeU, w1 = (a.Z * @mm - @OZ) / @Stud - 0.5 - @NudgeW,
           t2 = (b.X * @mm - @OX) / @Stud - 0.5, u2 = (b.Y * @mm - @OY) / @Lay - 0.5 - @NudgeU, w2 = (b.Z * @mm - @OZ) / @Stud - 0.5 - @NudgeW,
           t3 = (c.X * @mm - @OX) / @Stud - 0.5, u3 = (c.Y * @mm - @OY) / @Lay - 0.5 - @NudgeU, w3 = (c.Z * @mm - @OZ) / @Stud - 0.5 - @NudgeW
    INTO #Tri
    FROM obj.Face   AS f
    JOIN obj.Vertex AS a ON a.MeshID = f.MeshID AND a.VertexID = f.V1
    JOIN obj.Vertex AS b ON b.MeshID = f.MeshID AND b.VertexID = f.V2
    JOIN obj.Vertex AS c ON c.MeshID = f.MeshID AND c.VertexID = f.V3
    WHERE f.MeshID = @MeshID;

    /* 3. Which rays can each triangle hit? Only those whose (u, w) falls inside the
          triangle's bounding box. Triangles are ~1 mm across and rays 8-10 mm apart,
          so most triangles have none.                                                */
    DROP TABLE IF EXISTS #Hit;
    WITH Box AS
    (
        SELECT *,
               j0 = CAST(CEILING(LEAST(u1, u2, u3))    AS int),
               j1 = CAST(FLOOR(GREATEST(u1, u2, u3))   AS int),
               k0 = CAST(CEILING(LEAST(w1, w2, w3))    AS int),
               k1 = CAST(FLOOR(GREATEST(w1, w2, w3))   AS int),
               Area2 = (u2 - u1) * (w3 - w1) - (u3 - u1) * (w2 - w1)   -- twice the signed area in (u, w)
        FROM #Tri
    ),
    Candidate AS
    (
        SELECT b.*, j = gj.value, k = gk.value
        FROM Box AS b
        CROSS APPLY GENERATE_SERIES(b.j0, b.j1, 1) AS gj
        CROSS APPLY GENERATE_SERIES(b.k0, b.k1, 1) AS gk
        WHERE b.j0 <= b.j1 AND b.k0 <= b.k1
          AND b.Area2 <> 0                       -- edge-on to the ray: can't be crossed
    ),
    Bary AS      -- barycentric weights of the ray point (j, k) in the triangle
    (
        SELECT c.j, c.k, c.t1, c.t2, c.t3,
               l1 = ((c.u2 - c.j) * (c.w3 - c.k) - (c.u3 - c.j) * (c.w2 - c.k)) / c.Area2,
               l2 = ((c.u3 - c.j) * (c.w1 - c.k) - (c.u1 - c.j) * (c.w3 - c.k)) / c.Area2
        FROM Candidate AS c
    )
    SELECT j, k, t = l1 * t1 + l2 * t2 + (1 - l1 - l2) * t3     -- where along the ray it crosses
    INTO #Hit
    FROM Bary
    WHERE l1 >= 0 AND l2 >= 0 AND l1 + l2 <= 1;

    /* 4. Pair the crossings along each ray and fill the voxels in between */
    WITH Ray AS
    (
        SELECT j, k, t,
               n    = ROW_NUMBER() OVER (PARTITION BY j, k ORDER BY t),
               tOut = LEAD(t)      OVER (PARTITION BY j, k ORDER BY t),
               Hits = COUNT(*)     OVER (PARTITION BY j, k)
        FROM #Hit
    )
    INSERT lego.Voxel (ModelID, X, Y, Z)
    SELECT @ModelID, i.value, r.j, r.k
    FROM Ray AS r
    CROSS APPLY GENERATE_SERIES(CAST(CEILING(r.t) AS int), CAST(FLOOR(r.tOut) AS int), 1) AS i
    WHERE r.n % 2 = 1                -- entering the solid
      AND r.Hits % 2 = 0             -- a ray that leaks through a hole in the mesh is skipped
      AND CEILING(r.t) <= FLOOR(r.tOut);

    SELECT Rays          = COUNT(DISTINCT CONCAT(j, ',', k)),
           Crossings     = COUNT(*),
           OddRays       = (SELECT COUNT(*) FROM (SELECT j, k FROM #Hit GROUP BY j, k HAVING COUNT(*) % 2 = 1) AS o)
    FROM #Hit;

    /* 5. Onion-peel the solid (see lego.PeelModel) */
    EXEC lego.PeelModel @ModelID;
END;
GO
