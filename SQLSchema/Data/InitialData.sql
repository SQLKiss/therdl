INSERT INTO dbo.TherdlSetting(Code, Description, OrderID, DBName, SchemaName, ObjectName, ShowOnlyColumnsArrayListJSON, LayoutJSON)
SELECT a.Code, a.Description, 0 AS [OrderID], DB_NAME() AS [DBName], 'dbo' AS [SchemaName], 'TherdlMessage' AS [ObjectName], '["Message"]' AS [ShowOnlyColumnsArrayListJSON]
	,'[{"Column": "Message","Fill": "Red","Font": {"Color": "White", "Weight": "Bold"}}]' AS [LayoutJSON]
FROM (VALUES
	 ('Error', 'For the error messages')
	,('Invalid Input', 'When input validation failed')
) a(Code, Description)
LEFT JOIN dbo.TherdlSetting dup ON dup.Code = a.Code
WHERE dup.Code IS NULL /*dedup*/
;

