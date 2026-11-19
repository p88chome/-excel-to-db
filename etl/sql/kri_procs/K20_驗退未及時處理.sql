-- ======================================================================
-- K20 驗退後未及時處理
--
-- 【抓什麼】驗退的貨轉進「待退倉」之後，放了太久（超過 MaxOpenDays 天）才退回供應商或處理掉，
--          或到基準日都還沒處理。
-- 【為什麼有風險】驗退品一直放著，供應商不會補貨、也不會扣款；放久了可能找不到、被誤用，
--                 或錯過退貨期限，損失由公司吸收。
--
-- 【怎麼判斷】
--   第 1 步：把待退倉（ReturnStorLoc）裡、基準日以前的所有異動抓出來。
--   第 2 步：出待退倉（貸方 H）的異動，依同料號 × 工廠 × 倉 × 批號，按日期排好、算「累計出了多少」。
--   第 3 步：進待退倉（借方 S，而且異動類型在 ReturnTransferType）的異動，同樣算「累計進了多少」。
--            先進先出：累計出量第一次追上這筆的累計進量那天，就是這筆處理完的日期。
--            停留天數 = 處理完的日期（還沒處理完用基準日）− 轉入日。
--   第 4 步：觀察期間內轉入、停留天數 > MaxOpenDays → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K20'）
--   MaxOpenDays  轉入待退倉後幾天內要處理完
--
-- 【名單】（kri.ValueList）
--   ReturnStorLoc       待退倉的倉別代碼（只在各環境本地設定）
--   ReturnTransferType  轉入待退倉的異動類型（例：311 倉間轉撥）
--
-- 【明細表 kri.K20_Detail 怎麼看】一列 = 一筆轉入待退倉的異動
--   Quantity、BaseUom  轉入的數量、基本單位
--   ClearedOn          處理完的日期；空的 = 基準日還沒處理完
--   OpenDays           在待退倉停留幾天
--   AmountLocal        這筆異動的本幣金額
--
-- 【限制】
--   資料起始日以前待退倉就有的餘額看不到（當作 0），所以早期的出倉可能被配到後來的轉入。
--   沒有設定 ReturnStorLoc 時，這題不會標記任何資料（備註會提示）。
-- ======================================================================
IF OBJECT_ID(N'kri.K20_Detail', N'U') IS NULL
CREATE TABLE kri.K20_Detail (
    RunId           INT           NOT NULL,
    MaterialDoc     NVARCHAR(10)  NOT NULL,
    MaterialDocYear NVARCHAR(4)   NOT NULL,
    MaterialDocItem NVARCHAR(4)   NOT NULL,
    PostingDate     DATE          NULL,
    Material        NVARCHAR(18)  NULL,
    Plant           NVARCHAR(4)   NULL,
    StorLoc         NVARCHAR(4)   NULL,
    Batch           NVARCHAR(10)  NULL,
    Quantity        DECIMAL(19,4) NULL,
    BaseUom         NVARCHAR(3)   NULL,
    ClearedOn       DATE          NULL,      -- NULL = 基準日還沒處理完
    OpenDays        INT           NULL,
    AmountLocal     DECIMAL(19,4) NULL,
    IsFlagged       BIT           NOT NULL,
    CONSTRAINT PK_kri_K20_Detail PRIMARY KEY (RunId, MaterialDoc, MaterialDocYear, MaterialDocItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K20
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @maxOpenDays INT = kri.Param('K20', 'MaxOpenDays');   -- 幾天內要處理完

    -- 第 1 步：待退倉裡、基準日以前的所有異動
    SELECT m.MaterialDoc, m.MaterialDocYear, m.MaterialDocItem, m.PostingDate, m.Material, m.Plant, m.StorLoc,
           ISNULL(m.Batch, '') AS Batch,          -- 沒有批號的當成同一批
           m.Quantity, m.BaseUom, m.LocalAmount, m.MovementType, m.DebitCreditInd
    INTO #ReturnMoves
    FROM inv.MaterialMovement m
    WHERE m.StorLoc IN (SELECT Value FROM kri.List('K20', 'ReturnStorLoc'))
      AND m.PostingDate <= @AsOfDate
      AND m.Quantity > 0;

    -- 第 2 步：出待退倉（貸方）：同料號 × 工廠 × 倉 × 批號，按日期累計出了多少
    SELECT Material, Plant, StorLoc, Batch, PostingDate,
           SUM(Quantity) OVER (PARTITION BY Material, Plant, StorLoc, Batch
                               ORDER BY PostingDate, MaterialDoc, MaterialDocItem ROWS UNBOUNDED PRECEDING) AS CumOut
    INTO #OutMoves
    FROM #ReturnMoves
    WHERE DebitCreditInd = 'H';
    CREATE CLUSTERED INDEX cx ON #OutMoves (Material, Plant, StorLoc, Batch, CumOut);   -- 第 3 步用累計量找

    -- 第 3 步：進待退倉（借方）：按日期累計進了多少（所有借方都算，配對才正確）
    SELECT r.*,
           SUM(Quantity) OVER (PARTITION BY Material, Plant, StorLoc, Batch
                               ORDER BY PostingDate, MaterialDoc, MaterialDocItem ROWS UNBOUNDED PRECEDING) AS CumIn
    INTO #InMoves
    FROM #ReturnMoves r
    WHERE DebitCreditInd = 'S';

    -- 先進先出：累計出量第一次 >= 這筆的累計進量的那天 = 處理完的日期
    SELECT i.*, c.ClearedOn,
           DATEDIFF(DAY, i.PostingDate, ISNULL(c.ClearedOn, @AsOfDate)) AS OpenDays   -- 沒處理完算到基準日
    INTO #Cleared
    FROM #InMoves i
    OUTER APPLY (SELECT MIN(o.PostingDate) AS ClearedOn
                 FROM #OutMoves o
                 WHERE o.Material = i.Material AND o.Plant = i.Plant AND o.StorLoc = i.StorLoc AND o.Batch = i.Batch
                   AND o.CumOut >= i.CumIn
                   AND o.PostingDate >= i.PostingDate) c
    WHERE i.PostingDate BETWEEN @PeriodFrom AND @PeriodTo                                     -- 期間內轉入的
      AND i.MovementType IN (SELECT Value FROM kri.List('K20', 'ReturnTransferType'));      -- 轉入待退倉的異動

    -- 第 4 步：放太久 → 標記；寫進明細
    INSERT kri.K20_Detail (RunId, MaterialDoc, MaterialDocYear, MaterialDocItem, PostingDate, Material, Plant,
                           StorLoc, Batch, Quantity, BaseUom, ClearedOn, OpenDays, AmountLocal, IsFlagged)
    SELECT @RunId, MaterialDoc, MaterialDocYear, MaterialDocItem, PostingDate, Material, Plant,
           StorLoc, NULLIF(Batch, ''), Quantity, BaseUom, ClearedOn, OpenDays, LocalAmount,
           CASE WHEN OpenDays > @maxOpenDays THEN 1 ELSE 0 END
    FROM #Cleared;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocNumber, DocItem, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, Reason)
    SELECT RunId, 'K20', CONCAT(MaterialDoc, '-', MaterialDocYear, '-', MaterialDocItem), 'MOVEMENT', Plant, Material,
           MaterialDoc, MaterialDocItem, PostingDate, OpenDays, @maxOpenDays, AmountLocal,
           CONCAT(N'轉入待退倉 ', StorLoc, N' 後 ', OpenDays, N' 天',
                  CASE WHEN ClearedOn IS NULL THEN N'仍未處理' ELSE CONCAT(N'才處理完（', ClearedOn, N'）') END)
    FROM kri.K20_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    IF NOT EXISTS (SELECT 1 FROM kri.List('K20', 'ReturnStorLoc'))
        SET @Note = N'沒有設定待退倉（ReturnStorLoc），這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'轉入待退倉 ', COUNT(*), N' 筆；基準日仍未處理 ', COUNT(CASE WHEN ClearedOn IS NULL THEN 1 END))
        FROM kri.K20_Detail WHERE RunId = @RunId;
END;
GO
