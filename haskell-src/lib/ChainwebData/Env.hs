{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
module ChainwebData.Env
  ( Args(..)
  , Env(..)
  , MigrationsFolder
  , chainStartHeights
  , ServerEnv(..)
  , HTTPEnv (..)
  , ETLEnv (..)
  , getHTTPEnv
  , getETLEnv
  , Connect(..), withPoolInit, withPool, withCWDPool
  , Scheme(..)
  , toServantScheme
  , Url(..)
  , urlToString
  , UrlScheme(..)
  , showUrlScheme
  , ChainwebVersion(..)
  , Command(..)
  , BackfillArgs(..)
  , FillArgs(..)
  , envP
  , migrateOnlyP
  , checkSchemaP
  , richListP
  , NodeDbPath(..)
  , progress
  , EventType(..)
  ) where

import           Chainweb.Api.ChainId (ChainId(..))
import           Chainweb.Api.Common (BlockHeight)
import           Chainweb.Api.NodeInfo
import           ChainwebDb.Migration
import           Control.Concurrent
import           Control.Exception
import           Control.Monad (void)
import           Data.ByteString (ByteString)
import           Data.Char (toLower)
import           Data.IORef
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.String
import           Data.Pool
import           Data.Text (pack, Text)
import           Data.Time.Clock.POSIX
import           Database.Beam.Postgres
import           Database.PostgreSQL.Simple (execute_)
import           Gargoyle
import           Gargoyle.PostgreSQL
-- To get gargoyle to give you postgres automatically without having to install
-- it externally, uncomment the below line and comment the above line. Then do
-- the same thing down in withGargoyleDb and uncomment the gargoyle-postgres-nix
-- package in the cabal file.
--import Gargoyle.PostgreSQL.Nix
import           Network.HTTP.Client (Manager)
import           Options.Applicative
import qualified Servant.Client as S
import           System.IO
import           System.Logger.Types hiding (logg)
import           Text.Printf

---

type MigrationsFolder = FilePath

data Args
  = Args Command Connect UrlScheme Url LogLevel MigrationAction (Maybe MigrationsFolder)
    -- ^ arguments for all but the richlist command
  | RichListArgs NodeDbPath LogLevel ChainwebVersion
    -- ^ arguments for the Richlist command
  | MigrateOnly Connect LogLevel (Maybe MigrationsFolder)
  | CheckSchema Connect LogLevel
  deriving (Show)

data Env = Env
  { _env_httpManager :: Manager
  , _env_dbConnPool :: Pool Connection
  , _env_serviceUrlScheme :: UrlScheme
  , _env_p2pUrl :: Url
  , _env_nodeInfo :: NodeInfo
  , _env_chainsAtHeight :: [(BlockHeight, [ChainId])]
  , _env_logger :: LogFunctionIO Text
  }

chainStartHeights :: [(BlockHeight, [ChainId])] -> Map ChainId BlockHeight
chainStartHeights chainsAtHeight = go mempty chainsAtHeight
  where
    go m [] = m
    go m ((h,cs):rest) = go (foldr (\c -> M.insert c h) m cs) rest

data Connect = PGInfo ConnectInfo | PGString ByteString | PGGargoyle String
  deriving (Eq,Show)

-- | Equivalent to withPool but uses a Postgres DB started by Gargoyle
withGargoyleDbInit ::
  (Connection -> IO ()) ->
  FilePath ->
  (Pool Connection -> IO a) -> IO a
withGargoyleDbInit initConn dbPath func = do
  --pg <- postgresNix
  let pg = defaultPostgres
  withGargoyle pg dbPath $ \dbUri -> do
    caps <- getNumCapabilities
    let poolConfig =
          PoolConfig
            {
              createResource = connectPostgreSQL dbUri >>= \c -> c <$ initConn c
            , freeResource = close
            , poolCacheTTL = 5
            , poolMaxResources = caps
            }
    pool <- newPool poolConfig
    func pool

-- | Create a `Pool` based on `Connect` settings designated on the command line.
getPool :: IO Connection -> IO (Pool Connection)
getPool getConn = do
  caps <- getNumCapabilities
  let poolConfig =
        PoolConfig
          {
            createResource = getConn
          , freeResource = close
          , poolCacheTTL = 5
          , poolMaxResources = caps
          }
  newPool poolConfig

-- | A bracket for `Pool` interaction.
withPoolInit :: (Connection -> IO ()) -> Connect -> (Pool Connection -> IO a) -> IO a
withPoolInit initC = \case
  PGGargoyle dbPath -> withGargoyleDbInit initC dbPath
  PGInfo ci -> bracket (getPool $ withInit (connect ci)) destroyAllResources
  PGString s -> bracket (getPool $ withInit (connectPostgreSQL s)) destroyAllResources
  where withInit mkConn = mkConn >>= \c -> c <$ initC c


-- | A bracket for `Pool` interaction.
withPool :: Connect -> (Pool Connection -> IO a) -> IO a
withPool = withPoolInit mempty

withCWDPool :: Connect -> (Pool Connection -> IO a) -> IO a
withCWDPool = withPoolInit $ \conn -> do
  -- The following tells postgres to assume that accesses to random disk pages
  -- is equally expensive as accessing sequential pages. This is generally a good
  -- setting for a database that's storing its data on an SSD, but our intention
  -- here is to encourage Postgres to use index scan over table scans. The
  -- justification is that we design CW-D indexes and queries in tandem carefully
  -- to make sure all requests are serviced with predictable performance
  -- characteristics.
  void $ execute_ conn "SET random_page_cost = 1.0"

data Scheme = Http | Https
  deriving (Eq,Ord,Show,Enum,Bounded)

toServantScheme :: Scheme -> S.Scheme
toServantScheme Http = S.Http
toServantScheme Https = S.Https

schemeToString :: Scheme -> String
schemeToString Http = "http"
schemeToString Https = "https"

data Url = Url
  { urlHost :: String
  , urlPort :: Int
  } deriving (Eq,Ord,Show)

urlToString :: Url -> String
urlToString (Url h p) = h <> ":" <> show p

urlParser :: String -> Int -> Parser Url
urlParser prefix defaultPort = Url
    <$> strOption (long (prefix <> "-host") <> metavar "HOST" <> help ("host for the " <> prefix <> " API"))
    <*> option auto (long (prefix <> "-port") <> metavar "PORT" <> value defaultPort <> help portHelp)
  where
    portHelp = printf "port for the %s API (default %d)" prefix defaultPort

schemeParser :: String -> Parser Scheme
schemeParser prefix =
  flag Http Https (long (prefix <> "-https") <> help "Use HTTPS to connect to the service API (instead of HTTP)")

data UrlScheme = UrlScheme
  { usScheme :: Scheme
  , usUrl :: Url
  } deriving (Eq, Show)

showUrlScheme :: UrlScheme -> String
showUrlScheme (UrlScheme s u) = schemeToString s <> "://" <> urlToString u

urlSchemeParser :: String -> Int -> Parser UrlScheme
urlSchemeParser prefix defaultPort = UrlScheme
  <$> schemeParser prefix
  <*> urlParser prefix defaultPort

newtype ChainwebVersion = ChainwebVersion { getCWVersion :: Text }
  deriving newtype (IsString, Eq, Show, Ord, Read)

newtype NodeDbPath = NodeDbPath { getNodeDbPath :: Maybe FilePath }
  deriving (Eq, Show)

readNodeDbPath :: ReadM NodeDbPath
readNodeDbPath = eitherReader $ \case
  "" -> Right $ NodeDbPath Nothing
  s -> Right $ NodeDbPath $ Just s

data Command
    = Server ServerEnv
    | Listen (Maybe ETLEnv)
    | Backfill BackfillArgs
    | Fill FillArgs
    | Single ChainId BlockHeight
    | FillEvents BackfillArgs EventType
    | BackFillTransfers Bool BackfillArgs
    deriving (Show)

data BackfillArgs = BackfillArgs
  { _backfillArgs_delayMicros :: Maybe Int
  , _backfillArgs_chunkSize :: Maybe Int
  } deriving (Eq,Ord,Show)

data FillArgs = FillArgs
  { _fillArgs_delayMicros :: Maybe Int
  } deriving (Eq, Ord, Show)

data ServerEnv = Full FullEnv | HTTP HTTPEnv | ETL ETLEnv
  deriving (Eq,Ord,Show)

type FullEnv = (HTTPEnv, ETLEnv)

getHTTPEnv :: ServerEnv -> Maybe HTTPEnv
getHTTPEnv = \case
  HTTP env -> Just env
  Full (env,_) -> Just env
  _ -> Nothing

getETLEnv :: ServerEnv -> Maybe ETLEnv
getETLEnv = \case
  ETL env -> Just env
  Full (_,env) -> Just env
  _ -> Nothing

data HTTPEnv = HTTPEnv
 { _httpEnv_port :: Int
 , _httpEnv_serveSwaggerUi :: Bool
 } deriving (Eq,Ord,Show)

data ETLEnv = ETLEnv
 { _etlEnv_runFill :: Bool
 , _etlEnv_fillDelay :: Maybe Int
 } deriving (Eq,Ord,Show)

envP :: Parser Args
envP = Args
  <$> commands
  <*> connectP
  <*> urlSchemeParser "service" 1848
  <*> urlParser "p2p" 443
  <*> logLevelParser
  <*> migrationP
  <*> migrationsFolderParser

migrationsFolderParser :: Parser (Maybe MigrationsFolder)
migrationsFolderParser = optional $ strOption
    ( long "migrations-folder"
   <> metavar "PATH"
   <> help "Path to the migrations folder"
    )

migrationP :: Parser MigrationAction
migrationP
    = flag' RunMigrations (short 'm' <> long "migrate" <> help "Run DB migration")
  <|> flag' PrintMigrations
        ( long "ignore-schema-diff"
       <> help "Ignore any unexpected differences in the database schema"
        )
  <|> pure CheckMigrations

logLevelParser :: Parser LogLevel
logLevelParser =
    option (eitherReader (readLogLevel . pack)) $
      long "level"
      <> value Info
      <> help "Initial log threshold"

migrateOnlyP :: Parser Args
migrateOnlyP = hsubparser
  ( command "migrate"
    ( info opts $ progDesc
        "Run the database migrations only"
    )
  )
  where
    opts = MigrateOnly
      <$> connectP
      <*> logLevelParser
      <*> migrationsFolderParser

checkSchemaP :: Parser Args
checkSchemaP = hsubparser
  ( command "check-schema"
    ( info opts $ progDesc
        "Check the DB schema against the ORM definitions"
    )
  )
  where
    opts = CheckSchema
      <$> connectP
      <*> logLevelParser

richListP :: Parser Args
richListP = hsubparser
  ( command "richlist"
    ( info rlOpts
      ( progDesc "Create a richlist using existing chainweb node data"
      )
    )
  )
  where
    rlOpts = RichListArgs
      <$> option readNodeDbPath
        ( long "db-path"
        <> value (NodeDbPath Nothing)
        <> help "Chainweb node db filepath"
        )
      <*> logLevelParser
      <*> simpleVersionParser

versionReader :: ReadM ChainwebVersion
versionReader = eitherReader $ \case
  txt | map toLower txt == "mainnet01" || map toLower txt == "mainnet" -> Right "mainnet01"
  txt | map toLower txt == "testnet04" || map toLower txt == "testnet" -> Right "testnet04"
  txt -> Left $ printf "Can'txt read chainwebversion: got %" txt

simpleVersionParser :: Parser ChainwebVersion
simpleVersionParser =
  option versionReader $
    long "chainweb-version"
    <> value "mainnet01"
    <> help "Chainweb node version"

connectP :: Parser Connect
connectP = (PGString <$> pgstringP)
       <|> (PGInfo <$> connectInfoP)
       <|> (PGGargoyle <$> dbdirP)
       <|> pure (PGGargoyle "cwdb-pgdata")

dbdirP :: Parser FilePath
dbdirP = strOption (long "dbdir" <> help "Directory for self-run postgres")

pgstringP :: Parser ByteString
pgstringP = strOption (long "dbstring" <> help "Postgres Connection String")

-- | These defaults are pulled from the postgres-simple docs.
connectInfoP :: Parser ConnectInfo
connectInfoP = ConnectInfo
  <$> strOption   (long "dbhost" <> value "localhost" <> help "Postgres DB hostname")
  <*> option auto (long "dbport" <> value 5432        <> help "Postgres DB port")
  <*> strOption   (long "dbuser" <> value "postgres"  <> help "Postgres DB user")
  <*> strOption   (long "dbpass" <> value ""          <> help "Postgres DB password")
  <*> strOption   (long "dbname" <> help "Postgres DB name")

singleP :: Parser Command
singleP = Single
  <$> (ChainId <$> option auto (long "chain" <> metavar "INT"))
  <*> option auto (long "height" <> metavar "INT")

serverP :: Parser ServerEnv
serverP = toServerEnv
  <$> option auto (long "port" <> metavar "INT" <> help "Port the server will listen on")
  <*> flag False True (long "run-fill" <> short 'f' <> help "Run fill operation once a day to fill gaps")
  <*> delayP
  -- The OpenAPI spec is currently rudimentary and not official so we're hiding this option
  <*> flag False True (long "serve-swagger-ui" <> internal)
  <*> flag False True (long "no-listen" <> help "Disable ETL")
  where
    toServerEnv port runFill delay serveSwaggerUi = \case
      False -> Full (HTTPEnv port  serveSwaggerUi, ETLEnv runFill delay)
      True -> HTTP (HTTPEnv port serveSwaggerUi)

etlP :: Parser (Maybe ETLEnv)
etlP = optional $ toETLEnv
  <$> flag False True (long "run-fill" <> short 'f' <> help "Run fill operation once a day to fill gaps")
  <*> delayP
  where
    toETLEnv :: Bool -> Maybe Int -> ETLEnv
    toETLEnv runFill delay = ETLEnv runFill delay

delayP :: Parser (Maybe Int)
delayP = optional $ option auto (long "delay" <> metavar "DELAY_MICROS" <> help  "Number of microseconds to delay between queries to the node")

bfArgsP :: Parser BackfillArgs
bfArgsP = BackfillArgs
  <$> delayP
  <*> optional (option auto (long "chunk-size" <> metavar "CHUNK_SIZE" <> help "Number of transactions to query at a time"))

fillArgsP :: Parser FillArgs
fillArgsP = FillArgs
  <$> delayP

data EventType = CoinbaseAndTx | OnlyTx
  deriving (Eq,Ord,Show,Read,Enum,Bounded)

eventTypeP :: Parser EventType
eventTypeP =
  flag CoinbaseAndTx OnlyTx (long "only-tx" <> help "Only fill missing events associated with transactions")

commands :: Parser Command
commands = hsubparser
  (  command "listen" (info (Listen <$> etlP)
       (progDesc "Node Listener - Waits for new blocks and adds them to work queue"))
  <> command "backfill" (info (Backfill <$> bfArgsP)
       (progDesc "Backfill Worker - Backfills blocks from before DB was started (DEPRECATED)"))
  <> command "fill" (info (Fill <$> fillArgsP)
       (progDesc "Fills the DB with  missing blocks"))
  <> command "gaps" (info (Fill <$> fillArgsP)
       (progDesc "Gaps Worker - Fills in missing blocks lost during backfill or listen (DEPRECATED)"))
  <> command "single" (info singleP
       (progDesc "Single Worker - Lookup and write the blocks at a given chain/height"))
  <> command "server" (info (Server <$> serverP)
       (progDesc "Serve the chainweb-data REST API (also does listen)"))
  <> command "fill-events" (info (FillEvents <$> bfArgsP <*> eventTypeP)
       (progDesc "Event Worker - Fills missing events"))
  <> command "backfill-transfers" (info (BackFillTransfers <$> flag False True (long "disable-indexes" <> help "Delete indexes on transfers table") <*> bfArgsP)
       (progDesc "Backfill transfer table entries"))
  )

progress :: LogFunctionIO Text -> IORef Int -> Int -> IO a
progress logg count total = do
    start <- getPOSIXTime
    let go lastTime lastCount = do
          threadDelay 30_000_000  -- 30 seconds. TODO Make configurable?
          completed <- readIORef count
          now <- getPOSIXTime
          let perc = (100 * fromIntegral completed / fromIntegral total) :: Double
              elapsedSeconds = now - start
              elapsedSecondsSinceLast = now - lastTime
              instantBlocksPerSecond = (fromIntegral (completed - lastCount) / realToFrac elapsedSecondsSinceLast) :: Double
              totalBlocksPerSecond = (fromIntegral completed / realToFrac elapsedSeconds) :: Double
              estSecondsLeft = floor (fromIntegral (total - completed) / instantBlocksPerSecond) :: Int
              (timeUnits, timeLeft) | estSecondsLeft < 60 = ("seconds" :: String, estSecondsLeft)
                                    | estSecondsLeft < 3600 = ("minutes" :: String, estSecondsLeft `div` 60)
                                    | otherwise = ("hours", estSecondsLeft `div` 3600)
          logg Info $ fromString $ printf "Progress: %d/%d (%.2f%%), ~%d %s remaining at %.0f current items per second (%.0f overall average)."
            completed total perc timeLeft timeUnits instantBlocksPerSecond totalBlocksPerSecond
          hFlush stdout
          go now completed
    go start 0
