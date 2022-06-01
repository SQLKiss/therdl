#!/bin/bash  
filename="installation_file.sql"

#override file with initial GO command in it
echo "GO" > $filename
#Add header
echo "SET NUMERIC_ROUNDABORT OFF
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
GO" >> $filename

folder="Tables"
if [ -d $folder ]; then
    for f in $folder/*.sql
    do
        echo "PRINT N'Creating the $f'
GO
IF EXISTS (
		SELECT 1 
		FROM sys.tables t
		INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
		WHERE '$folder/' + s.name + '.' + t.name + '.sql' = '$f'
	)
BEGIN
    PRINT '$f exists already (no need to create again)'
    RETURN;
END" >> $filename

        cat $f >> $filename

        echo "GO
IF @@ERROR <> 0 SET NOEXEC ON
GO" >> $filename
    done
fi

folder="Procedures"
if [ -d $folder ]; then
    for f in $folder/*.sql
    do
    echo "PRINT N'Creating/Altering the $f'
GO" >> $filename

        cat $f >> $filename

        echo "GO
IF @@ERROR <> 0 SET NOEXEC ON
GO" >> $filename
    done
fi

folder="Data"
if [ -d $folder ]; then
    for f in $folder/*.sql
    do
    echo "PRINT N'Adding/merging initial data the $f'
GO" >> $filename

        cat $f >> $filename
        
        echo "GO
IF @@ERROR <> 0 SET NOEXEC ON
GO" >> $filename
    done
fi


#footer
echo "-----------------------------------------------------------------------------------------------------------------
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
GO" >> $filename

