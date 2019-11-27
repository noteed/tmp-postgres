import           Control.Concurrent
import           Control.Exception
import           Control.Monad ((<=<), void, unless)
import           Data.Function
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Monoid
import           Data.Monoid.Generic
-- import           Data.Int
import           Data.List
import qualified Data.Set as Set
import           Data.String
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Options as Client
import           Database.Postgres.Temp.Internal
import           Database.Postgres.Temp.Internal.Config
import           Database.Postgres.Temp.Internal.Core
import           GHC.Generics (Generic)
-- import qualified Network.Socket as N
import           Network.Socket.Free
import           System.Directory
import           System.Environment
import           System.Exit
import           System.IO.Error
import           System.IO.Temp
import           System.Posix.Files
import           System.Process
import           System.Timeout
import           Test.Hspec

withConn :: DB -> (PG.Connection -> IO a) -> IO a
withConn db f = do
  let connStr = toConnectionString db
  bracket (PG.connectPostgreSQL connStr) PG.close f

withConfig' :: Config -> (DB -> IO a) -> IO a
withConfig' config = either throwIO pure <=< withConfig config

countPostgresProcesses :: IO Int
countPostgresProcesses = countProcesses "postgres"

countInitdbProcesses :: IO Int
countInitdbProcesses = countProcesses "initdb"

countCreatedbProcesses :: IO Int
countCreatedbProcesses = countProcesses "createdb"

countProcesses :: String -> IO Int
countProcesses processName = do
  -- TODO we should restrict to child process
  (exitCode, xs, _) <-  readProcessWithExitCode "pgrep" [processName] []

  unless (exitCode == ExitSuccess || exitCode == ExitFailure 1) $ throwIO exitCode

  pure $ length $ lines xs

assertConnection :: DB -> IO ()
assertConnection db = do
  one <- fmap (PG.fromOnly . head) $
      withConn db $ \conn -> PG.query_ conn "SELECT 1"

  one `shouldBe` (1 :: Int)

testSuccessfulConfigNoTmp :: ConfigAndAssertion -> IO ()
testSuccessfulConfigNoTmp ConfigAndAssertion {..} = do
  initialPostgresCount <- countPostgresProcesses
  initialInitdbCount <- countInitdbProcesses
  initialCreatedbCount <- countCreatedbProcesses

  withConfig' cConfig $ \db -> do
    cAssert db
    assertConnection db

  countPostgresProcesses `shouldReturn` initialPostgresCount
  countInitdbProcesses `shouldReturn` initialInitdbCount
  countCreatedbProcesses `shouldReturn` initialCreatedbCount

testSuccessfulConfig :: ConfigAndAssertion -> IO ()
testSuccessfulConfig configAssert@ConfigAndAssertion{..} = do
  -- get the temp listing before
  let tmpDir = fromMaybe (error "test is bad")
        $ getLast $ temporaryDirectory cConfig
  initialContents <- listDirectory tmpDir
  testSuccessfulConfigNoTmp configAssert
  -- get the temp listing after
  listDirectory tmpDir `shouldReturn` initialContents

testWithTemporaryDirectory :: ConfigAndAssertion -> (ConfigAndAssertion -> IO a) -> IO a
testWithTemporaryDirectory x f =
  withTempDirectory "/tmp" "tmp-postgres-spec" $ \directoryPath ->
    f x
      { cConfig = (cConfig x) { temporaryDirectory = pure directoryPath }
      , cAssert = cAssert x <> (\db -> toTemporaryDirectory db `shouldBe` directoryPath)
      }

data ConfigAndAssertion = ConfigAndAssertion
  { cConfig :: Config
  , cAssert :: DB -> IO ()
  }
  deriving (Generic)
  deriving Semigroup via GenericSemigroup ConfigAndAssertion
  deriving Monoid    via GenericMonoid ConfigAndAssertion

-- Set all the things we support

memptyConfigAndAssertion :: ConfigAndAssertion
memptyConfigAndAssertion = memptyConfigAndAssertion' "postgres"

memptyConfigAndAssertion' :: String -> ConfigAndAssertion
memptyConfigAndAssertion' expectedDbName =
  let
    cConfig = mempty
    cAssert db = do
      let
        Client.Options {..} = toConnectionOptions db
        Last (Just hostString) = host
      -- I'm assuming here that I'm going to test
      -- with this prefix
      hostString `shouldStartWith` "/tmp/tmp-postgres-"
      -- Ephemeral range
      let Just thePort = getLast port
      thePort `shouldSatisfy` (>32768)
      toDataDirectory db `shouldStartWith` "/tmp/tmp-postgres-"
      dbname `shouldBe` pure expectedDbName

  in ConfigAndAssertion {..}

optionsToDefaultConfigMempty :: ConfigAndAssertion
optionsToDefaultConfigMempty = memptyConfigAndAssertion
  { cConfig = optionsToDefaultConfig mempty
  }

-- can't be combined
optionsToDefaultConfigSocket :: FilePath -> ConfigAndAssertion
optionsToDefaultConfigSocket socketPath =
  let
    cConfig = optionsToDefaultConfig mempty
      { Client.host = pure socketPath
      }
    cAssert db = do
      let
        Client.Options {..} = toConnectionOptions db
        Last (Just hostString) = host
      -- I'm assuming here that I'm going to test
      -- with this prefix
      hostString `shouldStartWith` "/tmp/tmp-postgres-"

  in ConfigAndAssertion {..}

optionsToDefaultConfigFilledOutConfigAssert :: Int -> ConfigAndAssertion
optionsToDefaultConfigFilledOutConfigAssert expectedPort =
  let
    expectedDbName   = "foobar"
    expectedUser     = "some_user"
    expectedPassword = "password"
    expectedHost     = "localhost"

    cConfig = optionsToDefaultConfig mempty
      { Client.port     = pure expectedPort
      , Client.dbname   = pure expectedDbName
      , Client.user     = pure expectedUser
      , Client.password = pure expectedPassword
      , Client.host     = pure expectedHost
      }

    cAssert db = do
      let Client.Options {..} = toConnectionOptions db
      port     `shouldBe` pure expectedPort
      user     `shouldBe` pure expectedUser
      dbname   `shouldBe` pure expectedDbName
      password `shouldBe` pure expectedPassword
      host     `shouldBe` pure expectedHost

  in ConfigAndAssertion {..}

extraConfigAssert :: ConfigAndAssertion
extraConfigAssert =
  let
    cConfig = mempty
      { plan = mempty
        { postgresConfigFile = ["log_min_duration_statement='100ms'"]
        }
      }

    cAssert db = withConn db $ \conn -> do
      [PG.Only actualDuration] <- PG.query_ conn "SHOW log_min_duration_statement"
      actualDuration `shouldBe` ("100ms" :: String)

  in ConfigAndAssertion {..}

defaultIpConfig :: ConfigAndAssertion
defaultIpConfig =
  let
    cConfig = mempty
      { plan = mempty
          { postgresPlan = mempty
            { connectionOptions = mempty
              { Client.host = pure "127.0.0.1"
              }
            }
          }
      }

    cAssert db = do
      let Client.Options {..} = toConnectionOptions db
      host `shouldBe` pure "127.0.0.1"

  in ConfigAndAssertion {..}


specificUnixSocket :: FilePath -> ConfigAndAssertion
specificUnixSocket filePath =
  let
    cConfig = mempty
      { socketDirectory = Permanent filePath
      }
    cAssert db = do
      let
        Client.Options {..} = toConnectionOptions db
        Last (Just hostString) = host
      -- I'm assuming here that I'm going to test
      -- with this prefix
      hostString `shouldStartWith` filePath

  in ConfigAndAssertion {..}

defaultConfigAssert :: ConfigAndAssertion
defaultConfigAssert = ConfigAndAssertion defaultConfig mempty

createdbAndDescription :: ConfigAndAssertion
createdbAndDescription =
  let
    expectedDescription = "newdb description"
    cConfig = mempty
      { plan = mempty
          { createDbConfig = pure silentProcessConfig
              { commandLine = mempty
                { indexBased = Map.fromList
                    [ (0, "newdb")
                    , (1, expectedDescription)
                    ]
                }
              }
          }
      }

    cAssert db = withConn db $ \conn -> do
      [PG.Only actualDescription] <- PG.query_ conn $ fromString $ unlines
        [ "SELECT description FROM pg_shdescription"
        , "JOIN pg_database ON objoid = pg_database.oid"
        , "WHERE datname = 'newdb'"
        ]
      actualDescription `shouldBe` expectedDescription
  in ConfigAndAssertion {..}

happyPaths :: Spec
happyPaths = describe "succeeds with" $ do
  it "mempty and extra postgresql.conf" $
    testWithTemporaryDirectory
      (defaultConfigAssert <> memptyConfigAndAssertion <> extraConfigAssert)
      testSuccessfulConfig

  it "optionsToDefaultConfig mempty is the same as mempty Config" $
    testWithTemporaryDirectory
      optionsToDefaultConfigMempty
      testSuccessfulConfig

  it "postgres db name does not cause createdb failure" $ do
    testWithTemporaryDirectory
      (  defaultConfigAssert
      <> memptyConfigAndAssertion
      <> ConfigAndAssertion (optionsToDefaultConfig mempty { Client.dbname = pure "postgres" }) mempty
      )
      testSuccessfulConfig

  it "template1 db name does not cause createdb failure" $ do
    testWithTemporaryDirectory
      (  defaultConfigAssert
      <> memptyConfigAndAssertion' "template1"
      <> ConfigAndAssertion (optionsToDefaultConfig mempty { Client.dbname = pure "template1" }) mempty
      )
      testSuccessfulConfig

  it "specific socket works with optionsToDefaultConfig" $
    withTempDirectory "/tmp" "tmp-postgres-spec-socket" $ \socketFilePath ->
      testWithTemporaryDirectory
        (optionsToDefaultConfigSocket socketFilePath)
        testSuccessfulConfig

  it "filled out optionsToDefaultConfig" $ do
    thePort <- getFreePort
    testWithTemporaryDirectory
      (optionsToDefaultConfigFilledOutConfigAssert thePort)
      testSuccessfulConfig

  it "default ip option works" $
    testWithTemporaryDirectory
      (defaultConfigAssert <> defaultIpConfig)
      testSuccessfulConfig

  it "specific unix socket works" $
    withTempDirectory "/tmp" "tmp-postgres-spec-socket" $ \socketFilePath ->
      testWithTemporaryDirectory
        (defaultConfigAssert <> specificUnixSocket socketFilePath)
        testSuccessfulConfig

  it "works with the default temporary directory to some degree at least" $
    testSuccessfulConfigNoTmp $ defaultConfigAssert <>
      memptyConfigAndAssertion <> createdbAndDescription

  it "works if on non-empty if initdb is disabled" $
    withTempDirectory "/tmp" "tmp-postgres-preinitdb" $ \dirPath -> do
      throwIfNotSuccess id =<< system ("initdb " <> dirPath)
      let nonEmptyFolderConfig = memptyConfigAndAssertion
            { cConfig = defaultConfig
              { dataDirectory = Permanent dirPath
              , plan = (plan defaultConfig)
                  { initDbConfig = Zlich
                  }
              }
            }
      testWithTemporaryDirectory nonEmptyFolderConfig testSuccessfulConfig

  it "makeResourcesDataDirPermanent works" $
    withTempDirectory "/tmp" "tmp-postgres-make-premanent" $ \dirPath -> do
       let config = defaultConfig { temporaryDirectory = pure dirPath }
       pathToCheck <- bracket (either throwIO (pure . makeDataDirPermanent) =<< startConfig config) stop $
        pure . toDataDirectory
       doesDirectoryExist pathToCheck >>= \case
         True -> pure ()
         False -> fail "temporary file was not made permanent"

  it "withDbCacheConfig actually caches the config and cleans up" $
    withTempDirectory "/tmp" "tmp-postgres-cache-test" $ \dirPath -> do
      let config = defaultConfig { temporaryDirectory = pure dirPath }
          cacheConfig = CacheConfig
            { cacheTemporaryDirectory = dirPath
            , cacheDirectoryType      = Temporary
            , cacheUseCopyOnWrite     = True
            }
      withDbCacheConfig cacheConfig $ \cacheInfo -> do
        withConfig' (config <> toCacheConfig cacheInfo) $ const $ pure ()
        -- see if there is a cache
        tmpFiles <- listDirectory dirPath

        cacheDir <- case filter ("tmp-postgres-cache" `isPrefixOf`) tmpFiles of
          [x] -> pure x
          xs -> fail $ "expected single cache dir got: " <> show xs

        listDirectory (dirPath <> "/" <> cacheDir) >>= \case
          [versionDir] -> listDirectory  (dirPath <> "/" <> cacheDir <> "/" <> versionDir) >>= \case
            [initDbCacheDir] ->
              writeFile
                (  dirPath
                <> "/"
                <> cacheDir
                <> "/"
                <> versionDir
                <> "/"
                <> initDbCacheDir
                <> "/data/cacheCheck.txt"
                )
                "test"
            xs -> fail $ "expected a single initdb cache directory but got " <> show xs
          xs -> fail $ "expected a single version directory but got " <> show xs

        -- add a file to look for later
        withConfig' (config <> toCacheConfig cacheInfo) $ \db -> do
          -- see if the file is in the data directory
          let theDataDirectory = toDataDirectory db
          xs <- listDirectory theDataDirectory
          xs `shouldContain` ["cacheCheck.txt"]

          assertConnection db

      -- See if cache has been cleaned up
      tmpFiles <- listDirectory dirPath

      case filter ("tmp-postgres-cache" `isPrefixOf`) tmpFiles of
        [] -> pure ()
        xs -> fail $ "unexpected cache dirs. Should be cleaned up. Got: " <> show xs

  it "withDbCache seems to work" $
    withDbCache $ \cacheInfo ->
      either throwIO pure =<< withConfig (defaultConfig <> toCacheConfig cacheInfo) assertConnection

--
-- Error Plans. Can't be combined. Just list them out inline since they can't be combined
--

errorPaths :: Spec
errorPaths = describe "fails when" $ do
  -- Should this test ensure that atleast a single connection
  -- attempt was made? probably.
  it "timesout if the connection parameters are wrong" $ do
    let invalidConfig = mempty
          { plan = mempty
              { connectionTimeout = pure 0
              , postgresPlan = mempty
                  { connectionOptions = mempty
                      { Client.dbname = pure "doesnotexist"
                      }
                  }
              }
          }
    withConfig (defaultConfig <> invalidConfig) (const $ pure ())
      `shouldReturn` Left ConnectionTimedOut

  it "does not timeout quickly with an invalid connection and large timeout" $ do
    let invalidConfig = mempty
          { plan = mempty
              { connectionTimeout = pure maxBound
              , postgresPlan = mempty
                  { connectionOptions = mempty
                      { Client.dbname = pure "doesnotexist"
                      }
                  }
              }
          }
    timeout 100000 (withConfig (defaultConfig <> invalidConfig) (const $ pure ()))
      `shouldReturn` Nothing
{-
  it "throws StartPostgresFailed if the port is taken" $
    bracket openFreePort (N.close . snd) $ \(thePort, _) -> do
      let invalidConfig = optionsToDefaultConfig mempty
            { Client.port = pure thePort
            , Client.host = pure "127.0.0.1"
            }
      withConfig invalidConfig (const $ pure ())
        `shouldReturn` Left (StartPostgresFailed $ ExitFailure 1)
-}
  it "throws StartPostgresFailed if the host does not exist" $ do
    let invalidConfig = optionsToDefaultConfig mempty
          { Client.host = pure "focalhost"
          }

        invalidConfig' = invalidConfig
          { plan = (plan invalidConfig)
              { connectionTimeout = pure 100000
              }
          }
    withConfig invalidConfig' (const $ pure ())
      `shouldReturn` Left ConnectionTimedOut

  it "throws StartPostgresFailed if the host does not resolve to ip that is local" $ do
    let invalidConfig = optionsToDefaultConfig mempty
          { Client.host = pure "yahoo.com"
          }

        invalidConfig' = invalidConfig
          { plan = (plan invalidConfig)
              { connectionTimeout = pure 100000
              }
          }
    withConfig invalidConfig' (const $ pure ())
      `shouldReturn` Left ConnectionTimedOut

  it "throws StartPostgresFailed if the host path does not exist" $ do
    let invalidConfig = optionsToDefaultConfig mempty
          { Client.host = pure "/focalhost"
          }
    withConfig invalidConfig (const $ pure ())
      `shouldReturn` Left (StartPostgresFailed $ ExitFailure 1)

  it "No initdb plan causes failure" $ do
    let dontTimeout = defaultConfig
          { plan = (plan defaultConfig)
              { connectionTimeout = pure maxBound
              , initDbConfig = Zlich
              }
          }

    withConfig dontTimeout (const $ pure ())
      `shouldReturn` Left EmptyDataDirectory

  it "initdb with non-empty data directory fails with InitDbFailed" $
    withTempDirectory "/tmp" "tmp-postgres-test" $ \dirPath -> do
      writeFile (dirPath <> "/PG_VERSION") "1 million"
      let nonEmptyFolderPlan = defaultConfig
            { dataDirectory = Permanent dirPath
            }

      withConfig nonEmptyFolderPlan mempty >>= \case
        Right () -> fail "Should not succeed"
        Left ((InitDbFailed theOut theErr code)) -> do
          code `shouldBe` ExitFailure 1
          length theOut `shouldSatisfy` (> 0)
          length theErr `shouldSatisfy` (> 0)
        Left err -> fail $ "Wrong type of error " <> show err

  it "invalid initdb options cause an error" $ do
    let invalidConfig = defaultConfig
          { plan = (plan defaultConfig)
              { initDbConfig = pure silentProcessConfig
                { commandLine = mempty
                  { keyBased = Map.singleton "--super-sync" Nothing
                  }
                }
              }
          }
    withConfig invalidConfig (const $ pure ()) >>= \case
      Right () -> fail "Should not succeed"
      Left (InitDbFailed {}) -> pure ()
      Left err -> fail $ "Wrong type of error " <> show err

  it "invalid createdb plan causes an error" $ do
    let invalidConfig = defaultConfig
          { plan = (plan defaultConfig)
              { createDbConfig = pure silentProcessConfig
                { commandLine = mempty
                  { indexBased =
                      Map.singleton 0 "template1"
                  }
                }
              }

          }
    withConfig invalidConfig (const $ pure ()) >>= \case
      Right () -> fail "Should not succeed"
      Left (CreateDbFailed {}) -> pure ()
      Left err -> fail $ "Wrong type of error " <> show err

  it "throws if initdb is not on the path" $ do
    path <-  getEnv "PATH"

    bracket (setEnv "PATH" "/foo") (const $ setEnv "PATH" path) $ \_ ->
      withConfig defaultConfig (const $ pure ())
        `shouldThrow` isDoesNotExistError

  it "throws if createdb is not on the path" $
    withTempDirectory "/tmp" "createdb-not-on-path-test" $ \dir -> do
      Just initDbPath   <- findExecutable "initdb"
      Just postgresPath <- findExecutable "postgres"

      -- create symlinks
      createSymbolicLink initDbPath $ dir <> "/initdb"
      createSymbolicLink postgresPath $ dir <> "/postgres"

      path <-  getEnv "PATH"

      let config = defaultConfig
            { plan = (plan defaultConfig)
                { createDbConfig = pure mempty
                }
            }

      bracket (setEnv "PATH" dir) (const $ setEnv "PATH" path) $ \_ ->
        withConfig config (const $ pure ())
          `shouldThrow` isDoesNotExistError

withConfigSpecs :: Spec
withConfigSpecs = describe "withConfig" $ do
  happyPaths
  errorPaths

withSnapshotSpecs :: Spec
withSnapshotSpecs = describe "withSnapshot" $ do
  it "works" $ withConfig' defaultConfig $ \db -> do
    -- TODO create a table
    withConn db $ \conn -> do
      _ <- PG.execute_ conn "BEGIN; CREATE TABLE foo ( id int );"
      void $ PG.execute_ conn "INSERT INTO foo (id) VALUES (1); END;"

    either throwIO pure <=< withSnapshot Temporary db $ \snapshotDir -> do
      let theSnapshotConfig = defaultConfig <> snapshotConfig snapshotDir
          snapshotConfigAndAssert = ConfigAndAssertion theSnapshotConfig $ flip withConn $ \conn -> do
            oneAgain <- fmap (PG.fromOnly . head) $ PG.query_ conn "SELECT id FROM foo"
            oneAgain `shouldBe` (1 :: Int)

      testWithTemporaryDirectory
        snapshotConfigAndAssert
        testSuccessfulConfig

spec :: Spec
spec = do
  withConfigSpecs

  withSnapshotSpecs

  it "stopPostgres cannot be connected to" $ withConfig' defaultConfig $ \db -> do
    stopPostgres db `shouldReturn` ExitSuccess
    PG.connectPostgreSQL (toConnectionString db) `shouldThrow`
      (\(_ :: IOError) -> True)

  it "reloadConfig works" $ withConfig' defaultConfig $ \db -> do
    let
      dataDir = toDataDirectory db
      expectedDuration = "100ms"
      extraConfig = "log_min_duration_statement='" <> expectedDuration <> "'"
    appendFile (dataDir ++ "/postgresql.conf") $ extraConfig

    reloadConfig db

    bracket (PG.connectPostgreSQL $ toConnectionString db) PG.close $ \conn -> do
      [PG.Only actualDuration] <- PG.query_ conn "SHOW log_min_duration_statement"
      actualDuration `shouldBe` expectedDuration

  -- Not a great test but don't want to be too rigid
  let createdbPlan = optionsToDefaultConfig mempty { Client.dbname = pure "newdb" }
  it "prettyPrintConfig seems to work" $ do
    let configString = prettyPrintConfig createdbPlan

        wordsToSearchFor = Set.fromList
          [ "commandLine:"
          , "connectionOptions:"
          , "connectionTimeout:"
          , "dataDirectory:"
          , "dataDirectoryString:"
          , "environmentVariables:"
          , "inherit:"
          , "initDbConfig:"
          , "port:"
          , "postgresConfig:"
          , "postgresConfigFile:"
          , "postgresPlan:"
          , "socketDirectory:"
          , "specific:"
          , "stdErr:"
          , "stdIn:"
          , "stdOut:"
          ]
    shouldSatisfy (Set.fromList $ words configString) $
      Set.isSubsetOf wordsToSearchFor

  it "prettyPrintDB seems to work" $ withConfig' (createdbPlan <> defaultConfig) $ \db -> do
    let dbString = prettyPrintDB db

        wordsToSearchFor = Set.fromList
          [ "completePlanInitDb:"
          , "completePlanCreateDb:"
          , "completePlanPostgres:"
          , "completePlanConfig:"
          , "completePlanDataDirectory:"
          ]

    shouldSatisfy (Set.fromList $ words dbString) $
      Set.isSubsetOf wordsToSearchFor

  let justBackupResources = defaultPostgresConf
        [ "wal_level=replica"
        , "archive_mode=on"
        , "max_wal_senders=2"
        , "fsync=on"
        , "synchronous_commit=on"
        ]
      backupResources = justBackupResources

  it "can support backup and restore" $ withConfig' backupResources $ \db@DB {..} -> do
    let dataDir = toFilePath (resourcesDataDir dbResources)
    appendFile (dataDir ++ "/pg_hba.conf") $ "local replication all trust"
    withTempDirectory "/tmp" "tmp-postgres-backup" $ \tempDir -> do
      let walArchiveDir = tempDir ++ "/archive"
          baseBackupFile = tempDir ++ "/backup"
          archiveLine = "archive_command = " ++
            "'test ! -f " ++ walArchiveDir ++ "/%f && cp %p " ++ walArchiveDir ++ "/%f'\n"
      appendFile (dataDir ++ "/postgresql.conf") $ archiveLine

      createDirectory walArchiveDir

      reloadConfig db

      let Just port = getLast $ Client.port $ postgresProcessClientOptions dbPostgresProcess
          Just host = getLast $ Client.host $ postgresProcessClientOptions dbPostgresProcess
          backupCommandFlags =
            [ "-D" ++ baseBackupFile
            , "--format=tar"
            , "-p" ++ show port
            , "-h" ++ host
            ]

      (exitCode, stdouts, errs) <-  readProcessWithExitCode "pg_basebackup" backupCommandFlags []
      case exitCode of
        ExitSuccess -> pure ()
        ExitFailure _ -> do
          putStrLn stdouts
          putStrLn errs
          fail $ "pg_basebackup failed with flags " ++ unwords backupCommandFlags

      bracket (PG.connectPostgreSQL $ toConnectionString db ) PG.close $ \conn -> do
        _ <- PG.execute_ conn "CREATE TABLE foo(id int PRIMARY KEY);"
        _ <- PG.execute_ conn "BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE; INSERT INTO foo (id) VALUES (1); COMMIT"
        _ :: [PG.Only String] <- PG.query_ conn "SELECT pg_walfile_name(pg_switch_wal())"
        _ :: [PG.Only String] <- PG.query_ conn "SELECT pg_walfile_name(pg_create_restore_point('pitr'))"
        _ <- PG.execute_ conn "BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE; INSERT INTO foo (id) VALUES (2); COMMIT"

        PG.query_ conn "SELECT id FROM foo ORDER BY id ASC"
          `shouldReturn` [PG.Only (1 :: Int), PG.Only 2]

      stopPostgresGracefully db `shouldReturn` ExitSuccess

      removeDirectoryRecursive dataDir
      createDirectory dataDir

      let untarCommand = "tar -C" ++ dataDir ++ " -xf " ++ baseBackupFile ++ "/base.tar"
      system untarCommand `shouldReturn` ExitSuccess

      system ("chmod -R 700 " ++ dataDir) `shouldReturn` ExitSuccess

      writeFile (dataDir ++ "/recovery.conf") $ "recovery_target_name='pitr'\nrecovery_target_action='promote'\nrecovery_target_inclusive=true\nrestore_command='"
         ++ "cp " ++ walArchiveDir ++ "/%f %p'"

      either throwIO pure <=< withRestart db $ \newDb -> do
        bracket (PG.connectPostgreSQL $ toConnectionString newDb) PG.close $ \conn -> do
          fix $ \next -> do
            fmap (PG.fromOnly . head) (PG.query_ conn "SELECT pg_is_in_recovery()") >>= \case
              True -> threadDelay 100000 >> next
              False -> pure ()

          PG.query_ conn "SELECT id FROM foo ORDER BY id ASC"
            `shouldReturn` [PG.Only (1 :: Int)]


main :: IO ()
main = hspec spec