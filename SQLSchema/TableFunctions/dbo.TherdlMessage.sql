GO
--Created:	2022-06-10	www.SQLKiss.com
CREATE OR ALTER FUNCTION [dbo].[TherdlMessage](@Message NVARCHAR(MAX))
RETURNS @Table_Message TABLE([Message] NVARCHAR(4000)) AS
BEGIN
	INSERT @Table_Message(Message) SELECT s.value AS [Message] FROM STRING_SPLIT(@Message,',') s;
	RETURN;
END;
GO
