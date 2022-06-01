INSERT INTO dbo.TherdlSetting(Code, Description, OrderID, DBName, SchemaName, ObjectName, ShowOnlyColumnsArrayListJSON)
SELECT a.Code, a.Description, 0 AS [OrderID], DB_NAME() AS [DBName], 'dbo' AS [SchemaName], 'TherdlMessage' AS [ObjectName], '[]' AS [ShowOnlyColumnsArrayListJSON]
FROM (VALUES
	 ('Error', 'For the error messages')
	,('Invalid Input', 'When input validation failed')
) a(Code, Description)
LEFT JOIN dbo.TherdlSetting dup ON dup.Code = a.Code
WHERE dup.Code IS NULL /*dedup*/
;

