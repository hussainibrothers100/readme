# set server instance along with ip address and port number

$serverName = "localhost"
$port = "1435"
$instanceName = "MSSQLSERVER"
$serverInstance = "$serverName,$port\$instanceName"
$threshold = 300000  # Blocking threshold in milliseconds (5 minutes)
$sqlScript = @"
    IF EXISTS (SELECT 1 
               FROM master.dbo.sysprocesses S2-- WITH (NOLOCK) 
               --WHERE S2.spid != 0 
			   --AND S2.blocked != 0 AND S2.blocked != S2.spid
			   --AND waittime > @threshold
			   )
    BEGIN
        -- Create a temporary table to store blocking information
        CREATE TABLE BlockingInfo (
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
        INSERT INTO BlockingInfo (SPID, BlockingSPID, SQL_QUERY, HostName, LoginName, DatabaseName, ObjectName)
        SELECT 
        top 2
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
        --WHERE S1.blocked != 0 AND S1.blocked != S1.spid AND S1.waittime > @threshold;
        select * FROM BlockingInfo
    END
    ELSE
    BEGIN
        PRINT 'No blocking processes found.'
    END
"@
# Execute the SQL query using invoke-sqlcmd and store the result in $result
$result = Invoke-Sqlcmd -ServerInstance $serverInstance -Query $sqlScript

# Loop through each row in the result set
foreach ($row in $result) {
    # Access individual columns by their name
    Write-Host "Current row values:"
    Write-Host "Column1: $($row.SPID)"
    Write-Host "Column2: $($row.SQL_QUERY)"
    # ... and so on

    # Take user input using Read-Host
    $userInput = Read-Host "Please enter your input for this row"

    # If user selects to kill the process, update the ToBeKilled flag in the temporary table
    if ($userInput -eq "kill") {
        $updateQuery = "UPDATE BlockingInfo SET ToBeKilled = 1 WHERE SPID = '$($row.SPID)'"
        Invoke-Sqlcmd -ServerInstance $serverInstance -Query $updateQuery
    }
}

# After processing all rows, execute the final update query to kill the selected processes
$finalUpdateQuery = "SELECT * FROM BlockingInfo WHERE ToBeKilled = 1"

# After processing all rows, execute the final update query to kill the selected processes
$finalUpdateQuery = @"
    DECLARE @killCommand NVARCHAR(MAX) = '';
    SELECT @killCommand = @killCommand + 'KILL ' + CAST(SPID AS NVARCHAR(10)) + '; '
    FROM BlockingInfo WHERE ToBeKilled = 1;
    --EXEC sp_executesql @killCommand;
    --DROP TABLE BlockingInfo;
"@

Invoke-Sqlcmd -ServerInstance $serverInstance -Query $finalUpdateQuery
