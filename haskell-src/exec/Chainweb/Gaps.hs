{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Chainweb.Gaps ( gaps, _test_headersBetween_and_payloadBatch ) where

import           Chainweb.Api.ChainId (ChainId(..))
import           Chainweb.Api.NodeInfo
import           Chainweb.Api.BlockHeader
import           ChainwebDb.Database
import           ChainwebData.Env
import           Chainweb.Lookups
import           Chainweb.Worker (writeBlocks)
import           ChainwebDb.Types.Block
import           ChainwebData.Genesis
import           ChainwebData.Types
import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Exception (catch, SomeException(..))
import           Control.Monad
import           Control.Scheduler
import           Data.Bool
import           Data.ByteString.Lazy (ByteString)
import           Data.IORef
import           Data.Int
import qualified Data.Map.Strict as M
import           Data.String
import           Data.Text (Text)
import           Data.Word (Word16)
import           Database.Beam hiding (insert)
import           Database.Beam.Postgres
import           Network.Connection (TLSSettings(TLSSettingsSimple))
import           Network.HTTP.Client
import           Network.HTTP.Client.TLS
import           System.Logger hiding (logg)
import qualified System.Logger as S
import           System.Exit (exitFailure)
import           Text.Printf

---
gaps :: Env -> FillArgs -> IO ()
gaps env args = do
  ecut <- queryCut env
  case ecut of
    Left e -> do
      let logg = _env_logger env
      logg Error "Error querying cut"
      logg Info $ fromString $ show e
    Right cutBS -> gapsCut env args cutBS

gapsCut :: Env -> FillArgs -> ByteString -> IO ()
gapsCut env args cutBS = do
  minHeights <- getAndVerifyMinHeights env cutBS
  getBlockGaps env minHeights >>= \gapsByChain ->
    if null gapsByChain
      then do
        logg Info $ fromString $ printf "No gaps detected."
        logg Info $ fromString $ printf "Either the database is empty or there are truly no gaps!"
      else do
        count <- newIORef 0
        let gapSize (a,b) = case compare a b of
              LT -> b - a - 1
              _ -> 0
            isGap = (> 0) . gapSize
            total = sum $ fmap (sum . map (bool 0 1 . isGap)) gapsByChain :: Int
            totalNumBlocks = fromIntegral $ sum $ fmap (sum . map gapSize) gapsByChain
        logg Info $ fromString $ printf "Filling %d gaps and %d blocks" total totalNumBlocks
        logg Debug $ fromString $ printf "Gaps to fill %s" (show gapsByChain)
        let doChain (cid, gs) = do
              let ranges = concatMap (createRanges cid) gs
              mapM_ (f logg count cid) ranges
        let gapFiller = do
              race_ (progress logg count totalNumBlocks)
                    (traverseConcurrently_ Par' doChain (M.toList gapsByChain))
              final <- readIORef count
              logg Info $ fromString
                $ printf "Filled in %d missing blocks" final
               ++ if (totalNumBlocks > final) then (printf ", %d fewer than detected gaps"  (totalNumBlocks - final)) else mempty
        gapFiller
  where
    pool = _env_dbConnPool env
    delay =  _fillArgs_delayMicros args
    gi = mkGenesisInfo $ _env_nodeInfo env
    logg = _env_logger env
    createRanges cid (low, high)
      | low == high = []
      | fromIntegral (genesisHeight (ChainId (fromIntegral cid)) gi) == low = rangeToDescGroupsOf blockHeaderRequestSize (Low $ fromIntegral low) (High $ fromIntegral (high - 1))
      | otherwise = rangeToDescGroupsOf blockHeaderRequestSize (Low $ fromIntegral (low + 1)) (High $ fromIntegral (high - 1))

    f :: LogFunctionIO Text -> IORef Int -> Int64 -> (Low, High) -> IO ()
    f logger count cid (l, h) = do
      let range = (ChainId (fromIntegral cid), l, h)
      let onCatch (e :: SomeException) = do
              logger Error $
                  fromString $ printf "Caught exception from headersBetween for range %s: %s" (show range) (show e)
              pure $ Right []
      (headersBetween env range `catch` onCatch) >>= \case
        Left e -> logger Error $ fromString $ printf "ApiError for range %s: %s" (show range) (show e)
        Right [] -> logger Error $ fromString $ printf "headersBetween: %s" $ show range
        Right hs -> writeBlocks env pool count hs
      maybe mempty threadDelay delay

_test_headersBetween_and_payloadBatch :: IO ()
_test_headersBetween_and_payloadBatch = do
    env <- testEnv
    queryCut env >>= print
    let ranges = rangeToDescGroupsOf blockHeaderRequestSize (Low 3817591) (High 3819591)
        toRange c (Low l, High h) = (c, Low l, High h)
        onCatch (e :: SomeException) = do
          putStrLn $ "Caught exception from headersBetween: " <> show e
          pure $ Right []
    forM_ (take 1 ranges) $ \range -> (headersBetween env (toRange (ChainId 0) range) `catch` onCatch) >>= \case
      Left e -> putStrLn $ "Error: " <> show e
      Right hs -> do
        putStrLn $ "Got " <> show (length hs) <> " headers"
        let makeMap = M.fromList . map (\bh -> (hashToDbHash $ _blockHeader_payloadHash bh, _blockHeader_hash bh))
        payloadWithOutputsBatch env (ChainId 0) (makeMap hs) id >>= \case
          Left e -> putStrLn $ "Error: " <> show e
          Right pls -> do
            putStrLn $ "Got " <> show (length pls) <> " payloads"
  where
    testEnv :: IO Env
    testEnv = do
      manager <- newManager $ mkManagerSettings (TLSSettingsSimple True False False) Nothing
      let urlHost_ = "localhost"
          serviceUrlScheme = UrlScheme Http $ Url urlHost_ 1848
          p2pUrl = Url urlHost_ 443
          nodeInfo = NodeInfo
            {
                _nodeInfo_chainwebVer = "mainnet01"
              , _nodeInfo_apiVer = undefined
              , _nodeInfo_chains = undefined
              , _nodeInfo_numChains = undefined
              , _nodeInfo_graphs = Nothing
            }
      return Env -- these undefined fields are not used in the `headersBetween` function
        {
          _env_httpManager = manager
        , _env_dbConnPool = undefined
        , _env_serviceUrlScheme = serviceUrlScheme
        , _env_p2pUrl = p2pUrl
        , _env_nodeInfo = nodeInfo
        , _env_chainsAtHeight = undefined
        , _env_logger = undefined
        }

_test_getBlockGaps
  :: String -- host
  -> Word16 -- port
  -> String -- user
  -> String -- password
  -> String -- db name
  -> IO ()
_test_getBlockGaps dbHost dbPort dbUser password dbName = withHandleBackend defaultHandleBackendConfig $ \backend ->
  withLogger defaultLoggerConfig backend $ \logger -> do
    let l = loggerFunIO logger
    manager <- newManager $ mkManagerSettings (TLSSettingsSimple True False False) Nothing
    let serviceUrlScheme = UrlScheme Http $ Url "localhost" 1848
    getNodeInfo manager serviceUrlScheme >>= \case
      Left _err -> l Error "Error getting node info"
      Right ni -> do
        let pgc = PGInfo $ ConnectInfo
              {
                connectHost = dbHost
              , connectPort = dbPort
              , connectUser = dbUser
              , connectPassword = password
              , connectDatabase = dbName
              }

        withCWDPool pgc $ \pool -> do
          env <- getEnv ni l manager pool
          let fromRight = either (error "fromRight: hit left") id
          cutBS <- fromRight <$> queryCut env
          minHeights <- getAndVerifyMinHeights env cutBS
          gapsByChain <- getBlockGaps env minHeights
          print gapsByChain
  where
    second f (a,b) = (a, f b)
    fromMaybe b = \case
      Just a -> a
      Nothing -> b
    getEnv ni lr m pool =
      return Env
        {
          _env_httpManager = m
        , _env_dbConnPool = pool
        , _env_serviceUrlScheme = UrlScheme Http $ Url "localhost" 1848
        , _env_p2pUrl = Url "localhost" 443
        , _env_nodeInfo = ni
        , _env_chainsAtHeight = fromMaybe (error "chainsAtMinHeight missing") $ map (second (map (ChainId . fst))) <$> (_nodeInfo_graphs ni)
        , _env_logger = lr
        }

getBlockGaps :: Env -> M.Map Int64 (Maybe Int64) -> IO (M.Map Int64 [(Int64,Int64)])
getBlockGaps env existingMinHeights = withDbDebug env Debug $ do
    let toMap = M.fromListWith (<>) . map (\(cid,a,b) -> (cid,[(a,b)]))
    foundGaps <- fmap toMap $ runSelectReturningList $ selectWith $ do
      foundGaps <- selecting $
        withWindow_ (\b -> frame_ (partitionBy_ (_block_chainId b)) (orderPartitionBy_ $ asc_ $ _block_height b) noBounds_)
                    (\b w -> (_block_chainId b, _block_height b, lead_ (_block_height b) (val_ (1 :: Int64)) `over_` w))
                    (all_ $ _cddb_blocks database)
      pure $ orderBy_ (\(cid,a,_) -> (desc_ a, asc_ cid)) $ do
        res@(_,a,b) <- reuse foundGaps
        guard_ ((b - a) >. val_ 1)
        pure res
    let minHeights = M.intersectionWith maybeAppendGenesis existingMinHeights
          $ fmap toInt64 $ M.mapKeys toInt64 genesisInfo
    unless (M.null minHeights) (liftIO $ logg Debug $ fromString $ "minHeight: " <> show minHeights)
    pure $ if M.null foundGaps
      then M.mapMaybe (fmap pure) minHeights
      else M.intersectionWith addStart minHeights foundGaps
  where
    logg level = _env_logger env level . fromString
    genesisInfo = getGenesisInfo $ mkGenesisInfo $ _env_nodeInfo env
    toInt64 a = fromIntegral a :: Int64
    maybeAppendGenesis mMin genesisheight =
      case mMin of
        Just min' -> case compare genesisheight min' of
          LT -> Just (genesisheight, min')
          _ -> Nothing
        Nothing -> Nothing
    addStart mr xs = case mr of
        Nothing -> xs
        Just r@(a,b)
          | a == b -> xs
          | otherwise -> r : xs

chainMinHeights :: Pg (M.Map Int64 (Maybe Int64))
chainMinHeights =
  fmap M.fromList
  $ runSelectReturningList
  $ select
  $ aggregate_ (\b -> (group_ (_block_chainId b), min_ (_block_height b))) (all_ $ _cddb_blocks database)

getAndVerifyMinHeights :: Env -> ByteString -> IO (M.Map Int64 (Maybe Int64))
getAndVerifyMinHeights env cutBS = do
  minHeights <- withDbDebug env Debug chainMinHeights
  let curHeight = fromIntegral $ cutMaxHeight cutBS
      count = length minHeights
      cids = atBlockHeight curHeight $ _env_chainsAtHeight env
      logg = _env_logger env
  when (count /= length cids) $ do
    logg Error $ fromString $ printf "%d chains have, but we expected %d." count (length cids)
    logg Error $ fromString $ printf "Please run 'listen' or 'server' first, and ensure that a block has been received on each chain."
    logg Error $ fromString $ printf "That should take about a minute, after which you can rerun this command."
    exitFailure
  return minHeights
