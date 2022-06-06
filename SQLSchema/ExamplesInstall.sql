SET NUMERIC_ROUNDABORT OFF
GO
SET ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
SET XACT_ABORT ON
GO
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
GO
BEGIN TRANSACTION
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
-----------------------------------------------------------------------------------------------------------------
GO
PRINT N'Create example table Customer'
GO
IF NOT EXISTS (
		SELECT 1 
		FROM sys.tables t
		INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
		WHERE s.name = 'dbo'
			AND t.name = 'Customer'
	)
BEGIN
	CREATE TABLE dbo.Customer(ID INT NOT NULL IDENTITY(1,1),Active BIT NOT NULL CONSTRAINT DF_Customer_Active DEFAULT(1),Name NVARCHAR(255) NOT NULL, Address VARCHAR(4000), ContactName VARCHAR(255), [BillingStartDate] DATETIME2 NULL,Budget DECIMAL(10,2) NULL);
END
ELSE PRINT 'Customer table exists already (no need to create again)'
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
PRINT N'Populate example table Customer'
GO
INSERT INTO dbo.Customer(Active,Name, Address, ContactName, BillingStartDate, Budget)
SELECT a.Active, a.Name, a.Address, a.ContactName, a.BillingStartDate, a.Budget
FROM (VALUES
	 (1,N'Amazon', 'USA', 'Jeff', NULL, 1000)
	,(1,N'Volvo', 'Sweden', 'Xo', NULL, 500)
	,(1,N'Microsoft', 'USA', 'Satya', '2022-01-01 05:00', 800)
	,(0,N'Future Motion', 'USA', 'Kyle', NULL, NULL)
) a(Active,Name, Address, ContactName, BillingStartDate, Budget)
LEFT JOIN dbo.Customer c ON c.Name COLLATE DATABASE_DEFAULT = a.Name COLLATE DATABASE_DEFAULT
WHERE c.ID IS NULL/*dedup*/
;

INSERT INTO dbo.TherdlSetting(Code, Description, OrderID, DBName, SchemaName, ObjectName, ShowOnlyColumnsArrayListJSON, LayoutJSON)
SELECT a.Code, a.Description, a.OrderID, a.DBName, a.SchemaName, a.ObjectName, a.ShowOnlyColumnsArrayListJSON, a.LayoutJSON
FROM (VALUES
	( 'CustomerInfo', N'Get customers information', 10, DB_NAME(), 'dbo', 'Customer', N'["Active", "ID", "Name", "Budget", "BillingStartDate"]'
	 ,'[{"Column": "Name","Fill": "Tomato","Font": {"Color": "White", "Weight": "Bold"}},{"Column": "Budget", "Format": "''$''0.00;(''$''0.00)"},{"Column": "BillingStartDate", "Format": "dd/MM/yyyy"}]' 
	)
) a(Code, Description, OrderID, DBName, SchemaName, ObjectName, ShowOnlyColumnsArrayListJSON, LayoutJSON)
LEFT JOIN dbo.TherdlSetting s ON s.Code COLLATE DATABASE_DEFAULT = a.Code COLLATE DATABASE_DEFAULT
WHERE s.Code IS NULL /*dedup*/
;
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
PRINT N'Example view vwStorage'
GO
CREATE OR ALTER VIEW dbo.vwStorage AS 
SELECT a.Name, a.Quantity, a.Price, c.Name AS [MadeBy],c.ContactName AS [ComplainTo], a.SortingGroup
FROM (VALUES
	 (NULL,'Shelf','Cartbox',23, 0.01)
	,(NULL,'Bucket','Junk',34, 0)
	,('Amazon','Shelf','Alexa Echo',1, 30)
	,('Future Motion','Garage','Onewheel XR',1, 2500)
)a(CustomerName,SortingGroup,Name,Quantity,Price)
LEFT JOIN dbo.Customer c ON c.Name COLLATE DATABASE_DEFAULT = a.CustomerName COLLATE DATABASE_DEFAULT
;
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
PRINT N'Make view vwStorage available in the TheRDL'
GO
INSERT INTO dbo.TherdlSetting(Code, Description, OrderID, DBName, SchemaName, ObjectName, ShowOnlyColumnsArrayListJSON, LayoutJSON)
SELECT a.Code, a.Description, a.OrderID, a.DBName, a.SchemaName, a.ObjectName, a.ShowOnlyColumnsArrayListJSON, a.LayoutJSON
FROM (VALUES
	( 'Storage', N'What''s in my storage', 20, DB_NAME(), 'dbo', 'vwStorage', NULL , '[{"Column": "Price", "Format": "''$''0.00;(''$''0.00)"}]')
) a(Code, Description, OrderID, DBName, SchemaName, ObjectName, ShowOnlyColumnsArrayListJSON, LayoutJSON)
LEFT JOIN dbo.TherdlSetting s ON s.Code COLLATE DATABASE_DEFAULT = a.Code COLLATE DATABASE_DEFAULT
WHERE s.Code IS NULL /*dedup*/
;
GO
IF @@ERROR <> 0 SET NOEXEC ON
-----------------------------------------------------------------------------------------------------------------
GO
COMMIT TRANSACTION
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
DECLARE @Success AS BIT
SET @Success = 1
SET NOEXEC OFF
IF (@Success = 1) PRINT 'The database update succeeded'
ELSE BEGIN
	IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION
	PRINT 'The database update failed'
END
GO
