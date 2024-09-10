USE msdb;
GO

--- This procedure creates/maintains stored procedures that act as proxies to
--- SQL Server Agent jobs, allowing you to assign EXECUTE permissions to
--- individual jobs, rather than simply assigning ownership to the job.
---
--- DISCLAIMER: This is not production-grade software. Please review the code
---             and test it in a suitable environment before deploying it to
---             a live production environment.
---
--- Source: github.com/sqlsunday/sqlagent-proxy-procedures
---
-------------------------------------------------------------------------------

CREATE OR ALTER PROCEDURE dbo.Create_Agent_proxy_procedures
    @Principal_name     sysname=N'Agent_job_abstraction',
    @Category_schemas   bit=1,
    @Default_schema     sysname=N'Jobs',
    @Whatif             bit=0
AS





DECLARE @sql1 nvarchar(max), @sql2 nvarchar(max);



--- Create a database user without login or password, add this user to the SQL
--- Server Agent operator role:
-------------------------------------------------------------------------------

IF (NOT EXISTS (SELECT NULL FROM sys.database_principals WHERE [name]=@Principal_name)) BEGIN;
    SET @sql1=N'
    CREATE USER '+QUOTENAME(@Principal_name)+N' WITHOUT LOGIN;
    
    ALTER ROLE [SQLAgentOperatorRole] ADD MEMBER '+QUOTENAME(@Principal_name)+N';
';

    PRINT @sql1;
    IF (@Whatif=0) EXECUTE sys.sp_executesql @sql1;
END;



--- If @Category_schemas=1, make sure we have one schema for each job category.
--- Do not include "uncategorized" in this list - those will go to the default
--- schema.
-------------------------------------------------------------------------------

IF (@Category_schemas=1) BEGIN;
    DECLARE sch_cur CURSOR FAST_FORWARD FOR
        SELECT DISTINCT N'
CREATE SCHEMA '+QUOTENAME(REPLACE(REPLACE([name], N'[', N''), N']', N''))+N';', N'
GRANT VIEW DEFINITION ON SCHEMA::'+QUOTENAME(REPLACE(REPLACE([name], N'[', N''), N']', N''))+N' TO public;'
        FROM dbo.syscategories
        WHERE SCHEMA_ID(REPLACE(REPLACE([name], N'[', N''), N']', N'')) IS NULL
          AND category_id IN (SELECT category_id FROM dbo.sysjobs)
          AND [name] NOT IN (N'[Uncategorized (Local)]', N'[Uncategorized (Multi-Server)]', N'[Uncategorized]');
    OPEN sch_cur;

    FETCH NEXT FROM sch_cur INTO @sql1, @sql2;
    WHILE (@@FETCH_STATUS=0) BEGIN;

        PRINT @sql1;
        IF (@Whatif=0) EXECUTE sys.sp_executesql @sql1;

        PRINT @sql2;
        IF (@Whatif=0) EXECUTE sys.sp_executesql @sql2;

        FETCH NEXT FROM sch_cur INTO @sql1, @sql2;
    END;

    CLOSE sch_cur;
    DEALLOCATE sch_cur;
END;




--- Create the default schema (for uncategorized jobs, or if we don't want to
--- use different schemas per category).
-------------------------------------------------------------------------------

IF (SCHEMA_ID(@Default_schema) IS NULL) BEGIN;
    SET @sql1=N'
CREATE SCHEMA '+QUOTENAME(@Default_schema)+N';';
    PRINT @sql1;
    IF (@Whatif=0) EXECUTE sys.sp_executesql @sql1;

    SET @sql2=N'
GRANT VIEW DEFINITION ON SCHEMA::'+QUOTENAME(@Default_schema)+N' TO public;';
    PRINT @sql2;
    IF (@Whatif=0) EXECUTE sys.sp_executesql @sql2;
END;




--- Delete orphaned job procedures
-------------------------------------------------------------------------------

SELECT @sql1=STRING_AGG(N'DROP PROCEDURE '+QUOTENAME(s.[name])+N'.'+QUOTENAME(p.[name])+N';', N'
')
FROM sys.sql_modules AS m
INNER JOIN sys.procedures AS p ON m.[object_id]=p.[object_id]
INNER JOIN sys.schemas AS s ON p.[schema_id]=s.[schema_id]
WHERE m.[definition] LIKE N'%--- This procedure is automatically generated and maintained%'+
                          N'%--- Job identifier: <0x'+REPLICATE(N'[0-9A-F]', 32)+N'>%'
  AND s.[name] IN (
        SELECT @Default_schema
        UNION ALL
        SELECT REPLACE(REPLACE([name], N'[', N''), N']', N'')
        FROM dbo.syscategories)
  AND SUBSTRING(m.[definition], CHARINDEX(N'--- Job identifier: <0x', m.[definition])+21, 34) NOT IN (
        SELECT CONVERT(nvarchar(200), CAST(job_id AS varbinary(64)), 1)
        FROM dbo.sysjobs);

PRINT @sql1;
IF (@Whatif=0) EXECUTE sys.sp_executesql @sql1;





--- Create/update the job procedures
-------------------------------------------------------------------------------

DECLARE proc_cur CURSOR FAST_FORWARD FOR
    SELECT N'
--- This procedure is automatically generated and maintained - any modifications may be overwritten.
--- Used to start job "'+REPLACE(REPLACE(j.[name], NCHAR(10), N''), NCHAR(13), N'')+'".
--- Job identifier: <'+CONVERT(nvarchar(200), CAST(j.job_id AS varbinary(64)), 1)+N'>

CREATE OR ALTER PROCEDURE '+QUOTENAME(ISNULL(REPLACE(REPLACE(c.[name], N'[', N''), N']', N''), @Default_schema))+N'.'+QUOTENAME(j.[name])+N'
    @server_name        sysname=NULL,
    @step_name          sysname=NULL
WITH EXECUTE AS '+QUOTENAME(@Principal_name, N'''')+N'
AS

EXECUTE dbo.sp_start_job
    @job_id='+CONVERT(nvarchar(200), CAST(j.job_id AS varbinary(64)), 1)+N',
    @server_name=@server_name,
    @step_name=@step_name;

'
    FROM dbo.sysjobs AS j
    LEFT JOIN dbo.syscategories AS c ON j.category_id=c.category_id AND c.[name] NOT IN (N'[Uncategorized (Local)]', N'[Uncategorized (Multi-Server)]', N'[Uncategorized]');

OPEN proc_cur;
FETCH NEXT FROM proc_cur INTO @sql1;
WHILE (@@FETCH_STATUS=0) BEGIN;

    PRINT @sql1;
    IF (@Whatif=0) EXECUTE sys.sp_executesql @sql1;

    FETCH NEXT FROM proc_cur INTO @sql1;
END;

CLOSE proc_cur;
DEALLOCATE proc_cur;

GO

---
--- This view roughly replicates the data seen in the SQL Server Agent
--- job monitor windows in SSMS.
---
-------------------------------------------------------------------------------

CREATE OR ALTER VIEW dbo.SQLServerAgentJobs
AS

SELECT j.[name] AS [Name],
       (CASE WHEN j.[enabled]=1 THEN 'Yes' ELSE 'No' END) AS [Enabled],
       (CASE WHEN ja.stop_execution_date IS NOT NULL THEN N'Idle'
             WHEN ja.last_executed_step_id IS NULL THEN N'Idle'
             ELSE N'Executing, step '+CAST(ja.last_executed_step_id AS nvarchar(10))+N' '+js.step_name
             END) AS [Status],
       (CASE WHEN jh.run_status=0 THEN 'Failed'
             WHEN jh.run_status=1 THEN 'Succeeded'
             WHEN jh.run_status=2 THEN 'Retrying'
             WHEN jh.run_status=3 THEN 'Canceled'
             WHEN jh.run_status=4 THEN 'Executing'
             WHEN ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL THEN 'Executing'
             END) AS [Last Run outcome],
       jsch.next_run AS [Next Run],
       c.[name] AS [Category],
       (CASE WHEN jsch.next_run IS NOT NULL THEN 'Yes' ELSE 'No' END) AS [Scheduled],
       j.category_id AS [Category ID]
FROM sys.procedures AS p
INNER JOIN sys.sql_modules AS m ON p.[object_id]=m.[object_id]
CROSS APPLY (VALUES (TRY_CONVERT(varbinary(20), SUBSTRING(m.[definition], CHARINDEX(N'Job identifier: <0x', m.[definition])+17, 34), 1))) AS x(job_id)
INNER JOIN dbo.sysjobs AS j ON x.job_id=j.job_id
LEFT JOIN dbo.syscategories AS c ON j.category_id=c.category_id
OUTER APPLY (
    SELECT TOP (1)
           CONVERT(datetime2(0), STUFF(STUFF(CAST(next_run_date AS varchar(10)), 7, 0, '-'), 5, 0, '-')+' '+
                                 STUFF(STUFF(RIGHT('000000'+CAST(next_run_time AS varchar(10)), 6), 5, 0, ':'), 3, 0, ':'), 121) AS next_run
    FROM dbo.sysjobschedules
    WHERE job_id=j.job_id
      AND next_run_date>0
    ORDER BY next_run_date, next_run_time
    ) AS jsch
OUTER APPLY (
    SELECT TOP (1) start_execution_date, stop_execution_date, last_executed_step_id, job_history_id
    FROM dbo.sysjobactivity
    WHERE job_id=j.job_id
    ORDER BY [session_id] DESC
    ) AS ja
LEFT JOIN dbo.sysjobhistory AS jh ON j.job_id=jh.job_id AND ja.job_history_id=jh.instance_id
LEFT JOIN dbo.sysjobsteps AS js ON j.job_id=js.job_id AND ja.last_executed_step_id=js.step_id
WHERE m.[definition] LIKE N'%Job identifier: <0x%>%@server_name%@step_name%WITH EXECUTE AS%sp_start_job%'
  AND HAS_PERMS_BY_NAME(QUOTENAME(OBJECT_SCHEMA_NAME(p.[object_id]))+N'.'+QUOTENAME(OBJECT_NAME(p.[object_id])), 'OBJECT', 'EXECUTE')=1

GO
GRANT SELECT ON dbo.SQLServerAgentJobs TO public;
GO
