# SQL Server Agent proxy procedure

## How we got here

If you're reading this, you're probably painfully aware that SQL Server Agent does not allow
you to assign granular permissions to SQL Server Agent jobs. One way to solve this problem
is to create a "proxy stored procedure" that runs as a different user and then use that
stored procedure to start Agent jobs.

Here's what the process looks like:

* Create a database user without a login or password in the `msdb` database.
* Make the database user a member of the `SQLAgentOperatorRole` role. This allows the
  user to start any agent job.
* Create a stored procedure that runs under the new database user's security context
  using the `WITH EXECUTE AS` clause. This stored procedure runs `dbo.sp_start_job`
  to start a specific job.
* You can now assign `EXECUTE` permissions to this stored procedure to users, roles or
  groups to suit your requirements.

## Procedure dbo.Create_Agent_proxy_procedures

This stored procedure creates proxy procedures for SQL Server Agent jobs.

Arguments:

* **@Principal_name**, *sysname*: The name of a new or existing database user.
* **@Category_schemas**, *bit*: Defaults to "1". If set, the procedure will create a
  dedicated database schema for each SQL Server Agent category. This allows you to set
  schema-level permissions rather than having to set permissions for each job. If false,
  all procedures are created in the default SQL Server schema (@Default_schema).
* **@Default_schema**, *sysname*: Defaults to "Jobs".

Process flow:

* Creates the database user if it does not already exist.
* Grant user membership in `SQLAgentOperatorRole`.
* Create schema(s) according to the parameter values.
* Grant `VIEW DEFINITION` on the new schema(s) to `public`.
* Create proxy stored procedure(s) with `EXECUTE AS`.

## View dbo.SQLServerAgentJobs

This view attempts to display the same information as shown in the SQL Server Agent
monitor in SQL Server Management Studio.

The setup script grants `SELECT` on this view to `public`.

## How to assign job permissions to users

Grant the designated user(s) `EXECUTE` permissions on the new proxy procedures.

Users with `EXECUTE` permissions will automatically be allowed to see the job(s)
in the monitoring view.

Remember that these logins will also require access to the `msdb` database.
