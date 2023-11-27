-- Created: 2017-01-09  Vitaly Borisov
-- Use your own way of getting customer IDs and Names, the below goes as an example only
CREATE VIEW [dbo].[vw_ReportCustomer] AS
WITH Customer AS (
    SELECT a.ID,a.Name,a.Active,a.ResellerID,a.isReseller
    FROM (VALUES
         (1,'Test Customer A',1,NULL,1)
		,(2,'VB Industries',1,1,0)
		,(3,'TCB',1,NULL,0)
    ) a(ID,Name,Active,ResellerID,isReseller)

    --Optionally please use "dbo.Customer" from the ExamplesInstall.sql:
    --SELECT c.ID,c.Name,c.Active,CONVERT(INT,NULL) AS [ResellerID],CONVERT(BIT,NULL) AS [isReseller] FROM dbo.Customer c
)
SELECT c.ID AS [CustomerID]
    ,COALESCE('[' + res.Name + ']: ','') 
        + CASE WHEN c.isReseller = 1 THEN '[' ELSE '' END 
        + c.Name
        + CASE WHEN c.isReseller = 1 THEN ']' ELSE '' END
    AS [CustomerName]
FROM Customer c (NOLOCK)
LEFT JOIN Customer res (NOLOCK) ON res.ID = c.ResellerID
WHERE c.Active = 1	
GO
