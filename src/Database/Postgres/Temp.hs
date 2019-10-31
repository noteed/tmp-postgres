{-|
This module provides functions creating a temporary @postgres@ instance.
By default it will create a temporary directory for the data,
a random port for listening and a temporary directory for a UNIX
domain socket.

Here is an example using the expection safe 'with' function:

 @
 'with' $ \\db -> 'Control.Exception.bracket' ('PG.connectPostgreSQL' ('toConnectionString' db)) 'PG.close' $ \\conn ->
  'PG.execute_' conn "CREATE TABLE foo (id int)"
 @

To extend or override the defaults use `withPlan` (or `startWith`).

@tmp-postgres@ ultimately calls @initdb@, @postgres@ and @createdb@.
All of the command line, environment variables and configuration files
that are generated by default for the respective executables can be
extended or overrided.

All @tmp-postgres@ by default is most useful for creating tests by
configuring "tmp-postgres" differently it can be used for other purposes.

* By disabling @initdb@ and @createdb@ one could run a temporary
postgres on a base backup to test a migration.
* By using the 'stopPostgres' and 'withRestart' functions one can test
backup strategies.

The level of custom configuration is extensive but with great power comes
ability to screw everything up. `tmp-postgres` doesn't validate any custom
configuration and one can easily create a `Config` that would not allow
postgres to start.

WARNING!!
Ubuntu's PostgreSQL installation does not put @initdb@ on the @PATH@. We need to add it manually.
The necessary binaries are in the @\/usr\/lib\/postgresql\/VERSION\/bin\/@ directory, and should be added to the @PATH@

 > echo "export PATH=$PATH:/usr/lib/postgresql/VERSION/bin/" >> /home/ubuntu/.bashrc

-}

module Database.Postgres.Temp
  (
  -- * Main resource handle
    DB (..)
  -- * Exception safe interface
  -- $options
  , with
  , withPlan
  -- * Separate start and stop interface.
  , start
  , startWith
  , stop
  , defaultConfig
  -- * Starting and Stopping postgres without removing the temporary directory
  , restart
  , stopPostgres
  , withRestart
  -- * Reloading the config
  , reloadConfig
  -- * DB manipulation
  , toConnectionString
  -- * Errors
  , StartError (..)
  -- * Configuration Types
  , Config (..)
  -- ** General extend or override monoid
  , Lastoid (..)
  -- ** Directory configuration
  , DirectoryType (..)
  , PartialDirectoryType (..)
  -- ** Listening socket configuration
  , SocketClass (..)
  , PartialSocketClass (..)
  -- ** Process configuration
  , PartialProcessConfig (..)
  , ProcessConfig (..)
  -- ** @postgres@ process configuration
  , PartialPostgresPlan (..)
  , PostgresPlan (..)
  -- *** @postgres@ process handle. Includes the client options for connecting
  , PostgresProcess (..)
  -- ** Database plans. This is used to call @initdb@, @postgres@ and @createdb@
  , PartialPlan (..)
  , Plan (..)
  -- ** Top level configuration
  ) where
import Database.Postgres.Temp.Internal
import Database.Postgres.Temp.Internal.Core
import Database.Postgres.Temp.Internal.Partial


{- $options

@postgres@ is started with a default config with the following options:

 @

   shared_buffers = 12MB
   fsync = off
   synchronous_commit = off
   full_page_writes = off
   log_min_duration_statement = 0
   log_connections = on
   log_disconnections = on
   unix_socket_directories = {DATA_DIRECTORY}
   client_min_messages = ERROR
 @

Additionally if an IP address is provide the following line is added:

 @
   listen_addresses = \'IP_ADDRESS\'
 @

 If a UNIX domain socket is specified the following is added:

 @
   listen_addresses = ''
   unix_socket_directories = {DATA_DIRECTORY}
 @

To add to \"postgresql.conf\" file create a custom 'Config' like the following:

 @
  let custom = defaultConfig <> mempty { configPlan = mempty
        { partialPlanConfig = Mappend
            [ "wal_level=replica"
            , "archive_mode=on"
            , "max_wal_senders=2"
            , "fsync=on"
            , "synchronous_commit=on"
            ]
        }
    }
 @

 In general you'll want to 'mappend' a config to the 'defaultConfig'.
 The 'defaultConfig' setups a database and connection options for
 the created database. However if you want to extend the behavior
 of @createdb@ you will probably have to create a 'Config' from
 scratch to ensure the final parameter to @createdb@ is the
 database name.
-}