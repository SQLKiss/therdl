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
PRINT N'Check DB SQL 2016 compatibility'
GO
IF EXISTS (SELECT 1 FROM sys.databases s WHERE s.name = DB_NAME() AND s.compatibility_level < 130) RAISERROR('Installation requires SQL2016 compatibility_level=130 or higher',16,1);
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
PRINT N'Creating the settings table'
GO
IF NOT EXISTS (
		SELECT 1 
		FROM sys.tables t
		INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
		WHERE s.name = 'dbo'
			AND t.name = 'TherdlSetting'
	)
BEGIN
	CREATE TABLE [dbo].[TherdlSetting](
		 [Code] VARCHAR(255) NOT NULL
		,[Description] NVARCHAR(4000) NULL
		,[OrderID] INT NOT NULL CONSTRAINT DF_dbo_TherdlSetting_OrderID DEFAULT(0)
		,[DBName] VARCHAR(255) NOT NULL
		,[SchemaName] VARCHAR(255) NOT NULL CONSTRAINT DF_dbo_SchemaName DEFAULT('dbo')
		,[ObjectName] VARCHAR(255) NOT NULL
		,[ShowOnlyColumnsArrayListJSON] NVARCHAR(4000) NULL CONSTRAINT CHK_dbo_TherdlSetting_ShowOnlyColumnsJSON CHECK (ISJSON([ShowOnlyColumnsArrayListJSON])>0) --["ID", "Active", "Name"]
		,[ValidFrom] DATETIME2 (2) GENERATED ALWAYS AS ROW START HIDDEN 
		,[ValidTo] DATETIME2 (2) GENERATED ALWAYS AS ROW END HIDDEN
		,CONSTRAINT [PK_dbo_TherdlSetting] PRIMARY KEY CLUSTERED ([Code] ASC)
			WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
		,PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
	)
	WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [dbo].[TherdlSettingHistory]))
	;
END
ELSE PRINT 'Settings table exists already (no need to create again)'
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
PRINT N'Adding base values to the settings'
GO
INSERT INTO dbo.TherdlSetting(Code, Description, OrderID, DBName, SchemaName, ObjectName, ShowOnlyColumnsArrayListJSON)
SELECT a.Code, a.Description, 0 AS [OrderID], DB_NAME() AS [DBName], 'dbo' AS [SchemaName], 'TherdlMessage' AS [ObjectName], '[]' AS [ShowOnlyColumnsArrayListJSON]
FROM (VALUES
	 ('Error', 'For the error messages')
	,('Invalid Input', 'When input validation failed')
) a(Code, Description)
LEFT JOIN dbo.TherdlSetting dup ON dup.Code = a.Code
WHERE dup.Code IS NULL /*dedup*/
;
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
PRINT N'Creating/altering the main procedure'
GO
--Created:	2022-05-23	Vitaly Borisov
CREATE OR ALTER PROCEDURE [dbo].[TherdlReportData] 
	@json NVARCHAR(MAX)
AS
BEGIN 
	SET NOCOUNT ON; 
	--RDL accept only one parameter - single JSON and passes it directly to the procedure
	/*
	[
		{
			"Code": "Customer Information",
			-- not required
			"Params":{ -- this will be used as parameters in functions/procedures, not in use in views/tables
				"Message": "Test message",
				"ShowActiveOnly": 1
			},
			"Filters": { -- this will be used inside WHERE clause at the very end result data return
				"Sector": "COM",
				"ID": [126,148]
			}
		},
		{
			"Code": "..."
		}
		,
		{
			...
		}
	]
	*/
	DROP TABLE IF EXISTS #Result;
	CREATE TABLE #Result(Code VARCHAR(255),[Row] INT, [Column] INT, ColumnName NVARCHAR(255),[Value] NVARCHAR(MAX), ValueType INT);

	DROP TABLE IF EXISTS #Error;
	CREATE TABLE #Error([Code] VARCHAR(255) DEFAULT('Error'),[Message] NVARCHAR(4000));

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

	IF ISJSON(@json) < 1
	BEGIN
		INSERT INTO #Error(Code,Message)VALUES('Invalid Input','Incorrect JSON format of @json parameter');
		GOTO Finally;
	END

	BEGIN TRY
		DROP TABLE IF EXISTS #Base;
		SELECT s.Code, s.OrderID, s.DBName, OBJECT_ID('['+s.DBName+'].['+s.SchemaName+'].['+s.ObjectName+']') AS [object_id], s.SchemaName, s.ObjectName, s.ShowOnlyColumnsArrayListJSON AS [Columns], a.Params, a.Filters
		INTO #Base
		FROM (SELECT JSON_VALUE(j.Value,'$.Code') AS [Code], JSON_QUERY(j.Value,'$.Params') AS [Params], JSON_QUERY(j.Value,'$.Filters') AS [Filters] FROM OPENJSON(@json) j) a
		INNER JOIN dbo.TherdlSetting s ON s.Code COLLATE DATABASE_DEFAULT = a.Code COLLATE DATABASE_DEFAULT
		WHERE OBJECT_ID('['+s.DBName+'].['+s.SchemaName+'].['+s.ObjectName+']') IS NOT NULL /*to make sure this object actually exists, also this will filter out any tries of SQL injections*/
			AND EXISTS(SELECT 1 FROM sys.databases db WHERE db.name COLLATE DATABASE_DEFAULT = s.DBName COLLATE DATABASE_DEFAULT) /*second check on DB name just in case*/
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to create #Base table');
		GOTO Finally;
	END CATCH

	BEGIN TRY
		--Getting columns data from each DB (DBName has been checked in query above. Objects must be only table or view)
		DROP TABLE IF EXISTS #Column; CREATE TABLE #Column(DBName VARCHAR(255),[object_id] INT,name NVARCHAR(255),[column_id] INT);
		DECLARE @ColumnDynamicSQL NVARCHAR(MAX);
		SET @ColumnDynamicSQL = (
				SELECT (SELECT DISTINCT N'
					INSERT INTO #Column(DBName, object_id, name, column_id)
					SELECT DISTINCT '''+b.DBName+''' AS [DBName],c.object_id,c.name,c.column_id
					FROM ['+b.DBName+'].sys.columns c
					INNER JOIN ['+b.DBName+'].sys.objects o ON o.object_id = c.object_id AND o.type IN (''U'',''V'')
					WHERE c.object_id = ' + CONVERT(VARCHAR(255),b.object_id) + ';'
					FROM #Base b
					FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)')
			)
		;
		IF @ColumnDynamicSQL IS NOT NULL EXEC sys.sp_executesql @stmt = @ColumnDynamicSQL;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to fill in #Column table');
		GOTO Finally;
	END CATCH

	BEGIN TRY
		DROP TABLE IF EXISTS #Query;
		SELECT b.Code
			,'DECLARE @jsonquery NVARCHAR(MAX) = (' 
			 + 'SELECT ' + STUFF((
				SELECT ',[a].[' + c.name + ']'
				FROM #Column c
				OUTER APPLY OPENJSON(b.Columns) j
				WHERE c.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT AND c.object_id = b.object_id
					AND (b.Columns IS NULL OR j.Value COLLATE DATABASE_DEFAULT = c.name COLLATE DATABASE_DEFAULT)
				ORDER BY c.column_id
				FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)'),1,1,'')
			 + CHAR(13) + 'FROM ' + '['+b.DBName+'].['+b.SchemaName+'].['+b.ObjectName+'] AS [a]'
			 + IIF(b.Filters IS NOT NULL,CHAR(13) + 'WHERE 1=1','')
			 + COALESCE(CHAR(13) + ' ' + (SELECT DISTINCT 'AND [a].[' + f.[Key] + '] = ''' + f.Value + '''' 
											FROM OPENJSON(b.Filters) f 
											INNER JOIN #Column c ON c.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT
												AND c.name COLLATE DATABASE_DEFAULT = f.[Key] COLLATE DATABASE_DEFAULT
											WHERE f.Type <> 4 
										FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)'),'') --<< non-array filters
			 + COALESCE(CHAR(13) + ' ' + (SELECT DISTINCT 'AND [a].[' + f.[Key] + '] IN (' 
										+ STUFF((
												SELECT ',''' + j.[Value] + ''''
												FROM OPENJSON(f.[Value]) j
												FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)')
											,1,1,'')
										+ ')'
									FROM OPENJSON(b.Filters) f
									INNER JOIN #Column c ON c.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT
												AND c.name COLLATE DATABASE_DEFAULT = f.[Key] COLLATE DATABASE_DEFAULT
									WHERE f.Type = 4
									FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)'),'') --<< array filters
			 + CHAR(13) + 'FOR JSON PATH, INCLUDE_NULL_VALUES);'
			 + CHAR(13) + 'IF (ISJSON(@jsonquery)=0) RETURN;'
			 + CHAR(13) + 'INSERT INTO #Result(Code, [Row], [Column], ColumnName, Value, ValueType)' --<< temp table should be already created at this stage
			 + CHAR(13) + 'SELECT @Code AS [Code],j.[Key] AS [Row],COALESCE(o.column_id,cl.column_id) AS [Column],jj.[Key] AS [ColumnName],jj.Value AS [Value],jj.Type AS [ValueType]'
			 + CHAR(13) + 'FROM OPENJSON(@jsonquery) j CROSS APPLY OPENJSON(j.Value) jj'
			 + CHAR(13) + 'INNER JOIN #Column cl ON cl.DBName = ''' + b.DBName + ''' AND cl.object_id = ' + CONVERT(NVARCHAR(255),b.object_id) + ' AND cl.name COLLATE DATABASE_DEFAULT = jj.[Key] COLLATE DATABASE_DEFAULT'
			 + CHAR(13) + 'LEFT JOIN (SELECT c.Value AS [Param],c.[Key] AS [column_id] FROM OPENJSON(' + COALESCE('''' + b.Columns + '''','NULL') + ') c) o ON o.Param COLLATE DATABASE_DEFAULT = jj.[Key] COLLATE DATABASE_DEFAULT'
			 + CHAR(13) + 'ORDER BY [Row],[Column];'
			 + CHAR(13) AS [Query]
		INTO #Query
		FROM #Base b
		WHERE (b.Columns IS NULL OR ISJSON(b.Columns) > 0)
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to fill in #Column table');
		GOTO Finally;
	END CATCH

	--for each record run insert into #Result
	DECLARE @Code NVARCHAR(255),@Query NVARCHAR(MAX);
	DECLARE @ParmDefinition NVARCHAR(500) = '@Code NVARCHAR(255)';
	DECLARE cur_resultinsert CURSOR LOCAL FAST_FORWARD READ_ONLY FOR SELECT DISTINCT q.Code,q.Query FROM #Query q;
	OPEN cur_resultinsert;
	FETCH NEXT FROM cur_resultinsert INTO @Code,@Query;
	WHILE @@FETCH_STATUS = 0
	BEGIN
		BEGIN TRY
			EXEC sys.sp_executesql @stmt = @Query, @params = @ParmDefinition, @Code = @Code;  
		END TRY
		BEGIN CATCH
			INSERT INTO #Error(Code,Message)VALUES(@Code,'Query into #Result failed');
			--INSERT INTO #Error(Code,Message)VALUES(@Code,@Query); --<< For debugging
		END CATCH
		FETCH NEXT FROM cur_resultinsert INTO @Code,@Query;
	END
	CLOSE cur_resultinsert;
	DEALLOCATE cur_resultinsert;


	--if there is no data returned, show single message "No Data" for such sections
	--but if it's Error section - show the error message from Params (I know a bit wrong place for this one, to be moved somewhere else)
	BEGIN TRY
		INSERT INTO #Error(Code, Message)
		SELECT b.Code, IIF(b.Code = 'Error',JSON_VALUE(b.Params,'$.Message'),'No Data') AS [Message]
		FROM #Base b
		WHERE NOT EXISTS(SELECT 1 FROM #Result r WHERE r.Code COLLATE DATABASE_DEFAULT = b.Code COLLATE DATABASE_DEFAULT)
			AND NOT EXISTS(SELECT 1 FROM #Error e WHERE e.Code COLLATE DATABASE_DEFAULT = b.Code COLLATE DATABASE_DEFAULT)
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to fill in No Data sections');
		GOTO Finally;
	END CATCH

Finally:
	IF EXISTS(SELECT 1 FROM #Error)
	BEGIN
		INSERT INTO #Result(Code, [Row], [Column], ColumnName, Value, ValueType)
		SELECT e.Code,0 AS [TheRow],0 AS [TheColumn],'Message' AS [ColumnName],e.Message AS [Value],1/*string*/ AS [ValueType]
		FROM #Error e
		;
	END

	--Results
	SELECT r.Code, s.OrderID, r.[Row], r.[Column], r.ColumnName, r.Value, r.ValueType
	FROM #Result r
	INNER JOIN dbo.TherdlSetting s ON s.Code COLLATE DATABASE_DEFAULT = r.Code COLLATE DATABASE_DEFAULT
	ORDER BY s.OrderID,r.[Row],r.[Column]
	;

	--Clean-ups
	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Column;
	DROP TABLE IF EXISTS #Query;
	DROP TABLE IF EXISTS #Error;
	DROP TABLE IF EXISTS #Result;
END
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
PRINT N'Creating/altering the single-code-call procedure'
GO
--Created:	2022-05-24	Vitaly Borisov
CREATE OR ALTER PROCEDURE [dbo].[TherdlSingleCode] 
	@Code NVARCHAR(255),
	@Filters NVARCHAR(MAX) = NULL
AS
BEGIN 
	SET NOCOUNT ON;
	--Don't do much checks, just assemble JSON and pass as is. Errors will be handled in the main procedure
	DECLARE @json NVARCHAR(MAX) = CHAR(91)+CHAR(123)+CHAR(125)+CHAR(93);
	IF @Filters = '' SET @Filters = NULL;
	IF (ISJSON(@Filters) > 0 OR @Filters IS NULL)
	BEGIN
		SET @json = JSON_MODIFY(@json,'$[0].Code',@Code);
		SET @json = JSON_MODIFY(@json,'$[0].Filters',JSON_QUERY(@Filters));
	END
	ELSE
	BEGIN
		SET @json = JSON_MODIFY(@json,'$[0].Code','Error');

		DECLARE @Message NVARCHAR(4000) = '{"Message":"Invalid Filters JSON format"}'
		SET @json = JSON_MODIFY(@json,'$[0].Params',JSON_QUERY(@Message));
	END
	
	EXEC dbo.TherdlReportData @json = @json;

	IF OBJECT_NAME(@@PROCID) IS NULL PRINT @json;
END
GO
IF @@ERROR <> 0 SET NOEXEC ON
GO
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
