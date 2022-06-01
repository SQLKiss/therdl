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