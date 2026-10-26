/*  08_Video.sql  --  the video's script is a SELECT
    ------------------------------------------------
    The story:
      A. build the head, layer by layer, until it's nearly closed over the top...
      B. ...realise there's nothing inside, and rewind back to half way
      C. grow the brain, from the spinal cord up
      D. finish the head over the top of it
    Every brick gets up to three frame numbers, and the renderer shows it when
        (frame >= T1 AND frame < T2)  OR  frame >= T3
      * bricks below the half-way layer: T1 only (built once, never touched again)
      * bricks between half way and the stop layer: T1, rewound at T2, rebuilt at T3
      * bricks above the stop layer, and the brain: one appearance only
    Within a layer, bricks go in order of their angle around the middle, so each layer
    sweeps round like a clock hand. Phases are ROW_NUMBER() divided by a bricks-per-frame rate.
*/
USE LegoSQL;
GO
IF OBJECT_ID('lego.VideoScript') IS NULL
    CREATE TABLE lego.VideoScript
    (
        BrickID  int NOT NULL PRIMARY KEY REFERENCES lego.Brick,
        T1 int NULL,    -- first appears
        T2 int NULL,    -- rewound away
        T3 int NULL     -- appears again
    );
GO
CREATE OR ALTER PROCEDURE lego.VideoTimeline
    @HeadModelID   int,
    @BrainModelID  int,
    @StopAt        float = 0.88,   -- build the head this far up (0..1)...
    @BackTo        float = 0.58,   -- ...then rewind back down to about half the head (not counting the neck)
    @BuildRate     int   = 14,     -- bricks per frame
    @RewindRate    int   = 30,
    @BrainRate     int   = 12,
    @FinishRate    int   = 14,
    @Hold          int   = 30      -- frames to pause between phases
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @y0 int, @y1 int, @cx float, @cz float;
    SELECT @y0 = MIN(Y), @y1 = MAX(Y),
           @cx = (MIN(X) + MAX(X + SizeX)) / 2.0, @cz = (MIN(Z) + MAX(Z + SizeZ)) / 2.0
    FROM lego.Brick WHERE ModelID = @HeadModelID;

    DECLARE @Stop int = @y0 + ROUND(@StopAt * (@y1 - @y0), 0),
            @Back int = @y0 + ROUND(@BackTo * (@y1 - @y0), 0);

    DROP TABLE IF EXISTS #T;
    SELECT b.BrickID, b.ModelID, b.Y,
           Angle = ATN2(b.Z + b.SizeZ / 2.0 - @cz, b.X + b.SizeX / 2.0 - @cx),
           T1 = CAST(NULL AS int), T2 = CAST(NULL AS int), T3 = CAST(NULL AS int)
    INTO #T
    FROM lego.Brick AS b
    WHERE b.ModelID IN (@HeadModelID, @BrainModelID);

    /* A. Build the head up to the stop layer */
    DECLARE @f int = 1;
    WITH A AS (SELECT T1, n = ROW_NUMBER() OVER (ORDER BY Y, Angle) - 1
               FROM #T WHERE ModelID = @HeadModelID AND Y <= @Stop)
    UPDATE A SET T1 = @f + n / @BuildRate;
    DECLARE @EndA int = (SELECT MAX(T1) FROM #T WHERE T1 IS NOT NULL) + @Hold;

    /* B. Rewind: the same bricks, backwards, faster */
    WITH B AS (SELECT T2, n = ROW_NUMBER() OVER (ORDER BY Y DESC, Angle DESC) - 1
               FROM #T WHERE ModelID = @HeadModelID AND Y > @Back AND Y <= @Stop)
    UPDATE B SET T2 = @EndA + n / @RewindRate;
    DECLARE @EndB int = (SELECT MAX(T2) FROM #T WHERE T2 IS NOT NULL) + @Hold / 2;

    /* C. Grow the brain, bottom up */
    WITH C AS (SELECT T1, n = ROW_NUMBER() OVER (ORDER BY Y, Angle) - 1
               FROM #T WHERE ModelID = @BrainModelID)
    UPDATE C SET T1 = @EndB + n / @BrainRate;
    DECLARE @EndC int = (SELECT MAX(T1) FROM #T WHERE ModelID = @BrainModelID) + @Hold;

    /* D. Finish the head over the top */
    WITH D AS (SELECT T3, n = ROW_NUMBER() OVER (ORDER BY Y, Angle) - 1
               FROM #T WHERE ModelID = @HeadModelID AND Y > @Back)
    UPDATE D SET T3 = @EndC + n / @FinishRate;
    DECLARE @EndD int = (SELECT MAX(T3) FROM #T WHERE T3 IS NOT NULL);

    /* Bricks above the stop layer only ever appear in D */
    UPDATE #T SET T1 = NULL WHERE ModelID = @HeadModelID AND Y > @Stop;

    SELECT Phase = 'A build',  FromFrame = 1,     ToFrame = @EndA - @Hold, Layers = CONCAT(@y0, '-', @Stop)
    UNION ALL SELECT 'B rewind', @EndA, @EndB - @Hold / 2, CONCAT(@Stop, '-', @Back + 1)
    UNION ALL SELECT 'C brain',  @EndB, @EndC - @Hold,     'all'
    UNION ALL SELECT 'D finish', @EndC, @EndD,             CONCAT(@Back + 1, '-', @y1);

    /* The script, one row per brick */
    TRUNCATE TABLE lego.VideoScript;
    INSERT lego.VideoScript (BrickID, T1, T2, T3) SELECT BrickID, T1, T2, T3 FROM #T;
END;
GO
