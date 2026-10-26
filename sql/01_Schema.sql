/*  01_Schema.sql  --  LegoSQL: tables for a mesh, a voxel grid and a brick build
    ---------------------------------------------------------------------------
    Units
      * obj.*   : whatever the OBJ file uses (metres for most scanners / Blender)
      * lego.*  : integers. X and Z in studs (8 mm), Y in brick layers (9.6 mm).
                  Y is up, the face looks along +Z (same as the OBJ).
*/
USE LegoSQL;
GO
IF SCHEMA_ID('obj')  IS NULL EXEC ('CREATE SCHEMA obj');
IF SCHEMA_ID('lego') IS NULL EXEC ('CREATE SCHEMA lego');
GO

DROP TABLE IF EXISTS lego.VideoScript, lego.Brick, lego.Voxel, lego.Model, lego.Part, lego.Colour;
DROP TABLE IF EXISTS obj.Texel, obj.Texture, obj.Face, obj.TexCoord, obj.Vertex, obj.Mesh;
DROP FUNCTION IF EXISTS lego.RgbToLab;
GO

/* ---------- the raw mesh ---------- */

CREATE TABLE obj.Mesh
(
    MeshID      int IDENTITY PRIMARY KEY,
    Name        nvarchar(100) NOT NULL,
    SourceFile  nvarchar(400) NOT NULL,
    LoadedAt    datetime2(0)  NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE obj.Vertex
(
    MeshID    int   NOT NULL REFERENCES obj.Mesh,
    VertexID  int   NOT NULL,      -- 1-based, in file order: faces point at this
    X float NOT NULL, Y float NOT NULL, Z float NOT NULL,
    CONSTRAINT PK_Vertex PRIMARY KEY (MeshID, VertexID)
);

CREATE TABLE obj.TexCoord               -- "vt" lines: where on the texture image a corner sits
(
    MeshID      int   NOT NULL REFERENCES obj.Mesh,
    TexCoordID  int   NOT NULL,         -- 1-based, in file order
    U float NOT NULL, V float NOT NULL, -- 0..1, V measured UP from the bottom of the image
    CONSTRAINT PK_TexCoord PRIMARY KEY (MeshID, TexCoordID)
);

CREATE TABLE obj.Face                  -- always triangles (polygons are fanned)
(
    MeshID  int NOT NULL REFERENCES obj.Mesh,
    FaceID  int NOT NULL,
    V1 int NOT NULL, V2 int NOT NULL, V3 int NOT NULL,     -- vertices
    T1 int NULL,     T2 int NULL,     T3 int NULL,         -- texture coordinates, if any
    CONSTRAINT PK_Face PRIMARY KEY (MeshID, FaceID)
);

/* The colour ("base color" / diffuse) image, as a 24-bit BMP, and one row per pixel */
CREATE TABLE obj.Texture
(
    MeshID      int            NOT NULL PRIMARY KEY REFERENCES obj.Mesh,
    SourceFile  nvarchar(400)  NOT NULL,
    Width       int            NOT NULL,
    Height      int            NOT NULL,
    Bmp         varbinary(max) NOT NULL
);

CREATE TABLE obj.Texel
(
    MeshID  int      NOT NULL REFERENCES obj.Mesh,
    PX      smallint NOT NULL,         -- 0 = left
    PY      smallint NOT NULL,         -- 0 = BOTTOM row (BMPs and UVs both count up)
    R tinyint NOT NULL, G tinyint NOT NULL, B tinyint NOT NULL,
    CONSTRAINT PK_Texel PRIMARY KEY (MeshID, PY, PX)
);

/* ---------- Lego reference data ---------- */
GO
/*  sRGB (0-255) -> CIELAB (D65).  Distances in Lab roughly match how different two
    colours *look*, which RGB distances do not.  Returned as a VECTOR(3) so the
    nearest Lego colour is just VECTOR_DISTANCE('euclidean', ...).                  */
CREATE FUNCTION lego.RgbToLab (@R int, @G int, @B int)
RETURNS TABLE
AS RETURN
WITH Lin AS          -- undo the sRGB gamma curve
(
    SELECT r = IIF(c.r <= 0.04045, c.r / 12.92, POWER((c.r + 0.055) / 1.055, 2.4)),
           g = IIF(c.g <= 0.04045, c.g / 12.92, POWER((c.g + 0.055) / 1.055, 2.4)),
           b = IIF(c.b <= 0.04045, c.b / 12.92, POWER((c.b + 0.055) / 1.055, 2.4))
    FROM (SELECT r = @R / 255e0, g = @G / 255e0, b = @B / 255e0) AS c
),
XYZ AS               -- linear RGB -> XYZ, divided by the D65 white point
(
    SELECT x = (0.4124564e0 * r + 0.3575761e0 * g + 0.1804375e0 * b) / 0.95047e0,
           y = (0.2126729e0 * r + 0.7151522e0 * g + 0.0721750e0 * b),
           z = (0.0193339e0 * r + 0.1191920e0 * g + 0.9503041e0 * b) / 1.08883e0
    FROM Lin
),
F AS                 -- the Lab companding function: cube root, linear near black
(
    SELECT fx = IIF(x > 216e0/24389, POWER(x, 1e0/3), (24389e0/27 * x + 16) / 116),
           fy = IIF(y > 216e0/24389, POWER(y, 1e0/3), (24389e0/27 * y + 16) / 116),
           fz = IIF(z > 216e0/24389, POWER(z, 1e0/3), (24389e0/27 * z + 16) / 116)
    FROM XYZ
)
SELECT L = 116 * fy - 16,
       a = 500 * (fx - fy),
       b = 200 * (fy - fz),
       Lab = CAST(JSON_ARRAY(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)) AS vector(3))
FROM F;
GO

CREATE TABLE lego.Colour
(
    ColourID  int          NOT NULL PRIMARY KEY,   -- LDraw colour code
    Name      varchar(40)  NOT NULL,
    Hex       char(6)      NOT NULL,                -- LDraw LDConfig.ldr VALUE
    R AS CONVERT(int, CONVERT(binary(1), SUBSTRING(Hex, 1, 2), 2)),
    G AS CONVERT(int, CONVERT(binary(1), SUBSTRING(Hex, 3, 2), 2)),
    B AS CONVERT(int, CONVERT(binary(1), SUBSTRING(Hex, 5, 2), 2)),
    Lab       vector(3)    NULL,
    InPalette bit          NOT NULL DEFAULT 1       -- 0 = never use this colour
);

INSERT lego.Colour (ColourID, Name, Hex)
VALUES (0,   'Black',             '1B2A34'),
       (15,  'White',             'F4F4F4'),
       (71,  'Light Bluish Grey', '969696'),
       (72,  'Dark Bluish Grey',  '646464'),
       (78,  'Light Nougat',      'FFC995'),
       (92,  'Nougat',            'BB805A'),
       (84,  'Medium Nougat',     'AA7D55'),
       (128, 'Dark Nougat',       'AD6140'),
       (19,  'Tan',               'D7BA8C'),
       (371, 'Medium Tan',        'CCA373'),
       (28,  'Dark Tan',          '897D62'),
       (370, 'Medium Brown',      '755945'),
       (70,  'Reddish Brown',     '5F3109'),
       (308, 'Dark Brown',        '352100'),
       (335, 'Sand Red',          '88605E'),
       (320, 'Dark Red',          '720012'),
       (4,   'Red',               'B40000'),
       (1,   'Blue',              '1E5AA8'),
       (14,  'Yellow',            'FAC80A');

UPDATE c SET Lab = x.Lab
FROM lego.Colour AS c
CROSS APPLY lego.RgbToLab(c.R, c.G, c.B) AS x;

/* A portrait palette: no primaries, and no olive Dark Tan (stubble shadow lands on it) */
UPDATE lego.Colour SET InPalette = 0 WHERE Name IN ('Red', 'Blue', 'Yellow', 'Dark Tan');

/*  Bricks only (3 plates high).  Length >= Width, and in the LDraw part file
    the long side runs along X with the origin at the centre of the top face.  */
CREATE TABLE lego.Part
(
    PartID  varchar(20) NOT NULL PRIMARY KEY,   -- LDraw / BrickLink design number
    Name    varchar(40) NOT NULL,
    Length  tinyint     NOT NULL,               -- studs along X
    Width   tinyint     NOT NULL,               -- studs along Z
    CHECK (Length >= Width)
);

INSERT lego.Part (PartID, Name, Length, Width)
VALUES ('3005', 'Brick 1 x 1', 1, 1),
       ('3004', 'Brick 1 x 2', 2, 1),
       ('3622', 'Brick 1 x 3', 3, 1),
       ('3010', 'Brick 1 x 4', 4, 1),
       ('3009', 'Brick 1 x 6', 6, 1),
       ('3008', 'Brick 1 x 8', 8, 1),
       ('3003', 'Brick 2 x 2', 2, 2),
       ('3002', 'Brick 2 x 3', 3, 2),
       ('3001', 'Brick 2 x 4', 4, 2),
       ('2456', 'Brick 2 x 6', 6, 2),
       ('3007', 'Brick 2 x 8', 8, 2);

/* ---------- a model: voxels in, bricks out ---------- */
CREATE TABLE lego.Model
(
    ModelID    int IDENTITY PRIMARY KEY,
    Name       nvarchar(100) NOT NULL,
    MeshID     int NULL REFERENCES obj.Mesh,
    Scale      float NULL,          -- 1 = life size
    MmPerUnit  float NULL,          -- mesh units -> Lego mm (1000 * Scale for a mesh in metres)
    OriginX    float NULL,          -- mesh coordinates (mm) of voxel (0,0,0)'s corner
    OriginY    float NULL,
    OriginZ    float NULL
);

CREATE TABLE lego.Voxel
(
    ModelID   int      NOT NULL REFERENCES lego.Model,
    X         smallint NOT NULL,     -- studs
    Y         smallint NOT NULL,     -- brick layers, 0 = bottom
    Z         smallint NOT NULL,     -- studs, +Z = the front of the face
    Depth     smallint NULL,         -- 1 = on the surface, 2 = one in, ...
    ColourID  int      NULL REFERENCES lego.Colour,
    CONSTRAINT PK_Voxel PRIMARY KEY (ModelID, Y, Z, X)
);

CREATE TABLE lego.Brick
(
    BrickID   int IDENTITY PRIMARY KEY,
    ModelID   int         NOT NULL REFERENCES lego.Model,
    PartID    varchar(20) NOT NULL REFERENCES lego.Part,
    ColourID  int         NOT NULL REFERENCES lego.Colour,
    X         smallint    NOT NULL,  -- min corner, studs
    Y         smallint    NOT NULL,  -- layer
    Z         smallint    NOT NULL,  -- min corner, studs
    SizeX     tinyint     NOT NULL,  -- footprint as placed
    SizeZ     tinyint     NOT NULL
);
CREATE INDEX IX_Brick_Model ON lego.Brick (ModelID, Y) INCLUDE (X, Z, SizeX, SizeZ, PartID, ColourID);
GO
