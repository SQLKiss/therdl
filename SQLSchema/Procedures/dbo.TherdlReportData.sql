GO
--Created:	2022-05-23	www.SQLKiss.com
CREATE OR ALTER PROCEDURE [dbo].[TherdlReportData] 
	@json NVARCHAR(MAX)
AS
BEGIN 
	SET NOCOUNT ON; 
	--RDL accept only one parameter - single JSON and passes it directly to the procedure
	/*
	[
		{
			"Code": "CustomerInfo",
			-- not required
			"Params":{ -- this will be used as parameters in functions/procedures, not in use in views/tables
				"Message": "Test message"
			},
			"Filters": { -- this will be used inside WHERE clause at the very end result data return
				"Active": 1,
				"Name": ["CustomerA","CustB"]
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
	DECLARE @ConditionalFormatColumnName VARCHAR(255) = '_TheRDLLayoutOverrideJSON_';

	DROP TABLE IF EXISTS #Result;
	CREATE TABLE #Result(Code VARCHAR(255),[Row] INT, [Column] INT, ColumnName NVARCHAR(255),[Value] NVARCHAR(MAX), ValueType INT);

	DROP TABLE IF EXISTS #Error;
	CREATE TABLE #Error([Code] VARCHAR(255) DEFAULT('Error'),[Message] NVARCHAR(4000));

	DROP TABLE IF EXISTS #Column;
	CREATE TABLE #Column(DBName VARCHAR(255),[object_id] INT,[type] VARCHAR(50),name NVARCHAR(255),[column_id] INT);

	DROP TABLE IF EXISTS #Parameter;
	CREATE TABLE #Parameter(DBName VARCHAR(255),[object_id] INT,name NVARCHAR(255),[parameter_id] INT, [Param] NVARCHAR(4000), [Value] NVARCHAR(4000));

	DROP TABLE IF EXISTS #Layout;
	CREATE TABLE #Layout(Code VARCHAR(255), [Row] INT, ColumnName VARCHAR(255), [Format] VARCHAR(255), Fill VARCHAR(255), FontColor VARCHAR(255), FontWeight VARCHAR(255));

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

	IF ISJSON(@json) < 1
	BEGIN
		INSERT INTO #Error(Code,Message)VALUES('Invalid Input','Incorrect JSON format of @json parameter');
		GOTO Finally;
	END

	-- Data Level -----------------------------------------------------------------------------------------------------------------------------------

	BEGIN TRY
		DROP TABLE IF EXISTS #Base;
		SELECT s.Code, s.OrderID, s.DBName, OBJECT_ID('['+s.DBName+'].['+s.SchemaName+'].['+s.ObjectName+']') AS [object_id], s.SchemaName, s.ObjectName
			,s.ShowOnlyColumnsArrayListJSON AS [Columns], a.Params, a.Filters
			,s.LayoutJSON
		INTO #Base
		FROM (SELECT JSON_VALUE(j.Value,'$.Code') AS [Code], JSON_QUERY(j.Value,'$.Params') AS [Params], JSON_QUERY(j.Value,'$.Filters') AS [Filters] FROM OPENJSON(@json) j) a
		INNER JOIN dbo.TherdlSetting s ON s.Code COLLATE DATABASE_DEFAULT = a.Code COLLATE DATABASE_DEFAULT
		WHERE /*VB-01*/ OBJECT_ID('['+s.DBName+'].['+s.SchemaName+'].['+s.ObjectName+']') IS NOT NULL /*to make sure this object actually exists, also this will filter out any tries of SQL injections*/
			  /*VB-02*/ AND EXISTS(SELECT 1 FROM sys.databases db WHERE db.name COLLATE DATABASE_DEFAULT = s.DBName COLLATE DATABASE_DEFAULT) /*second check on DB name just in case*/
			  /*VB-07*/ AND (s.ShowOnlyColumnsArrayListJSON IS NULL OR ISJSON(s.ShowOnlyColumnsArrayListJSON) > 0)
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to create #Base table');
		GOTO Finally;
	END CATCH

	BEGIN TRY
		/*
		VB: SQL Injection check. Columns to be aware of:
		#Base.DBName - checked at VB-01
		*/

		--Getting columns data from each DB (DBName has been checked in query above. Objects must be only table or view or table function)
		DECLARE @ColParDynamicSQL NVARCHAR(MAX);
		/*VB-03*/
		SET @ColParDynamicSQL = (
				SELECT (SELECT DISTINCT N'
					INSERT INTO #Column(DBName, [type], object_id, name, column_id)
					SELECT DISTINCT '''+b.DBName+''' AS [DBName],o.[type],c.object_id,c.name,c.column_id
					FROM ['+b.DBName+'].sys.columns c
					INNER JOIN ['+b.DBName+'].sys.objects o ON o.object_id = c.object_id AND o.type IN (''U'',''V'',''TF'')
					WHERE c.object_id = ' + CONVERT(VARCHAR(255),b.object_id) + ';' + CHAR(13)
					+ N'
					INSERT INTO #Parameter(DBName, object_id, name, parameter_id)
					SELECT DISTINCT '''+b.DBName+''' AS [DBName],p.object_id,p.name,p.parameter_id
					FROM ['+b.DBName+'].sys.parameters p
					WHERE p.object_id = ' + CONVERT(VARCHAR(255),b.object_id) + ';'
					FROM #Base b
					FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)')
			)
		;
		IF @ColParDynamicSQL IS NOT NULL EXEC sys.sp_executesql @stmt = @ColParDynamicSQL;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to fill in #Column table');
		GOTO Finally;
	END CATCH

	BEGIN TRY
		--Validate the required parameter for TF match with provided
		UPDATE p SET p.Param = a.Param, p.Value = a.Value
		FROM #Parameter p
		LEFT JOIN (
			SELECT b.DBName,b.object_id, '@'+j.[Key] AS [name], j.[Key] AS [Param],REPLACE(j.Value,'''','''''') AS [Value]
			FROM #Base b
			CROSS APPLY OPENJSON(b.Params) j
			WHERE /*VB-09*/ISJSON(b.Params) > 0
		) a ON a.DBName COLLATE DATABASE_DEFAULT = p.DBName COLLATE DATABASE_DEFAULT AND a.object_id = p.object_id AND a.name COLLATE DATABASE_DEFAULT = p.name COLLATE DATABASE_DEFAULT
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to validate Parameters');
		GOTO Finally;
	END CATCH

	IF EXISTS(SELECT 1 FROM #Parameter p WHERE p.Param IS NULL)
	BEGIN
		DECLARE @MissingParamMessage NVARCHAR(4000) = 'TF object requires next parameters: ';
		BEGIN TRY
			SELECT @MissingParamMessage +=
				STUFF((
					SELECT ',' + SUBSTRING(p.name,2,999)
					FROM #Parameter p
					INNER JOIN #Base b ON b.DBName COLLATE DATABASE_DEFAULT = p.DBName COLLATE DATABASE_DEFAULT AND b.object_id = p.object_id
					WHERE p.Param IS NULL
					ORDER BY p.parameter_id
					FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)')
				,1,1,'')
			;
		END TRY
		BEGIN CATCH
			SET @MissingParamMessage = 'Incorrect or missing parameters for Table Function object';
		END CATCH
		INSERT INTO #Error(Code,Message)VALUES('Invalid Input',@MissingParamMessage);
		GOTO Finally;
	END

	BEGIN TRY
		--To support custom conditional formating, add artificial column name. Next check will validate the column and if it doesn't exist - column will be ignored/removed.
		UPDATE b SET b.Columns = JSON_MODIFY(b.Columns,'append $',@ConditionalFormatColumnName)
		FROM #Base b
		WHERE ISJSON(b.Columns) > 0
		;

		--To make sure provided list of columns actually matches with list of exisitng columns
		/*VB-08*/
		UPDATE up SET up.[Columns] = IIF(ISJSON(a.ValidatedColumns)>0,a.ValidatedColumns,'[]')
		FROM (
			SELECT b.Code,b.Columns AS [Columns]
				,'[' + STUFF((
					SELECT ',"' + col.name + '"'
					FROM OPENJSON(b.Columns) cc
					INNER JOIN #Column col ON col.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT AND col.name COLLATE DATABASE_DEFAULT = cc.[Value] COLLATE DATABASE_DEFAULT
					ORDER BY cc.[Key]
					FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)')
					,1,1,'') + ']' AS [ValidatedColumns]
			FROM #Base b
			WHERE ISJSON(b.Columns) > 0
		) a
		INNER JOIN #Base up ON up.Code COLLATE DATABASE_DEFAULT = a.Code COLLATE DATABASE_DEFAULT
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to validate #Base table Columns list');
		GOTO Finally;
	END CATCH

	BEGIN TRY
		/*
		VB: SQL Injection check. Columns to be aware of:
		#Column.name - checked at VB-03, objects can be only Tables/Views, columns must exist for the object
		#Base.DBName - checked at VB-02
		#Base.SchemaName - checked at VB-01
		#Base.ObjectName - checked at VB-01
		#Base.Filters:
			f.[Key] - checked at VB-04, filter's key must match with actual column name, which was checked at VB-03
			f.[Value] and j.[Value] - replace all incoming single quotes as double single quotes - VB-05
				additionally lenght of such values are limited to 4000 characters - VB-06
		#Base.Parameters - checked it is JSON object only VB-09, replace all incoming single quotes as double single quotes - VB-10
				additionally lenght of such values are limited to 4000 characters - VB-11
		#Base.object_id - checked at VB-03, it can be only actual object_id(int) of existing object
		#Base.Columns - checked it is JSON object only VB-07, also values of the Columns are revalidated at VB-08
		*/
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
			 + CHAR(13) + 'FROM ' + '['+b.DBName+'].['+b.SchemaName+'].['+b.ObjectName+']'
						+ IIF(t.[Type]='TF','(' 
								+ COALESCE(
									STUFF((
										SELECT ',''' + /*VB-10*/REPLACE(p.Value,'''','''''') + ''''
										FROM #Parameter p
										WHERE p.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT
											AND p.object_id = b.object_id
										/*VB-11*/AND LEN(p.[Value]) <= 4000
										ORDER BY p.parameter_id
										FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)')
									,1,1,'')
								  ,'')
							+ ')','')
						+ ' AS [a]'
			 + IIF(b.Filters IS NOT NULL,CHAR(13) + 'WHERE 1=1','')
			 + COALESCE(CHAR(13) + ' ' + (SELECT DISTINCT 'AND [a].[' + f.[Key] + '] ' + IIF(f.[Value] LIKE '%','LIKE','=') + ' ''' + /*VB-05*/REPLACE(f.Value,'''','''''') + '''' 
											FROM OPENJSON(b.Filters) f 
											INNER JOIN #Column c ON c.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT
												/*VB-04*/AND c.name COLLATE DATABASE_DEFAULT = f.[Key] COLLATE DATABASE_DEFAULT
												/*VB-06*/AND LEN(f.[Value]) <= 4000
											WHERE f.Type <> 4 
										FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)'),'') --<< non-array filters
			 + COALESCE(CHAR(13) + ' ' + (SELECT DISTINCT 'AND [a].[' + f.[Key] + '] IN (' 
										+ STUFF((
												SELECT ',''' + /*VB-05*/REPLACE(j.Value,'''','''''') + ''''
												FROM OPENJSON(f.[Value]) j
												/*VB-06*/WHERE LEN(j.[Value]) <= 4000
												FOR XML PATH(''),TYPE).value('(./text())[1]','NVARCHAR(MAX)')
											,1,1,'')
										+ ')'
									FROM OPENJSON(b.Filters) f
									INNER JOIN #Column c ON c.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT
											/*VB-04*/AND c.name COLLATE DATABASE_DEFAULT = f.[Key] COLLATE DATABASE_DEFAULT
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
		INNER JOIN (SELECT col.DBName,col.object_id,MAX(col.[type]) AS [Type] FROM #Column col GROUP BY col.DBName, col.object_id) t  ON t.DBName COLLATE DATABASE_DEFAULT = b.DBName COLLATE DATABASE_DEFAULT AND t.object_id = b.object_id
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

			IF OBJECT_NAME(@@PROCID) IS NULL
			BEGIN
				PRINT @Query;
				PRINT CHAR(13);
			END
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

	-- Layout Level ---------------------------------------------------------------------------------------------------------------------------------
	BEGIN TRY
		INSERT INTO #Layout(Code, [Row], ColumnName, [Format], Fill, FontColor, FontWeight)
		SELECT a.Code, rr.[Row], a.ColumnName, a.[Format], a.Fill, a.FontColor, a.FontWeight
		FROM (
			SELECT b.Code,ROW_NUMBER()OVER(PARTITION BY b.Code,JSON_VALUE(j.Value,'$.Column') ORDER BY b.Code,JSON_VALUE(j.Value,'$.Column')) AS [rn]
				,JSON_VALUE(j.Value,'$.Column') AS [ColumnName]
				,JSON_VALUE(j.Value,'$.Format') AS [Format]
				,JSON_VALUE(j.Value,'$.Fill') AS [Fill]
				,JSON_VALUE(j.Value,'$.Font.Color') AS [FontColor]
				,JSON_VALUE(j.Value,'$.Font.Weight') AS [FontWeight]
			FROM #Base b
			CROSS APPLY OPENJSON(b.LayoutJSON) j
			WHERE b.LayoutJSON IS NOT NULL
				AND ISJSON(b.LayoutJSON) > 0
		) a
		CROSS JOIN (SELECT DISTINCT r.[Row] FROM #Result r) rr --<< this means apply formating onto all rows
		WHERE a.rn = 1 /*dedup*/
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to set all rows Layout');
		GOTO Finally;
	END CATCH

	BEGIN TRY
		--Specific layout overrides from the objects @ConditionalFormatColumnName column
		MERGE #Layout AS target
		USING (
			SELECT a.Code, a.[Row], a.ColumnName, a.[Format], a.Fill, a.FontColor, a.FontWeight
			FROM (
				SELECT r.Code,r.[Row],JSON_VALUE(j.Value,'$.Column') AS [ColumnName]
					,ROW_NUMBER()OVER(PARTITION BY r.Code,r.Row,JSON_VALUE(j.Value,'$.Column') ORDER BY r.Code,r.[Row],JSON_VALUE(j.Value,'$.Column')) AS [rn]
					,JSON_VALUE(j.Value,'$.Format') AS [Format]
					,JSON_VALUE(j.Value,'$.Fill') AS [Fill]
					,JSON_VALUE(j.Value,'$.Font.Color') AS [FontColor]
					,JSON_VALUE(j.Value,'$.Font.Weight') AS [FontWeight]
				FROM #Result r
				CROSS APPLY OPENJSON(r.Value) j
				WHERE r.ColumnName = @ConditionalFormatColumnName
					AND ISJSON(r.Value) > 0
			) a
			WHERE a.rn = 1
		) AS source ON source.Code COLLATE DATABASE_DEFAULT = target.Code COLLATE DATABASE_DEFAULT
			AND source.[Row] = target.[Row]
			AND source.ColumnName COLLATE DATABASE_DEFAULT = target.ColumnName COLLATE DATABASE_DEFAULT
		WHEN MATCHED AND ( -- Merge one way, do not override exiting all-rows-settings
					COALESCE(target.[Format],'') <> source.[Format]
				 OR COALESCE(target.[Fill],'') <> source.[Fill]
				 OR COALESCE(target.[FontColor],'') <> source.[FontColor]
				 OR COALESCE(target.[FontWeight],'') <> source.[FontWeight]
				)
			THEN UPDATE SET
				 target.[Format] = COALESCE(source.[Format],target.[Format])
				,target.[Fill] = COALESCE(source.[Fill],target.[Fill])
				,target.[FontColor] = COALESCE(source.[FontColor],target.[FontColor])
				,target.[FontWeight] = COALESCE(source.[FontWeight],target.[FontWeight])
		WHEN NOT MATCHED THEN INSERT(Code, [Row], ColumnName, [Format], Fill, FontColor, FontWeight)
			VALUES(source.Code, source.[Row], source.ColumnName, source.[Format], source.Fill, source.FontColor, source.FontWeight)
		;
	END TRY
	BEGIN CATCH
		INSERT INTO #Error(Message)VALUES('Failed to merge custom Layout');
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
	DROP TABLE IF EXISTS #FinalResult;
	SELECT a.Code, a.OrderID, a.Row, a.[Column], a.ColumnName, a.Value, a.ValueType, a.Fill, a.FontColor, a.FontWeight, a.[Format] 
	INTO #FinalResult
	FROM (
		SELECT r.Code, s.OrderID, r.[Row], r.[Column], ROW_NUMBER()OVER(PARTITION BY r.Code, r.[Row], r.[Column] ORDER BY r.ColumnName) AS [rn]
			,r.ColumnName
			,r.Value AS [Value]
			,r.ValueType
			,l.Fill, l.FontColor, l.FontWeight, l.[Format]
		FROM #Result r
		INNER JOIN dbo.TherdlSetting s ON s.Code COLLATE DATABASE_DEFAULT = r.Code COLLATE DATABASE_DEFAULT
		LEFT JOIN #Layout l ON l.Code COLLATE DATABASE_DEFAULT = r.Code COLLATE DATABASE_DEFAULT AND l.ColumnName COLLATE DATABASE_DEFAULT = r.ColumnName COLLATE DATABASE_DEFAULT AND l.[Row] = r.[Row]
		WHERE r.ColumnName <> @ConditionalFormatColumnName
	) a
	WHERE a.rn = 1 /*make sure there is no duplicates on Code/Row/Column combination to avoid funky results in report*/
	;

	-- Output ---------------------------------------------------------------------------------------------------------------------------------------
	SELECT f.Code, f.OrderID, f.Row, f.[Column], f.ColumnName, f.Value, f.ValueType
		,f.Fill, f.FontColor, f.FontWeight, f.[Format] 
	FROM #FinalResult f
	ORDER BY f.OrderID,f.[Row],f.[Column]
	;

	--Clean-ups
	IF OBJECT_NAME(@@PROCID) IS NOT NULL
	BEGIN
		DROP TABLE IF EXISTS #Base;
		DROP TABLE IF EXISTS #Column;
		DROP TABLE IF EXISTS #Parameter;
		DROP TABLE IF EXISTS #Query;
		DROP TABLE IF EXISTS #Error;
		DROP TABLE IF EXISTS #Layout;
		DROP TABLE IF EXISTS #Result;
		DROP TABLE IF EXISTS #FinalResult;
	END
END
GO
