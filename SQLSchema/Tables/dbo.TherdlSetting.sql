CREATE TABLE [dbo].[TherdlSetting](
	 [Code] VARCHAR(255) NOT NULL
	,[Description] NVARCHAR(4000) NULL
	,[OrderID] INT NOT NULL CONSTRAINT DF_dbo_TherdlSetting_OrderID DEFAULT(0)
	,[DBName] VARCHAR(255) NOT NULL
	,[SchemaName] VARCHAR(255) NOT NULL CONSTRAINT DF_dbo_SchemaName DEFAULT('dbo')
	,[ObjectName] VARCHAR(255) NOT NULL
	,[ShowOnlyColumnsArrayListJSON] NVARCHAR(4000) NULL CONSTRAINT CHK_dbo_TherdlSetting_ShowOnlyColumnsJSON CHECK (ISJSON([ShowOnlyColumnsArrayListJSON])>0) --["ID", "Active", "Name"]
	,[LayoutJSON] NVARCHAR(4000) NULL CONSTRAINT CHK_dbo_TherdlSetting_LayoutJSON CHECK (ISJSON([LayoutJSON])>0) --[{"Column": "Name","Fill": "Tomato","Font": {"Color": "#FFFFFF", "Weight": "Bold"}}]
	,[ValidFrom] DATETIME2 (2) GENERATED ALWAYS AS ROW START HIDDEN 
	,[ValidTo] DATETIME2 (2) GENERATED ALWAYS AS ROW END HIDDEN
	,CONSTRAINT [PK_dbo_TherdlSetting] PRIMARY KEY CLUSTERED ([Code] ASC)
		WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
	,PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [dbo].[TherdlSettingHistory]))
GO
