/*  02_ImportObj.sql  --  read a Wavefront OBJ file straight into obj.Vertex / obj.Face
    ---------------------------------------------------------------------------------
    An OBJ file is plain text:
        v  -0.089426 0.033380 -0.017880        <- a vertex
        vt 0.074025 0.377586                   <- a texture coordinate (u, v on the image)
        f  1/1/1 2/2/2 3/3/3                   <- a face: vertex/texcoord/normal indexes
    Faces refer to vertices by their position in the file (1st "v" line = 1), so line
    order matters. STRING_SPLIT's enable_ordinal argument gives us that order;
    BULK INSERT into a table does not promise it.
*/
USE LegoSQL;
GO
CREATE OR ALTER PROCEDURE obj.ImportObj
    @Path    nvarchar(400),
    @Name    nvarchar(100),
    @MeshID  int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    /* The whole file as one string (OPENROWSET needs a literal path, hence the dynamic SQL) */
    DECLARE @doc varchar(max);
    DECLARE @sql nvarchar(max) =
        N'SELECT @doc = BulkColumn FROM OPENROWSET(BULK ' + QUOTENAME(@Path, '''') + N', SINGLE_CLOB) AS f;';
    EXEC sys.sp_executesql @sql, N'@doc varchar(max) OUTPUT', @doc = @doc OUTPUT;
    SET @doc = REPLACE(@doc, CHAR(13), '');

    INSERT obj.Mesh (Name, SourceFile) VALUES (@Name, @Path);
    SET @MeshID = SCOPE_IDENTITY();

    /* One row per line we care about, numbered in file order */
    DROP TABLE IF EXISTS #Line;
    SELECT LineNum = s.ordinal, Line = s.value
    INTO #Line
    FROM STRING_SPLIT(@doc, CHAR(10), 1) AS s
    WHERE s.value LIKE 'v %' OR s.value LIKE 'vt %' OR s.value LIKE 'f %';

    /* Vertices: the nth "v" line is vertex n */
    INSERT obj.Vertex (MeshID, VertexID, X, Y, Z)
    SELECT @MeshID,
           ROW_NUMBER() OVER (ORDER BY l.LineNum),
           CAST(REGEXP_SUBSTR(l.Line, '\S+', 1, 2) AS float),
           CAST(REGEXP_SUBSTR(l.Line, '\S+', 1, 3) AS float),
           CAST(REGEXP_SUBSTR(l.Line, '\S+', 1, 4) AS float)
    FROM #Line AS l
    WHERE l.Line LIKE 'v %';

    /* Texture coordinates: the nth "vt" line is texcoord n */
    INSERT obj.TexCoord (MeshID, TexCoordID, U, V)
    SELECT @MeshID,
           ROW_NUMBER() OVER (ORDER BY l.LineNum),
           CAST(REGEXP_SUBSTR(l.Line, '\S+', 1, 2) AS float),
           CAST(REGEXP_SUBSTR(l.Line, '\S+', 1, 3) AS float)
    FROM #Line AS l
    WHERE l.Line LIKE 'vt %';

    /* Face corners: "12/40/12" -> vertex 12, texcoord 40; "12//7" and "12" have no texcoord.
       (Negative, i.e. relative, indexes are not handled.) */
    DROP TABLE IF EXISTS #Corner;
    SELECT FaceNo = f.FaceNo,
           k      = c.ordinal,
           V      = CAST(LEFT(c.value, CHARINDEX('/', c.value + '/') - 1) AS int),
           T      = CAST(REGEXP_SUBSTR(c.value, '^\d+/(\d+)', 1, 1, '', 1) AS int)
    INTO #Corner
    FROM (SELECT FaceNo = ROW_NUMBER() OVER (ORDER BY LineNum), Line
          FROM #Line WHERE Line LIKE 'f %') AS f
    CROSS APPLY STRING_SPLIT(TRIM(SUBSTRING(f.Line, 3, 8000)), ' ', 1) AS c
    WHERE c.value <> '';

    CREATE CLUSTERED INDEX CX ON #Corner (FaceNo, k);

    /* Triangles: a polygon with corners 1..n becomes the fan (1,2,3), (1,3,4), ... */
    INSERT obj.Face (MeshID, FaceID, V1, V2, V3, T1, T2, T3)
    SELECT @MeshID,
           ROW_NUMBER() OVER (ORDER BY a.FaceNo, b.k),
           a.V, b.V, c.V,
           a.T, b.T, c.T
    FROM #Corner AS a
    JOIN #Corner AS b ON b.FaceNo = a.FaceNo AND b.k >= 2
    JOIN #Corner AS c ON c.FaceNo = a.FaceNo AND c.k = b.k + 1
    WHERE a.k = 1;
END;
GO

/*  Is the mesh a closed surface?  Every edge of a watertight mesh is shared by exactly
    two triangles, and Euler's formula V - E + F = 2 holds for anything shaped like a
    sphere (a head, a duck, a Benchy without its hole...).                              */
CREATE OR ALTER VIEW obj.MeshHealth
AS
WITH Edge AS
(
    SELECT f.MeshID, A = LEAST(e.A, e.B), B = GREATEST(e.A, e.B)
    FROM obj.Face AS f
    CROSS APPLY (VALUES (f.V1, f.V2), (f.V2, f.V3), (f.V3, f.V1)) AS e(A, B)
),
EdgeUse AS
(
    SELECT MeshID, A, B, Uses = COUNT(*) FROM Edge GROUP BY MeshID, A, B
)
SELECT m.MeshID, m.Name,
       V = (SELECT COUNT(*) FROM obj.Vertex WHERE MeshID = m.MeshID),
       E = (SELECT COUNT(*) FROM EdgeUse WHERE MeshID = m.MeshID),
       F = (SELECT COUNT(*) FROM obj.Face WHERE MeshID = m.MeshID),
       BoundaryEdges    = (SELECT COUNT(*) FROM EdgeUse WHERE MeshID = m.MeshID AND Uses = 1),
       NonManifoldEdges = (SELECT COUNT(*) FROM EdgeUse WHERE MeshID = m.MeshID AND Uses > 2)
FROM obj.Mesh AS m;
GO
