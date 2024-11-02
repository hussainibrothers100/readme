# Variables
$serverInstance = "OMWEKNYOSCRPDB2\MSSQLSERVER"  # Replace with your SQL Server instance name
$threshold = 300000  # Blocking threshold in milliseconds (5 minutes)
$sqlScript = @"
    -- Check for blocking processes exceeding the threshold
    IF EXISTS (SELECT 1 
               FROM master.dbo.sysprocesses S2 WITH (NOLOCK) 
               WHERE S2.spid != 0 AND S2.blocked != 0 AND S2.blocked != S2.spid AND waittime > $threshold)
    BEGIN
        -- Create a temporary table to store blocking information
        CREATE TABLE #BlockingInfo (
            SPID INT,
            BlockingSPID INT,
            SQL_QUERY VARCHAR(MAX),
            HostName VARCHAR(128),
            LoginName VARCHAR(128),
            DatabaseName VARCHAR(128),
            ObjectName VARCHAR(128),
			ToBeKilled bit
        );

        -- Gather information about blocking processes
        INSERT INTO #BlockingInfo (SPID, BlockingSPID, SQL_QUERY, HostName, LoginName, DatabaseName, ObjectName)
        SELECT 
            S1.spid,
            S1.blocked,
            sqltxt.text,
            LTRIM(RTRIM(hostname)),
            loginame,
            DB_NAME(L1.resource_database_id),
            OBJECT_NAME(L1.resource_associated_entity_id, L1.resource_database_id)
        FROM master.dbo.sysprocesses S1 WITH (NOLOCK)
        LEFT JOIN sys.dm_tran_locks L1 WITH (NOLOCK) ON S1.spid = L1.request_session_id AND L1.resource_type = 'OBJECT'
        OUTER APPLY sys.dm_exec_sql_text(sql_handle) sqltxt
        WHERE S1.blocked != 0 AND S1.blocked != S1.spid AND S1.waittime > $threshold;
"@
Invoke-Sqlcmd -ServerInstance $serverInstance -Query $sqlScript

$sqlScript = @"
        -- Kill the blocked sessions
        DECLARE @killCmd VARCHAR(MAX) = '';
        SELECT @killCmd = @killCmd + 'KILL ' + CAST(SPID AS VARCHAR(10)) + ';' FROM #BlockingInfo;
        EXEC(@killCmd);

        -- Construct the email body
        DECLARE @tableHTML NVARCHAR(MAX);
        SET @tableHTML =
            N'<H1>Blocking Alert</H1>' +
            N'<table border="1">' +
            N'<tr><th>SPID</th><th>Blocking SPID</th><th>SQL Query</th><th>Hostname</th><th>Login</th><th>Database</th><th>Object</th></tr>' +
            CAST((SELECT 
                      td = SPID, '',
                      td = BlockingSPID, '',
                      td = SQL_QUERY, '',
                      td = HostName, '',
                      td = LoginName, '',
                      td = DatabaseName, '',
                      td = ObjectName
                  FROM #BlockingInfo
                  FOR XML PATH('tr'), TYPE) AS NVARCHAR(MAX)) +
            N'</table>';

        -- Send the email notification
        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = 'DBA',  -- Replace with your actual DB Mail profile name
            @recipients = 'youremail@yourdomain.com',  -- Replace with your email address
            @subject = 'Blocking Processes Killed',
            @body = @tableHTML,
            @body_format = 'HTML';

        -- Drop the temporary table
        DROP TABLE #BlockingInfo;
    END
"@

# Execute the SQL script using Invoke-Sqlcmd
Invoke-Sqlcmd -ServerInstance $serverInstance -Query $sqlScript