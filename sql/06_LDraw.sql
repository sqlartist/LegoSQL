/*  05_LDraw.sql  --  write the build as an LDraw file (opens in BrickLink Studio, LDView, LeoCAD)
    ---------------------------------------------------------------------------------------------
    One line per brick:   1 <colour> <x> <y> <z> <3x3 rotation> <part>.dat
      * 20 LDU per stud, 24 LDU per brick layer; LDraw's Y axis points DOWN
      * a brick part's origin is the centre of its top face, long side along X
      * the face looks along -Z in LDraw ("front"), so our Z is flipped (with Y, that's
        a 180 degree turn about X, not a mirror image)
    A "0 STEP" after each layer turns the file into layer-by-layer building instructions.
*/
USE LegoSQL;
GO
CREATE OR ALTER FUNCTION lego.LDraw (@ModelID int)
RETURNS TABLE
AS RETURN
WITH Centre AS
(
    SELECT cx = (MIN(X) + MAX(X + SizeX)) / 2,     -- centre the model on the origin...
           cz = (MIN(Z) + MAX(Z + SizeZ)) / 2,
           y0 = MIN(Y)                              -- ...and stand it on the ground
    FROM lego.Brick
    WHERE ModelID = @ModelID
),
Lines AS
(
    SELECT Layer = -1, Seq = 1, Line = CONCAT('0 ', m.Name)                         FROM lego.Model AS m WHERE m.ModelID = @ModelID
    UNION ALL SELECT -1, 2, CONCAT('0 Name: model_', @ModelID, '.ldr')
    UNION ALL SELECT -1, 3, '0 Author: LegoSQL on SQL Server 2025'
    UNION ALL
    SELECT b.Y, 10 + ROW_NUMBER() OVER (PARTITION BY b.Y ORDER BY b.Z, b.X),
           CONCAT('1 ', b.ColourID, ' ',
                  (2 * b.X + b.SizeX - 2 * c.cx) * 10, ' ',          -- x: centre of the footprint
                  -(b.Y - c.y0 + 1) * 24, ' ',                       -- y: top of the layer (Y is down)
                  -(2 * b.Z + b.SizeZ - 2 * c.cz) * 10, ' ',         -- z: flipped so the face is at the front
                  IIF(b.SizeX >= b.SizeZ, '1 0 0 0 1 0 0 0 1',       -- long side along X as drawn...
                                          '0 0 1 0 1 0 -1 0 0'),     -- ...or turned 90 degrees about Y
                  ' ', b.PartID, '.dat')
    FROM lego.Brick AS b
    CROSS JOIN Centre AS c
    WHERE b.ModelID = @ModelID
    UNION ALL
    SELECT DISTINCT Y, 999999, '0 STEP' FROM lego.Brick WHERE ModelID = @ModelID
)
SELECT Layer, Seq, Line FROM Lines;
GO
