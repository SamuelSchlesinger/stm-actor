{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
module MailboxWindTunnel
  ( quickSmoke
  , runCLI
  ) where

import Control.Concurrent (forkFinally, getNumCapabilities, threadDelay)
import Control.Concurrent.Actor
    ( ActionT
    , Actor
    , ActorDead
    , act
    , actBounded
    , await
    , murder
    , receiveSTM
    , sendChecked
    )
import Control.Concurrent.MVar
    (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
    ( TVar
    , atomically
    , modifyTVar'
    , newTVarIO
    , orElse
    , readTVar
    , writeTVar
    )
import qualified Control.Concurrent.STM.TQueue as TQueue
import Control.Exception (bracket_, evaluate, try)
import Control.Monad (forM, forM_, forever, replicateM, when)
import Control.Monad.IO.Class (liftIO)
import Data.Char (toLower)
import Data.List (intercalate, isInfixOf, sort)
import qualified Data.Queue as Queue
import Data.Version (showVersion)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats
    (gc, gcdetails_live_bytes, getRTSStats, getRTSStatsEnabled)
import Numeric (showFFloat)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO
    ( BufferMode(NoBuffering)
    , hFlush
    , hGetBuffering
    , hGetChar
    , hGetEcho
    , hIsTerminalDevice
    , hPutStrLn
    , hSetBuffering
    , hSetEcho
    , stderr
    , stdin
    , stdout
    )
import System.Info (arch, compilerName, compilerVersion, os)
import System.Mem (performGC)
import System.Timeout (timeout)

data Mode = Automatic | Interactive | Json
  deriving (Eq, Show)

data Options = Options
  { optionMode :: Mode
  , optionQuick :: Bool
  , optionNoColor :: Bool
  }

data DemoConfig = DemoConfig
  { configBurstSizes :: [Int]
  , configBurstSamples :: Int
  , configPressureDurationMicros :: Int
  , configPressureMessageLimit :: Int
  , configPressureProducers :: Int
  , configConsumerDelayMicros :: Int
  , configPressureTickMicros :: Int
  , configFailureSenders :: Int
  , configFailureSettleMicros :: Int
  , configShortPauseMicros :: Int
  , configLongPauseMicros :: Int
  }
  deriving (Eq, Show)

normalConfig :: DemoConfig
normalConfig = DemoConfig
  { configBurstSizes = [1000, 10000, 100000]
  , configBurstSamples = 11
  , configPressureDurationMicros = 3000000
  , configPressureMessageLimit = 250000
  , configPressureProducers = 4
  , configConsumerDelayMicros = 1000
  , configPressureTickMicros = 100000
  , configFailureSenders = 12
  , configFailureSettleMicros = 100000
  , configShortPauseMicros = 1500000
  , configLongPauseMicros = 3500000
  }

quickConfig :: DemoConfig
quickConfig = DemoConfig
  { configBurstSizes = [100, 1000, 10000]
  , configBurstSamples = 3
  , configPressureDurationMicros = 150000
  , configPressureMessageLimit = 5000
  , configPressureProducers = 2
  , configConsumerDelayMicros = 1000
  , configPressureTickMicros = 20000
  , configFailureSenders = 4
  , configFailureSettleMicros = 10000
  , configShortPauseMicros = 0
  , configLongPauseMicros = 0
  }

data LatencySummary = LatencySummary
  { latencyMedianNs :: Word64
  , latencyP95Ns :: Word64
  , latencyMaximumNs :: Word64
  }
  deriving (Eq, Show)

data BurstResult = BurstResult
  { burstSize :: Int
  , burstBatchSize :: Int
  , queueSamplesNs :: [Word64]
  , tQueueSamplesNs :: [Word64]
  , queueSummary :: LatencySummary
  , tQueueSummary :: LatencySummary
  }
  deriving (Eq, Show)

data QueueKind = UnboundedActor | BoundedActor
  deriving (Eq, Show)

data PressureSnapshot = PressureSnapshot
  { snapshotElapsedNs :: Word64
  , snapshotSent :: Int
  , snapshotClaimed :: Int
  , snapshotQueued :: Int
  , snapshotActiveSenders :: Int
  }
  deriving (Eq, Show)

data PressureResult = PressureResult
  { pressureKind :: QueueKind
  , pressureCapacity :: Maybe Int
  , pressureSent :: Int
  , pressureClaimed :: Int
  , pressureQueued :: Int
  , pressurePeakSenders :: Int
  , pressureBackpressuredSends :: Int
  , pressureHeapDeltaBytes :: Maybe Word64
  }
  deriving (Eq, Show)

data BackpressureResult = BackpressureResult
  { unboundedResult :: PressureResult
  , boundedResult :: PressureResult
  }
  deriving (Eq, Show)

data FailureResult = FailureResult
  { failureSenders :: Int
  , failureRejected :: Int
  , failureUnexpected :: Int
  , failureBlockedCommitted :: Int
  , failureAcceptedTotal :: Int
  , failureInitiallyFull :: Bool
  , failureWakeNs :: Word64
  }
  deriving (Eq, Show)

data DemoReport = DemoReport
  { reportConfig :: DemoConfig
  , reportCapabilities :: Int
  , reportBursts :: [BurstResult]
  , reportBackpressure :: BackpressureResult
  , reportFailure :: FailureResult
  }
  deriving (Eq, Show)

data Palette = Palette
  { paletteAnsi :: Bool
  }

runCLI :: [String] -> IO ()
runCLI arguments =
  case parseOptions arguments of
    Left problem -> do
      hPutStrLn stderr problem
      hPutStrLn stderr usage
      exitFailure
    Right Nothing -> putStrLn usage
    Right (Just options) -> do
      let config = if optionQuick options then quickConfig else normalConfig
      case optionMode options of
        Json -> runJson config
        Automatic -> do
          palette <- detectPalette (optionNoColor options)
          runAutomatic config palette
        Interactive -> do
          interactiveInput <- hIsTerminalDevice stdin
          interactiveOutput <- hIsTerminalDevice stdout
          if interactiveInput && interactiveOutput
            then do
              palette <- detectPalette (optionNoColor options)
              runInteractive config palette
            else do
              hPutStrLn stderr
                "--interactive requires a terminal on standard input and output"
              exitFailure

parseOptions :: [String] -> Either String (Maybe Options)
parseOptions arguments
  | "--help" `elem` arguments = Right Nothing
  | firstUnknown : _ <- unknown = Left ("unknown option: " <> firstUnknown)
  | length selectedModes > 1 = Left "choose only one presentation mode"
  | otherwise = Right (Just Options
      { optionMode = case selectedModes of
          [] -> Automatic
          mode : _ -> mode
      , optionQuick = "--quick" `elem` arguments
      , optionNoColor = "--no-color" `elem` arguments
      })
  where
    known = ["--auto", "--interactive", "--json", "--quick", "--no-color"]
    unknown = filter (`notElem` known) arguments
    selectedModes =
      [ mode
      | (flag, mode) <-
          [ ("--auto", Automatic)
          , ("--interactive", Interactive)
          , ("--json", Json)
          ]
      , flag `elem` arguments
      ]

usage :: String
usage = unlines
  [ "Mailbox Wind Tunnel"
  , ""
  , "Usage: mailbox-wind-tunnel [--auto|--interactive|--json] [--quick] [--no-color]"
  , ""
  , "  --auto         roughly 30-second automatic presentation (default)"
  , "  --interactive  use b/p/k/a/q controls in a terminal"
  , "  --json         emit raw measurements as one JSON document"
  , "  --quick        use the short deterministic smoke-test configuration"
  , "  --no-color     disable ANSI color and screen control"
  , "  --help         show this help"
  ]

detectPalette :: Bool -> IO Palette
detectPalette explicitlyDisabled = do
  terminal <- hIsTerminalDevice stdout
  noColor <- lookupEnv "NO_COLOR"
  pure Palette
    { paletteAnsi = terminal && not explicitlyDisabled && noColor == Nothing
    }

runJson :: DemoConfig -> IO ()
runJson config = do
  report <- collectReport config
  case validateReport report of
    Left problem -> ioError (userError problem)
    Right () -> putStrLn (reportJson report)

collectReport :: DemoConfig -> IO DemoReport
collectReport config = do
  capabilities <- getNumCapabilities
  bursts <- forM (configBurstSizes config) \size ->
    measureBurst size (configBurstSamples config) (const (const (pure ())))
  backpressure <- runBackpressure config (const (const (pure ())))
  failure <- runFailure config (const (pure ()))
  pure DemoReport
    { reportConfig = config
    , reportCapabilities = capabilities
    , reportBursts = bursts
    , reportBackpressure = backpressure
    , reportFailure = failure
    }

quickSmoke :: IO (Either String ())
quickSmoke = do
  report <- collectReport quickConfig
  pure do
    validateReport report
    let encoded = reportJson report
    require ("\"schemaVersion\":1" `isInfixOf` encoded)
      "JSON report is missing its schema version"
    require ("\"backpressure\"" `isInfixOf` encoded)
      "JSON report is missing the backpressure phase"

measureBurst
  :: Int
  -> Int
  -> (Int -> Int -> IO ())
  -> IO BurstResult
measureBurst itemCount sampleCount progress = do
  let batchSize = latencyBatchSize itemCount
  _ <- measureQueueFirstReads (min 100 itemCount) 1
  _ <- measureTQueueFirstReads (min 100 itemCount) 1
  samples <- forM [1 .. sampleCount] \sampleNumber -> do
    pair <- if odd sampleNumber
      then do
        queueTime <- measureQueueFirstReads itemCount batchSize
        tQueueTime <- measureTQueueFirstReads itemCount batchSize
        pure (queueTime, tQueueTime)
      else do
        tQueueTime <- measureTQueueFirstReads itemCount batchSize
        queueTime <- measureQueueFirstReads itemCount batchSize
        pure (queueTime, tQueueTime)
    progress sampleNumber sampleCount
    pure pair
  let (queueTimes, tQueueTimes) = unzip samples
  pure BurstResult
    { burstSize = itemCount
    , burstBatchSize = batchSize
    , queueSamplesNs = queueTimes
    , tQueueSamplesNs = tQueueTimes
    , queueSummary = summarizeLatency queueTimes
    , tQueueSummary = summarizeLatency tQueueTimes
    }

latencyBatchSize :: Int -> Int
latencyBatchSize itemCount =
  max 10 (min 500 (200000 `div` max 1 itemCount))

measureQueueFirstReads :: Int -> Int -> IO Word64
measureQueueFirstReads itemCount batchSize = do
  performGC
  queues <- replicateM batchSize $ atomically do
    queue <- Queue.newQueue
    forM_ [1 .. itemCount] (Queue.enqueue queue)
    pure queue
  started <- getMonotonicTimeNSec
  forM_ queues \queue -> do
    value <- atomically (Queue.dequeue queue)
    _ <- evaluate value
    pure ()
  finished <- getMonotonicTimeNSec
  pure ((finished - started) `div` fromIntegral batchSize)

measureTQueueFirstReads :: Int -> Int -> IO Word64
measureTQueueFirstReads itemCount batchSize = do
  performGC
  queues <- replicateM batchSize $ atomically do
    queue <- TQueue.newTQueue
    forM_ [1 .. itemCount] (TQueue.writeTQueue queue)
    pure queue
  started <- getMonotonicTimeNSec
  forM_ queues \queue -> do
    value <- atomically (TQueue.readTQueue queue)
    _ <- evaluate value
    pure ()
  finished <- getMonotonicTimeNSec
  pure ((finished - started) `div` fromIntegral batchSize)

summarizeLatency :: [Word64] -> LatencySummary
summarizeLatency samples = LatencySummary
  { latencyMedianNs = percentile 0.50 samples
  , latencyP95Ns = percentile 0.95 samples
  , latencyMaximumNs = if null samples then 0 else maximum samples
  }

percentile :: Double -> [Word64] -> Word64
percentile _ [] = 0
percentile fraction values = ordered !! index
  where
    ordered = sort values
    rawIndex = ceiling (fraction * fromIntegral (length ordered)) - 1
    index = max 0 (min (length ordered - 1) rawIndex)

runBackpressure
  :: DemoConfig
  -> (QueueKind -> PressureSnapshot -> IO ())
  -> IO BackpressureResult
runBackpressure config observer = do
  unbounded <- runPressureScenario config UnboundedActor observer
  bounded <- runPressureScenario config BoundedActor observer
  pure BackpressureResult
    { unboundedResult = unbounded
    , boundedResult = bounded
    }

runPressureScenario
  :: DemoConfig
  -> QueueKind
  -> (QueueKind -> PressureSnapshot -> IO ())
  -> IO PressureResult
runPressureScenario config kind observer = do
  baselineBytes <- liveBytesAfterGC
  sent <- newTVarIO 0
  claimed <- newTVarIO 0
  nextMessage <- newTVarIO 0
  stopProducers <- newTVarIO False
  activeSenders <- newTVarIO 0
  peakSenders <- newTVarIO 0
  backpressuredSends <- newTVarIO 0
  actor <- case kind of
    UnboundedActor -> act (pressureConsumer claimed config)
    BoundedActor -> actBounded 256 (pressureConsumer claimed config)
  producerDone <- forM [1 .. configPressureProducers config] \_ ->
    spawnProducer
      actor
      sent
      nextMessage
      stopProducers
      activeSenders
      peakSenders
      backpressuredSends
      (configPressureMessageLimit config)
  started <- getMonotonicTimeNSec
  let deadline = started + microsToNs (configPressureDurationMicros config)
      sampleLoop = do
        now <- getMonotonicTimeNSec
        snapshot <- readPressureSnapshot started now sent claimed activeSenders
        observer kind snapshot
        if now >= deadline
          then pure ()
          else threadDelay (configPressureTickMicros config) >> sampleLoop
  sampleLoop
  atomically (writeTVar stopProducers True)
  mapM_ (waitForMVar "pressure producer") producerDone
  heapBytes <- liveBytesAfterGC
  now <- getMonotonicTimeNSec
  finalSnapshot <- readPressureSnapshot started now sent claimed activeSenders
  observer kind finalSnapshot
  peak <- atomically (readTVar peakSenders)
  slowSends <- atomically (readTVar backpressuredSends)
  let heapDelta = subtractMaybe baselineBytes heapBytes
  murder actor
  _ <- waitForIO "pressure actor shutdown" (atomically (await actor))
  performGC
  pure PressureResult
    { pressureKind = kind
    , pressureCapacity = case kind of
        UnboundedActor -> Nothing
        BoundedActor -> Just 256
    , pressureSent = snapshotSent finalSnapshot
    , pressureClaimed = snapshotClaimed finalSnapshot
    , pressureQueued = snapshotQueued finalSnapshot
    , pressurePeakSenders = peak
    , pressureBackpressuredSends = slowSends
    , pressureHeapDeltaBytes = heapDelta
    }

pressureConsumer :: TVar Int -> DemoConfig -> ActionT Int IO ()
pressureConsumer claimed config = forever do
  receiveSTM \_ -> modifyTVar' claimed (+ 1)
  liftIO (threadDelay (configConsumerDelayMicros config))

spawnProducer
  :: Actor Int
  -> TVar Int
  -> TVar Int
  -> TVar Bool
  -> TVar Int
  -> TVar Int
  -> TVar Int
  -> Int
  -> IO (MVar ())
spawnProducer
    actor
    sent
    nextMessage
    stopProducers
    activeSenders
    peakSenders
    backpressuredSends
    messageLimit = do
  done <- newEmptyMVar
  _ <- forkFinally loop (const (putMVar done ()))
  pure done
  where
    loop = do
      started <- getMonotonicTimeNSec
      result <- bracket_ beginAttempt endAttempt
        (tryActorDeadIO (atomically sendOne))
      finished <- getMonotonicTimeNSec
      case result of
        Right True -> do
          when (finished - started >= 500000) $
            atomically (modifyTVar' backpressuredSends (+ 1))
          loop
        Right False -> pure ()
        Left _ -> pure ()

    beginAttempt = atomically do
      current <- readTVar activeSenders
      let next = current + 1
      writeTVar activeSenders next
      modifyTVar' peakSenders (max next)

    endAttempt = atomically (modifyTVar' activeSenders (subtract 1))

    sendOne = do
      stopping <- readTVar stopProducers
      if stopping
        then pure False
        else do
          next <- readTVar nextMessage
          if next >= messageLimit
            then pure False
            else do
              sendChecked actor next
              writeTVar nextMessage (next + 1)
              modifyTVar' sent (+ 1)
              pure True

readPressureSnapshot
  :: Word64
  -> Word64
  -> TVar Int
  -> TVar Int
  -> TVar Int
  -> IO PressureSnapshot
readPressureSnapshot started now sent claimed activeSenders = do
  (sentCount, claimedCount, activeCount) <- atomically do
    sentCount <- readTVar sent
    claimedCount <- readTVar claimed
    activeCount <- readTVar activeSenders
    pure (sentCount, claimedCount, activeCount)
  pure PressureSnapshot
    { snapshotElapsedNs = now - started
    , snapshotSent = sentCount
    , snapshotClaimed = claimedCount
    , snapshotQueued = max 0 (sentCount - claimedCount)
    , snapshotActiveSenders = activeCount
    }

runFailure :: DemoConfig -> (Int -> IO ()) -> IO FailureResult
runFailure config armed = do
  blocker <- newEmptyMVar
  accepted <- newTVarIO 0
  actor <- actBounded 1 (liftIO (takeMVar blocker))
  atomically do
    sendChecked actor 0
    modifyTVar' accepted (+ 1)
  initiallyFull <- atomically
    ((sendChecked actor (-1) >> pure False) `orElse` pure True)
  senders <- forM [1 .. configFailureSenders config] \message -> do
    ready <- newEmptyMVar
    outcome <- newEmptyMVar
    _ <- forkFinally
      (do
        putMVar ready ()
        tryActorDeadIO $ atomically do
          sendChecked actor message
          modifyTVar' accepted (+ 1))
      (putMVar outcome)
    pure (ready, outcome)
  mapM_ (waitForMVar "blocked sender readiness" . fst) senders
  threadDelay (configFailureSettleMicros config)
  armed (length senders)
  killStarted <- getMonotonicTimeNSec
  murder actor
  _ <- waitForIO "failure actor shutdown" (atomically (await actor))
  outcomes <- mapM (waitForMVar "blocked sender result" . snd) senders
  killFinished <- getMonotonicTimeNSec
  acceptedCount <- atomically (readTVar accepted)
  let rejected = length [() | Right (Left _) <- outcomes]
      committed = length [() | Right (Right ()) <- outcomes]
      unexpected = length [() | Left _ <- outcomes]
  pure FailureResult
    { failureSenders = length senders
    , failureRejected = rejected
    , failureUnexpected = unexpected
    , failureBlockedCommitted = committed
    , failureAcceptedTotal = acceptedCount
    , failureInitiallyFull = initiallyFull
    , failureWakeNs = killFinished - killStarted
    }

tryActorDeadIO :: IO a -> IO (Either ActorDead a)
tryActorDeadIO = try

waitForMVar :: String -> MVar a -> IO a
waitForMVar label = waitForIO label . takeMVar

waitForIO :: String -> IO a -> IO a
waitForIO label action = timeout 5000000 action >>= \case
  Nothing -> ioError (userError ("timed out waiting for " <> label))
  Just result -> pure result

liveBytesAfterGC :: IO (Maybe Word64)
liveBytesAfterGC = do
  performGC
  enabled <- getRTSStatsEnabled
  if enabled
    then Just . gcdetails_live_bytes . gc <$> getRTSStats
    else pure Nothing

subtractMaybe :: Maybe Word64 -> Maybe Word64 -> Maybe Word64
subtractMaybe (Just before) (Just after) = Just (after - min before after)
subtractMaybe _ _ = Nothing

microsToNs :: Int -> Word64
microsToNs micros = fromIntegral micros * 1000

runAutomatic :: DemoConfig -> Palette -> IO ()
runAutomatic config palette = withHiddenCursor palette do
  clearScreen palette
  putStrLn (title palette)
  putStrLn "A live, measured tour of queue latency, pressure, and actor death."
  putStrLn "“Real-time” here means incremental queue work, not OS scheduling."
  pauseLong config

  phase palette 1 "BURST LATENCY"
  putStrLn "Alternating isolated batches; only first-dequeue operations are timed."
  putStrLn "This isolates structural latency; it is not a throughput claim."
  bursts <- forM (configBurstSizes config) \size -> do
    result <- measureBurst size (configBurstSamples config) $
      renderBurstProgress palette size
    clearProgress palette
    renderBurst palette result
    pauseShort config
    pure result
  pauseLong config

  phase palette 2 "BACKPRESSURE DAM"
  putStrLn "The same slow consumer faces unbounded producers, then capacity 256."
  backpressure <- runBackpressure config (renderPressureLive palette)
  clearProgress palette
  renderBackpressure palette backpressure
  pauseLong config

  phase palette 3 "FAILURE UNDER PRESSURE"
  putStrLn "A full actor is killed while checked senders are blocked in STM."
  failure <- runFailure config \count -> do
    putStrLn (paint palette "33" ("  armed " <> show count <> " blocked senders"))
  renderFailure palette failure
  pauseLong config

  capabilities <- getNumCapabilities
  let report = DemoReport
        { reportConfig = config
        , reportCapabilities = capabilities
        , reportBursts = bursts
        , reportBackpressure = backpressure
        , reportFailure = failure
        }
  case validateReport report of
    Left problem -> ioError (userError problem)
    Right () -> do
      putStrLn ""
      putStrLn (paint palette "1;32" "WIND TUNNEL COMPLETE — all accounting invariants held")
      putStrLn "Reproduce every raw sample with: mailbox-wind-tunnel --json"

runInteractive :: DemoConfig -> Palette -> IO ()
runInteractive config palette = withInteractiveTerminal palette (loop 0)
  where
    sizes = configBurstSizes config
    loop burstIndex = do
      clearScreen palette
      putStrLn (title palette)
      putStrLn ""
      putStrLn "  b  next burst-latency trial"
      putStrLn "  p  backpressure dam"
      putStrLn "  k  kill a full actor"
      putStrLn "  a  automatic presentation"
      putStrLn "  q  quit"
      putStr "\ncontrol> "
      command <- toLower <$> hGetChar stdin
      case command of
        'q' -> pure ()
        'b' -> do
          let size = sizes !! (burstIndex `mod` length sizes)
          clearScreen palette
          phase palette 1 "BURST LATENCY"
          result <- measureBurst size (configBurstSamples config) $
            renderBurstProgress palette size
          clearProgress palette
          renderBurst palette result
          waitForKey
          loop (burstIndex + 1)
        'p' -> do
          clearScreen palette
          phase palette 2 "BACKPRESSURE DAM"
          result <- runBackpressure config (renderPressureLive palette)
          clearProgress palette
          renderBackpressure palette result
          waitForKey
          loop burstIndex
        'k' -> do
          clearScreen palette
          phase palette 3 "FAILURE UNDER PRESSURE"
          result <- runFailure config \count ->
            putStrLn ("  armed " <> show count <> " blocked senders")
          renderFailure palette result
          waitForKey
          loop burstIndex
        'a' -> do
          runAutomatic config palette
          waitForKey
          loop burstIndex
        _ -> loop burstIndex

    waitForKey = do
      putStr "\npress any key to return to controls"
      _ <- hGetChar stdin
      pure ()

withInteractiveTerminal :: Palette -> IO a -> IO a
withInteractiveTerminal palette action = do
  inputBuffering <- hGetBuffering stdin
  outputBuffering <- hGetBuffering stdout
  inputEcho <- hGetEcho stdin
  bracket_
    (do
      hSetBuffering stdin NoBuffering
      hSetBuffering stdout NoBuffering
      hSetEcho stdin False
      hideCursor palette)
    (do
      showCursor palette
      hSetEcho stdin inputEcho
      hSetBuffering stdin inputBuffering
      hSetBuffering stdout outputBuffering)
    action

withHiddenCursor :: Palette -> IO a -> IO a
withHiddenCursor palette = bracket_ (hideCursor palette) (showCursor palette)

hideCursor :: Palette -> IO ()
hideCursor palette = when (paletteAnsi palette) (putStr "\ESC[?25l" >> hFlush stdout)

showCursor :: Palette -> IO ()
showCursor palette = when (paletteAnsi palette) (putStr "\ESC[?25h" >> hFlush stdout)

clearScreen :: Palette -> IO ()
clearScreen palette
  | paletteAnsi palette = putStr "\ESC[2J\ESC[H"
  | otherwise = putStrLn ""

clearProgress :: Palette -> IO ()
clearProgress palette = putStr (progressPrefix palette) >> hFlush stdout

progressPrefix :: Palette -> String
progressPrefix palette
  | paletteAnsi palette = "\r\ESC[2K"
  | otherwise = "\r"

title :: Palette -> String
title palette = paint palette "1;36" "MAILBOX WIND TUNNEL"

phase :: Palette -> Int -> String -> IO ()
phase palette number label = do
  putStrLn ""
  putStrLn (paint palette "1;35" ("PHASE " <> show number <> "/3 — " <> label))

renderBurstProgress :: Palette -> Int -> Int -> Int -> IO ()
renderBurstProgress palette size completed total = do
  putStr
    ( progressPrefix palette
    <> "  measuring burst " <> show size
    <> "  sample " <> show completed <> "/" <> show total
    )
  hFlush stdout

renderBurst :: Palette -> BurstResult -> IO ()
renderBurst palette result = do
  let queueMedian = latencyMedianNs (queueSummary result)
      tQueueMedian = latencyMedianNs (tQueueSummary result)
      largest = max 1 (max queueMedian tQueueMedian)
  putStrLn
    ( "  burst " <> show (burstSize result)
    <> "  (" <> show (burstBatchSize result) <> " first-dequeue trials/sample)"
    )
  putStrLn
    ( "    TQueue      "
    <> paint palette "31" (bar 34 tQueueMedian largest)
    <> "  " <> formatNs tQueueMedian
    <> " median  p95 " <> formatNs (latencyP95Ns (tQueueSummary result))
    )
  putStrLn
    ( "    stm-queue   "
    <> paint palette "32" (bar 34 queueMedian largest)
    <> "  " <> formatNs queueMedian
    <> " median  p95 " <> formatNs (latencyP95Ns (queueSummary result))
    )
  putStrLn
    ( "    median ratio TQueue/stm-queue: "
    <> formatRatio tQueueMedian queueMedian
    )

renderPressureLive :: Palette -> QueueKind -> PressureSnapshot -> IO ()
renderPressureLive palette kind snapshot = do
  putStr
    ( progressPrefix palette
    <> "  " <> queueKindLabel kind
    <> "  queued " <> padLeft 7 (show (snapshotQueued snapshot))
    <> "  committed " <> padLeft 7 (show (snapshotSent snapshot))
    <> "  senders in STM " <> show (snapshotActiveSenders snapshot)
    <> "  elapsed " <> formatNs (snapshotElapsedNs snapshot)
    )
  hFlush stdout

renderBackpressure :: Palette -> BackpressureResult -> IO ()
renderBackpressure palette BackpressureResult{unboundedResult, boundedResult} = do
  let largest = max 1 (max (pressureQueued unboundedResult) (pressureQueued boundedResult))
  putStrLn "  final live queue depth"
  renderOne "unbounded" "31" largest unboundedResult
  renderOne "bounded 256" "32" largest boundedResult
  putStrLn
    ( "  heap retained by queued work: "
    <> formatMaybeBytes (pressureHeapDeltaBytes unboundedResult)
    <> " unbounded, "
    <> formatMaybeBytes (pressureHeapDeltaBytes boundedResult)
    <> " bounded"
    )
  putStrLn
    ( "  sends delayed ≥0.5 ms: "
    <> show (pressureBackpressuredSends unboundedResult)
    <> " unbounded, "
    <> show (pressureBackpressuredSends boundedResult)
    <> " bounded"
    )
  where
    renderOne label colorCode largest result =
      putStrLn
        ( "    " <> padRight 12 label
        <> paint palette colorCode
            (barInt 34 (pressureQueued result) largest)
        <> "  " <> show (pressureQueued result)
        )

renderFailure :: Palette -> FailureResult -> IO ()
renderFailure palette result = do
  putStrLn
    ( "  " <> paint palette "32" (show (failureRejected result))
    <> "/" <> show (failureSenders result)
    <> " blocked transactions woke with ActorDead"
    )
  putStrLn
    ( "  wake-and-reject interval: " <> formatNs (failureWakeNs result)
    <> "   blocked sends committed: " <> show (failureBlockedCommitted result)
    )
  putStrLn
    ( "  accepted-message ledger: " <> show (failureAcceptedTotal result)
    <> " (the one message committed before the mailbox filled)"
    )

bar :: Int -> Word64 -> Word64 -> String
bar width value largest = barInt width (fromIntegral value) (fromIntegral largest)

barInt :: Int -> Int -> Int -> String
barInt width value largest =
  replicate filled '█' <> replicate (width - filled) '·'
  where
    filled
      | value <= 0 = 0
      | otherwise = max 1 (min width (value * width `div` max 1 largest))

paint :: Palette -> String -> String -> String
paint palette code value
  | paletteAnsi palette = "\ESC[" <> code <> "m" <> value <> "\ESC[0m"
  | otherwise = value

padLeft :: Int -> String -> String
padLeft width value = replicate (max 0 (width - length value)) ' ' <> value

padRight :: Int -> String -> String
padRight width value = value <> replicate (max 0 (width - length value)) ' '

formatNs :: Word64 -> String
formatNs nanoseconds
  | nanoseconds < 1000 = show nanoseconds <> " ns"
  | nanoseconds < 1000000 = decimal 1 (fromIntegral nanoseconds / 1000) <> " μs"
  | nanoseconds < 1000000000 = decimal 2 (fromIntegral nanoseconds / 1000000) <> " ms"
  | otherwise = decimal 2 (fromIntegral nanoseconds / 1000000000) <> " s"

formatRatio :: Word64 -> Word64 -> String
formatRatio numerator denominator
  | denominator == 0 = "n/a"
  | otherwise = decimal 2 (fromIntegral numerator / fromIntegral denominator) <> "×"

formatMaybeBytes :: Maybe Word64 -> String
formatMaybeBytes Nothing = "unavailable"
formatMaybeBytes (Just bytes)
  | bytes < 1024 = show bytes <> " B"
  | bytes < 1048576 = decimal 1 (fromIntegral bytes / 1024) <> " KiB"
  | otherwise = decimal 1 (fromIntegral bytes / 1048576) <> " MiB"

decimal :: Int -> Double -> String
decimal places value = showFFloat (Just places) value ""

queueKindLabel :: QueueKind -> String
queueKindLabel UnboundedActor = "unbounded "
queueKindLabel BoundedActor = "bounded 256"

pauseShort :: DemoConfig -> IO ()
pauseShort = pause . configShortPauseMicros

pauseLong :: DemoConfig -> IO ()
pauseLong = pause . configLongPauseMicros

pause :: Int -> IO ()
pause microseconds = when (microseconds > 0) (threadDelay microseconds)

validateReport :: DemoReport -> Either String ()
validateReport DemoReport
    {reportConfig, reportCapabilities, reportBursts, reportBackpressure, reportFailure} = do
  require (reportCapabilities > 0) "runtime reported no capabilities"
  require (not (null reportBursts)) "burst phase produced no results"
  require (map burstSize reportBursts == configBurstSizes reportConfig)
    "burst results do not match the requested configuration"
  mapM_ validateBurst reportBursts
  validatePressure (unboundedResult reportBackpressure)
  validatePressure (boundedResult reportBackpressure)
  case pressureCapacity (boundedResult reportBackpressure) of
    Nothing -> Left "bounded pressure result has no capacity"
    Just capacity -> require
      (pressureQueued (boundedResult reportBackpressure) <= capacity)
      "bounded queue exceeded its capacity"
  require (failureInitiallyFull reportFailure)
    "failure phase did not begin with a full mailbox"
  require (failureRejected reportFailure == failureSenders reportFailure)
    "not every blocked sender observed ActorDead"
  require (failureUnexpected reportFailure == 0)
    "a blocked sender failed with an unexpected exception"
  require (failureBlockedCommitted reportFailure == 0)
    "a blocked send committed after the mailbox was full"
  require (failureAcceptedTotal reportFailure == 1)
    "accepted-message ledger diverged"
  where
    validateBurst BurstResult
        {burstSize, burstBatchSize, queueSamplesNs, tQueueSamplesNs} = do
      require (burstSize > 0) "burst size is not positive"
      require (burstBatchSize > 0) "burst batch size is not positive"
      require (not (null queueSamplesNs)) "stm-queue produced no samples"
      require (length queueSamplesNs == length tQueueSamplesNs)
        "burst implementations produced different sample counts"

    validatePressure result = do
      require (pressureSent result >= pressureClaimed result)
        "pressure consumer claimed more messages than producers committed"
      require
        (pressureQueued result == pressureSent result - pressureClaimed result)
        "pressure queue-depth accounting diverged"

require :: Bool -> String -> Either String ()
require condition problem = if condition then Right () else Left problem

reportJson :: DemoReport -> String
reportJson DemoReport
    {reportConfig, reportCapabilities, reportBursts, reportBackpressure, reportFailure} =
  jsonObject
    [ ("schemaVersion", "1")
    , ("realTimeMeaning", jsonString "algorithmic queue work, not wall-clock scheduling")
    , ("runtime", runtimeJson reportCapabilities)
    , ("config", configJson reportConfig)
    , ("bursts", jsonArray (map burstJson reportBursts))
    , ("backpressure", backpressureJson reportBackpressure)
    , ("failure", failureJson reportFailure)
    ]

runtimeJson :: Int -> String
runtimeJson capabilities = jsonObject
  [ ("compiler", jsonString compilerName)
  , ("compilerVersion", jsonString (showVersion compilerVersion))
  , ("os", jsonString os)
  , ("arch", jsonString arch)
  , ("capabilities", show capabilities)
  ]

configJson :: DemoConfig -> String
configJson config = jsonObject
  [ ("burstSizes", jsonArray (map show (configBurstSizes config)))
  , ("burstSamples", show (configBurstSamples config))
  , ("pressureDurationMicros", show (configPressureDurationMicros config))
  , ("pressureMessageLimit", show (configPressureMessageLimit config))
  , ("pressureProducers", show (configPressureProducers config))
  , ("consumerDelayMicros", show (configConsumerDelayMicros config))
  , ("failureSenders", show (configFailureSenders config))
  , ("failureSettleMicros", show (configFailureSettleMicros config))
  ]

burstJson :: BurstResult -> String
burstJson BurstResult
    { burstSize
    , burstBatchSize
    , queueSamplesNs
    , tQueueSamplesNs
    , queueSummary
    , tQueueSummary
    } =
  jsonObject
    [ ("size", show burstSize)
    , ("firstDequeueTrialsPerSample", show burstBatchSize)
    , ("stmQueue", latencyJson queueSummary queueSamplesNs)
    , ("tQueue", latencyJson tQueueSummary tQueueSamplesNs)
    ]

latencyJson :: LatencySummary -> [Word64] -> String
latencyJson summary samples = jsonObject
  [ ("medianNs", show (latencyMedianNs summary))
  , ("p95Ns", show (latencyP95Ns summary))
  , ("maximumNs", show (latencyMaximumNs summary))
  , ("samplesNs", jsonArray (map show samples))
  ]

backpressureJson :: BackpressureResult -> String
backpressureJson BackpressureResult{unboundedResult, boundedResult} =
  jsonObject
    [ ("unbounded", pressureJson unboundedResult)
    , ("bounded", pressureJson boundedResult)
    ]

pressureJson :: PressureResult -> String
pressureJson result = jsonObject
  [ ("kind", jsonString (queueKindJson (pressureKind result)))
  , ("capacity", maybe "null" show (pressureCapacity result))
  , ("sent", show (pressureSent result))
  , ("claimed", show (pressureClaimed result))
  , ("queued", show (pressureQueued result))
  , ("peakSendersInSTM", show (pressurePeakSenders result))
  , ("sendsDelayedAtLeast500us", show (pressureBackpressuredSends result))
  , ("heapDeltaBytes", maybe "null" show (pressureHeapDeltaBytes result))
  ]

queueKindJson :: QueueKind -> String
queueKindJson UnboundedActor = "unbounded"
queueKindJson BoundedActor = "bounded"

failureJson :: FailureResult -> String
failureJson result = jsonObject
  [ ("senders", show (failureSenders result))
  , ("rejectedWithActorDead", show (failureRejected result))
  , ("unexpectedFailures", show (failureUnexpected result))
  , ("blockedSendsCommitted", show (failureBlockedCommitted result))
  , ("acceptedLedger", show (failureAcceptedTotal result))
  , ("initiallyFull", jsonBool (failureInitiallyFull result))
  , ("wakeNs", show (failureWakeNs result))
  ]

jsonObject :: [(String, String)] -> String
jsonObject fields =
  "{" <> intercalate "," [jsonString key <> ":" <> value | (key, value) <- fields] <> "}"

jsonArray :: [String] -> String
jsonArray values = "[" <> intercalate "," values <> "]"

jsonString :: String -> String
jsonString = show

jsonBool :: Bool -> String
jsonBool True = "true"
jsonBool False = "false"
