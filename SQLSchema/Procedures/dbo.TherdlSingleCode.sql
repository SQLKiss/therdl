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
