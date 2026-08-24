{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Control.Concurrent (forkIO)
import Control.Concurrent.Actor
import Control.Concurrent.MVar
    (MVar, newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Control.Concurrent.STM
    (atomically, newTVarIO, orElse, readTVar, retry, writeTVar)
import Control.Exception
    ( ArithException(Underflow)
    , AsyncException(ThreadKilled)
    , BlockedIndefinitelyOnSTM(BlockedIndefinitelyOnSTM)
    , SomeException
    , fromException
    , throwIO
    , try
    , uninterruptibleMask_
    )
import Control.Monad (forM_, replicateM, replicateM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, runReaderT)
import Data.Functor.Contravariant (contramap)
import Data.IORef
import System.Mem (performMajorGC)
import System.Timeout
import Test.Hspec

main :: IO ()
main = hspec do
  describe "Control.Concurrent.Actor" do
    describe "actFinally" do
      it "runs its handler on success" do
        result <- newEmptyMVar
        _ <- actFinally (putMVar result) (pure ())
        outcome <- within "successful actFinally handler" (takeMVar result)
        outcome `shouldSatisfy` isSuccess

      it "runs its handler on error" do
        result <- newEmptyMVar
        _ <- actFinally (putMVar result) (liftIO (throwIO Underflow :: IO ()))
        outcome <- within "failing actFinally handler" (takeMVar result)
        outcome `shouldSatisfy` isUnderflow

    describe "addAfterEffect" do
      it "runs later effects when an earlier effect throws" do
        release <- newEmptyMVar
        laterEffect <- newEmptyMVar
        actor <- act (liftIO (takeMVar release))
        atomically do
          addAfterEffect actor (const (throwIO ThreadKilled))
          addAfterEffect actor (const (putMVar laterEffect ()))
        putMVar release ()
        within "later after-effect" (takeMVar laterEffect)
          `shouldReturn` ()

      it "runs after-effects when the completion handler throws" do
        release <- newEmptyMVar
        laterEffect <- newEmptyMVar
        actor <- actFinally (const (throwIO ThreadKilled))
          (liftIO (takeMVar release))
        atomically $ addAfterEffect actor (const (putMVar laterEffect ()))
        putMVar release ()
        within "after-effect following completion-handler failure"
          (takeMVar laterEffect) `shouldReturn` ()

      it "drains large effect sets without a deep callback chain" do
        release <- newEmptyMVar
        effectCount <- newIORef (0 :: Int)
        finished <- newEmptyMVar
        actor <- act (liftIO (takeMVar release))
        atomically do
          replicateM_ 10000 $ addAfterEffect actor $ const $
            atomicModifyIORef' effectCount (\count -> (count + 1, ()))
          addAfterEffect actor (const (putMVar finished ()))
        putMVar release ()
        within "large after-effect set" (takeMVar finished) `shouldReturn` ()
        readIORef effectCount `shouldReturn` 10000

      it "is lifecycle-checked by default, with an unchecked variant" do
        actor <- act (pure ())
        _ <- within "actor completion" (awaitStopped actor)
        atomically (addAfterEffect actor (const (pure ())))
          `shouldThrow` isActorDead
        atomically (addAfterEffectUnchecked actor (const (pure ())))
          `shouldReturn` ()

      it "reports effect failures to the configured handler" do
        release <- newEmptyMVar
        failures <- newIORef []
        finished <- newEmptyMVar
        actor <- actWith defaultActorConfig
          { onEffectFailure = \exception ->
              atomicModifyIORef' failures (\seen -> (exception : seen, ()))
          }
          (liftIO (takeMVar release))
        atomically do
          addAfterEffect actor (const (throwIO Underflow))
          addAfterEffect actor (const (throwIO ThreadKilled))
          addAfterEffect actor (const (putMVar finished ()))
        putMVar release ()
        within "effects after failures" (takeMVar finished) `shouldReturn` ()
        _ <- within "effect completion" (atomically (awaitEffects actor))
        seen <- reverse <$> readIORef failures
        map isUnderflowException seen `shouldBe` [True, False]

      it "offers atomic checked and non-throwing registration" do
        release <- newEmptyMVar
        effectRan <- newEmptyMVar
        actor <- act (liftIO (takeMVar release))
        atomically (tryAddAfterEffect actor (const (putMVar effectRan ())))
          `shouldReturn` True
        putMVar release ()
        within "registered after-effect" (takeMVar effectRan) `shouldReturn` ()
        _ <- within "actor completion" (awaitStopped actor)
        atomically (tryAddAfterEffect actor (const (pure ())))
          `shouldReturn` False
        atomically (addAfterEffectChecked actor (const (pure ())))
          `shouldThrow` isActorDead

      it "does not let a blocked link delay later effects" do
        releaseRecipient <- newEmptyMVar
        recipientReady <- newEmptyMVar
        recipient <- act $ liftIO $ uninterruptibleMask_ do
          putMVar recipientReady ()
          takeMVar releaseRecipient
        within "masked recipient startup" (takeMVar recipientReady)
          `shouldReturn` ()

        releaseTarget <- newEmptyMVar
        laterEffect <- newEmptyMVar
        target <- act (liftIO (takeMVar releaseTarget))
        atomically do
          linkSTM recipient target
          addAfterEffectChecked target (const (putMVar laterEffect ()))
        putMVar releaseTarget ()

        effectResult <- timeout 1000000 (takeMVar laterEffect)
        putMVar releaseRecipient ()
        effectResult `shouldBe` Just ()
        _ <- within "masked recipient cleanup" (awaitStopped recipient)
        pure ()

      it "runs the completion handler and effects in registration order" do
        release <- newEmptyMVar
        recorded <- newIORef ([] :: [String])
        completionSeen <- newEmptyMVar
        drained <- newEmptyMVar
        let record event = atomicModifyIORef' recorded (\events -> (event : events, ()))
        actor <- actFinally (const (record "handler")) do
          liftIO (takeMVar release)
          liftIO (throwIO Underflow)
        atomically do
          addAfterEffectChecked actor $ \completion -> do
            record "first"
            putMVar completionSeen completion
          addAfterEffectChecked actor $ const do
            record "second"
            putMVar drained ()
        putMVar release ()
        within "ordered after-effects" (takeMVar drained) `shouldReturn` ()
        reverse <$> readIORef recorded
          `shouldReturn` ["handler", "first", "second"]
        within "after-effect completion value" (takeMVar completionSeen)
          >>= \case
            Just exception
              | isUnderflowException exception -> pure ()
            completion -> expectationFailure
              ("expected Underflow, got " <> show completion)

      it "closes registration before completion effects finish" do
        releaseAction <- newEmptyMVar
        effectStarted <- newEmptyMVar
        releaseEffect <- newEmptyMVar
        effectsDrained <- newEmptyMVar
        actor <- act (liftIO (takeMVar releaseAction))
        atomically do
          addAfterEffectChecked actor $ const do
            putMVar effectStarted ()
            takeMVar releaseEffect
          addAfterEffectChecked actor (const (putMVar effectsDrained ()))
        putMVar releaseAction ()
        within "blocking after-effect startup" (takeMVar effectStarted)
          `shouldReturn` ()
        atomically (await actor) >>= \case
          Completed -> pure ()
          status -> expectationFailure ("expected Completed, got " <> show status)
        atomically (addAfterEffectChecked actor (const (pure ())))
          `shouldThrow` isActorDead
        timeout 100000 (atomically (awaitEffects actor)) >>= \case
          Nothing -> pure ()
          Just status -> expectationFailure
            ("awaitEffects returned while an effect was blocked: " <> show status)
        putMVar releaseEffect ()
        within "remaining after-effects" (takeMVar effectsDrained)
          `shouldReturn` ()
        within "awaitEffects" (atomically (awaitEffects actor)) >>= \case
          Completed -> pure ()
          status -> expectationFailure ("expected Completed, got " <> show status)

    describe "sending" do
      it "sends while alive and rejects normal sends after completion" do
        result <- newEmptyMVar
        actor <- act $ receive (liftIO . putMVar result)
        atomically (trySend actor "hello") >>= \case
          Sent -> pure ()
          sendResult -> expectationFailure
            ("expected Sent, got " <> show sendResult)
        within "checked message" (takeMVar result) `shouldReturn` "hello"
        _ <- within "receiver completion" (awaitStopped actor)
        atomically (trySend actor "late") >>= \case
          ActorStopped _ -> pure ()
          sendResult -> expectationFailure
            ("expected ActorStopped, got " <> show sendResult)
        atomically (send actor "late") `shouldThrow` isActorDead
        atomically (sendChecked actor "late") `shouldThrow` isActorDead

    describe "mailbox" do
      it "preserves FIFO order" do
        result <- newEmptyMVar
        actor <- act do
          messages <- replicateM 100 (receive pure)
          liftIO (putMVar result messages)
        atomically $ forM_ [1 .. 100 :: Int] (send actor)
        within "FIFO mailbox delivery" (takeMVar result)
          `shouldReturn` [1 .. 100]

      it "participates in STM rollback" do
        result <- newEmptyMVar
        actor <- act $ receive (liftIO . putMVar result)
        atomically $
          (send actor "rolled back" >> retry)
            `orElse` send actor "committed"
        within "rolled-back send" (takeMVar result)
          `shouldReturn` "committed"

    describe "bounded mailbox" do
      it "applies transactional backpressure and preserves FIFO order" do
        releaseReceiver <- newEmptyMVar
        result <- newEmptyMVar
        actor <- actBounded 1 do
          liftIO (takeMVar releaseReceiver)
          first <- receive pure
          second <- receive pure
          liftIO (putMVar result [first, second])

        atomically (sendChecked actor "first")
        atomically
          ((sendChecked actor "second" >> pure True) `orElse` pure False)
          `shouldReturn` False

        putMVar releaseReceiver ()
        within "bounded mailbox capacity"
          (atomically (sendChecked actor "second")) `shouldReturn` ()
        within "bounded FIFO delivery" (takeMVar result)
          `shouldReturn` ["first", "second"]

      it "rolls back mailbox occupancy with a rolled-back send" do
        blocker <- newEmptyMVar
        actor <- actBounded 1 (liftIO (takeMVar blocker))
        atomically
          ((send actor "rolled back" >> retry) `orElse` pure ())
        atomically (trySend actor "committed") >>= \case
          Sent -> pure ()
          sendResult -> expectationFailure
            ("expected Sent after rollback, got " <> show sendResult)
        murder actor
        _ <- within "rollback actor shutdown" (awaitStopped actor)
        pure ()

      it "reports full mailboxes without retrying and observes shutdown" do
        blocker <- newEmptyMVar
        actor <- actBounded 1 (liftIO (takeMVar blocker))
        atomically (send actor "first")
        atomically (trySend actor "second") >>= \case
          MailboxFull -> pure ()
          sendResult -> expectationFailure
            ("expected MailboxFull, got " <> show sendResult)
        murder actor
        _ <- within "full bounded actor shutdown" (awaitStopped actor)
        atomically (trySend actor "second") >>= \case
          ActorStopped _ -> pure ()
          sendResult -> expectationFailure
            ("expected ActorStopped, got " <> show sendResult)
        atomically (send actor "second") `shouldThrow` isActorDead

      it "delivers messages from many senders exactly once and in order" do
        let senders = 8 :: Int
            perSender = 500 :: Int
        received <- newIORef []
        drained <- newEmptyMVar
        actor <- actBounded 4 do
          replicateM_ (senders * perSender) $ receive \message ->
            liftIO (atomicModifyIORef' received (\messages -> (message : messages, ())))
          liftIO (putMVar drained ())
        finished <- newEmptyMVar
        forM_ [1 .. senders] \sender -> forkIO do
          forM_ [1 .. perSender] \i -> atomically (send actor (sender, i))
          putMVar finished ()
        replicateM_ senders (within "sender completion" (takeMVar finished))
        within "bounded fan-in drain" (takeMVar drained) `shouldReturn` ()
        messages <- reverse <$> readIORef received
        forM_ [1 .. senders] \sender ->
          [i | (sender', i) <- messages, sender' == sender]
            `shouldBe` [1 .. perSender]
        _ <- within "fan-in actor completion" (awaitStopped actor)
        pure ()

      it "wakes a blocked normal sender when the actor stops" do
        blocker <- newEmptyMVar
        actor <- actBounded 1 (liftIO (takeMVar blocker))
        atomically (send actor "first")
        sendResult <- newEmptyMVar
        _ <- forkIO $ tryActorDeadIO (atomically (send actor "second"))
          >>= putMVar sendResult
        timeout 100000 (takeMVar sendResult) >>= \case
          Nothing -> pure ()
          Just _ -> expectationFailure "send completed while the mailbox was full"
        murder actor
        _ <- within "blocked-sender actor shutdown" (awaitStopped actor)
        within "blocked sender wakeup" (takeMVar sendResult) >>= \case
          Left _ -> pure ()
          Right () -> expectationFailure "send unexpectedly committed"

    describe "undelivered messages" do
      it "hands queued messages to the configured handler in order" do
        blocker <- newEmptyMVar
        undelivered <- newEmptyMVar
        actor <- actWith defaultActorConfig
          { mailboxCapacity = Just 8
          , onUndelivered = putMVar undelivered
          }
          (liftIO (takeMVar blocker))
        atomically (forM_ [1 .. 3 :: Int] (send actor))
        murder actor
        within "undelivered messages" (takeMVar undelivered)
          `shouldReturn` [1, 2, 3]

      it "does not call the handler when nothing was queued" do
        called <- newIORef False
        actor <- actWith defaultActorConfig
          { onUndelivered = \(_ :: [Int]) -> writeIORef called True }
          (pure ())
        _ <- within "empty-mailbox completion" (atomically (awaitEffects actor))
        readIORef called `shouldReturn` False

    describe "receive" do
      it "can receive messages" do
        result <- newEmptyMVar
        actor <- act $ receive (liftIO . putMVar result)
        atomically (send actor "hello")
        within "received message" (takeMVar result)
          `shouldReturn` "hello"

    describe "receiveSTM" do
      it "can receive messages and update STM atomically" do
        result <- newTVarIO Nothing
        actor <- act (receiveSTM (writeTVar result . Just))
        atomically (send actor "hello")
        within "receiveSTM update" (atomically do
          readTVar result >>= maybe retry pure)
          `shouldReturn` "hello"

    describe "hoistActionT" do
      it "hoists ActionTs" do
        result <- newTVarIO Nothing
        _ <- act $ hoistActionT (flip runReaderT True) do
          enabled <- ask
          liftIO $ atomically (writeTVar result (Just enabled))
        within "hoisted ReaderT action" (atomically do
          readTVar result >>= maybe retry pure)
          `shouldReturn` True

    describe "murder" do
      it "does nothing once the actor has stopped" do
        actor <- act (pure ())
        _ <- within "actor completion" (awaitStopped actor)
        within "murder of a stopped actor" (murder actor) `shouldReturn` ()

      it "kills actors" do
        blocker <- newEmptyMVar :: IO (MVar ())
        result <- newEmptyMVar
        actor <- actFinally (putMVar result) (liftIO (takeMVar blocker))
        murder actor
        outcome <- within "murdered actor completion" (takeMVar result)
        outcome `shouldSatisfy` isMurderKill

    describe "link" do
      it "links actors" do
        releaseTarget <- newEmptyMVar
        linked <- newEmptyMVar
        blocker <- newEmptyMVar :: IO (MVar ())
        target <- act do
          liftIO (takeMVar releaseTarget)
          liftIO (throwIO Underflow)
        result <- newEmptyMVar
        _ <- actFinally (putMVar result) do
          link target
          liftIO (putMVar linked ())
          liftIO (takeMVar blocker)
        within "link registration" (takeMVar linked) `shouldReturn` ()
        putMVar releaseTarget ()
        outcome <- within "linked actor completion" (takeMVar result)
        outcome `shouldSatisfy` isLinkKill

      it "signals a link when the target completes normally" do
        releaseTarget <- newEmptyMVar
        linked <- newEmptyMVar
        blocker <- newEmptyMVar :: IO (MVar ())
        target <- act (liftIO (takeMVar releaseTarget))
        result <- newEmptyMVar
        _ <- actFinally (putMVar result) do
          link target
          liftIO (putMVar linked ())
          liftIO (takeMVar blocker)
        within "normal link registration" (takeMVar linked) `shouldReturn` ()
        putMVar releaseTarget ()
        outcome <- within "normal linked completion" (takeMVar result)
        outcome `shouldSatisfy` isLinkKill

      it "fails immediately when the target is already dead" do
        target <- act (pure ())
        _ <- within "target completion" (awaitStopped target)
        result <- newEmptyMVar
        _ <- actFinally (putMVar result) (link target)
        outcome <- within "late link failure" (takeMVar result)
        outcome `shouldSatisfy` isLinkKill

      it "signals a link before a blocking target completion handler" do
        releaseHandler <- newEmptyMVar
        releaseTarget <- newEmptyMVar
        target <- actFinally (const (takeMVar releaseHandler))
          (liftIO (takeMVar releaseTarget))

        linked <- newEmptyMVar
        recipientBlocker <- newEmptyMVar :: IO (MVar ())
        recipientResult <- newEmptyMVar
        _ <- actFinally (putMVar recipientResult) do
          link target
          liftIO (putMVar linked ())
          liftIO (takeMVar recipientBlocker)

        within "prompt-link registration" (takeMVar linked) `shouldReturn` ()
        putMVar releaseTarget ()
        _ <- within "prompt-link target transition" (awaitStopped target)
        earlyResult <- timeout 1000000 (takeMVar recipientResult)
        putMVar releaseHandler ()
        case earlyResult of
          Just outcome -> outcome `shouldSatisfy` isLinkKill
          Nothing -> do
            _ <- within "delayed link cleanup" (takeMVar recipientResult)
            expectationFailure
              "link delivery waited for the target completion handler"

      it "never loses a link racing target completion" do
        replicateM_ 200 do
          releaseTarget <- newEmptyMVar
          target <- act (liftIO (takeMVar releaseTarget))
          linkedBlocker <- newEmptyMVar :: IO (MVar ())
          linkedResult <- newEmptyMVar
          linked <- actFinally (putMVar linkedResult)
            (liftIO (takeMVar linkedBlocker))
          _ <- forkIO (putMVar releaseTarget ())
          registration <- tryActorDeadIO (atomically (linkSTM linked target))
          case registration of
            Left _ -> do
              murder linked
              outcome <- within "racing-link cleanup" (takeMVar linkedResult)
              outcome `shouldSatisfy` isMurderKill
            Right () -> do
              outcome <- within "racing link notification" (takeMVar linkedResult)
              outcome `shouldSatisfy` isLinkKill

    describe "linkSTM" do
      it "links actors transactionally" do
        firstBlocker <- newEmptyMVar :: IO (MVar ())
        secondBlocker <- newEmptyMVar :: IO (MVar ())
        result <- newEmptyMVar
        first <- actFinally (putMVar result) (liftIO (takeMVar firstBlocker))
        second <- act (liftIO (takeMVar secondBlocker))
        atomically (linkSTM first second)
        murder second
        outcome <- within "transactionally linked actor completion" (takeMVar result)
        outcome `shouldSatisfy` isLinkKill

      it "rejects an already-dead target" do
        target <- act (pure ())
        _ <- within "target completion" (awaitStopped target)
        blocker <- newEmptyMVar
        actor <- act (liftIO (takeMVar blocker))
        atomically (linkSTM actor target) `shouldThrow` isActorDead
        murder actor
        _ <- within "linked actor cleanup" (awaitStopped actor)
        pure ()

      it "rejects an already-dead recipient" do
        recipient <- act (pure ())
        _ <- within "recipient completion" (awaitStopped recipient)
        targetBlocker <- newEmptyMVar
        target <- act (liftIO (takeMVar targetBlocker))
        atomically (linkSTM recipient target) `shouldThrow` isActorDead
        murder target
        _ <- within "link target cleanup" (awaitStopped target)
        pure ()

    describe "monitor" do
      it "delivers a message when the target completes normally" do
        releaseTarget <- newEmptyMVar
        result <- newEmptyMVar
        target <- act (liftIO (takeMVar releaseTarget))
        _ <- act do
          monitor target TargetDown
          receive \(TargetDown completion) -> liftIO (putMVar result completion)
        putMVar releaseTarget ()
        within "normal monitor notification" (takeMVar result) >>= \case
          Nothing -> pure ()
          Just exception -> expectationFailure
            ("expected normal completion, got " <> show exception)

      it "delivers the exception when the target fails" do
        releaseTarget <- newEmptyMVar
        result <- newEmptyMVar
        target <- act do
          liftIO (takeMVar releaseTarget)
          liftIO (throwIO Underflow)
        _ <- act do
          monitor target TargetDown
          receive \(TargetDown completion) -> liftIO (putMVar result completion)
        putMVar releaseTarget ()
        within "failure monitor notification" (takeMVar result) >>= \case
          Just exception | isUnderflowException exception -> pure ()
          completion -> expectationFailure
            ("expected Underflow, got " <> show completion)

      it "notifies immediately about an already-stopped target" do
        target <- act (pure ())
        _ <- within "target completion" (awaitStopped target)
        result <- newEmptyMVar
        _ <- act do
          monitor target TargetDown
          receive \(TargetDown completion) -> liftIO (putMVar result completion)
        within "late monitor notification" (takeMVar result) >>= \case
          Nothing -> pure ()
          Just exception -> expectationFailure
            ("expected normal completion, got " <> show exception)

      it "rejects a stopped recipient and drops notifications to one" do
        recipient <- act (pure ())
        _ <- within "recipient completion" (awaitStopped recipient)
        targetBlocker <- newEmptyMVar
        target <- act (liftIO (takeMVar targetBlocker))
        atomically (monitorSTM recipient target TargetDown)
          `shouldThrow` isActorDead
        murder target
        _ <- within "monitor target cleanup" (awaitStopped target)
        pure ()

    describe "self" do
      it "returns the actor's real handle" do
        result <- newEmptyMVar
        actor <- act do
          me <- self
          liftIO (putMVar result me)
        actual <- within "self handle" (takeMVar result)
        actual `shouldBe` actor

    describe "contramap" do
      it "adapts the mailbox type without changing actor identity" do
        result <- newEmptyMVar
        stringActor <- act $ receive (liftIO . putMVar result)
        let intActor = contramap show stringActor
        threadId intActor `shouldBe` threadId stringActor
        atomically (sendChecked intActor (42 :: Int))
        within "contramapped message" (takeMVar result) `shouldReturn` "42"

    describe "livenessCheck" do
      it "reports Completed" do
        actor <- act (pure ())
        within "completed actor status" (awaitStopped actor) >>= \case
          Completed -> pure ()
          status -> expectationFailure ("expected Completed, got " <> show status)

      it "reports ThrewException" do
        actor <- act (liftIO (throwIO Underflow))
        within "failed actor status" (awaitStopped actor) >>= \case
          ThrewException exception
            | isUnderflowException exception -> pure ()
          status -> expectationFailure ("expected Underflow, got " <> show status)

      it "reports Alive" do
        blocker <- newEmptyMVar
        actor <- act (liftIO (takeMVar blocker))
        atomically (livenessCheck actor) >>= \case
          Alive -> pure ()
          status -> expectationFailure ("expected Alive, got " <> show status)
        putMVar blocker ()
        _ <- within "alive actor cleanup" (awaitStopped actor)
        pure ()

    describe "await" do
      it "waits transactionally for completion" do
        release <- newEmptyMVar
        waiterReady <- newEmptyMVar
        result <- newEmptyMVar
        actor <- act (liftIO (takeMVar release))
        _ <- forkIO do
          putMVar waiterReady ()
          atomically (await actor) >>= putMVar result
        within "await waiter startup" (takeMVar waiterReady) `shouldReturn` ()
        tryTakeMVar result >>= \case
          Nothing -> pure ()
          Just status -> expectationFailure
            ("await returned before completion: " <> show status)
        putMVar release ()
        within "await completion" (takeMVar result) >>= \case
          Completed -> pure ()
          status -> expectationFailure ("expected Completed, got " <> show status)

    describe "garbage collection" do
      it "stops a receiver whose handle has been dropped" do
        stopped <- newEmptyMVar
        do
          actor <- act (receive (\() -> pure ()))
          atomically (addAfterEffect actor (putMVar stopped))
        let collect attempts = do
              performMajorGC
              timeout 200000 (takeMVar stopped) >>= \case
                Just completion -> pure (Just completion)
                Nothing
                  | attempts > (1 :: Int) -> collect (attempts - 1)
                  | otherwise -> pure Nothing
        collect 25 >>= \case
          Just (Just exception)
            | Just BlockedIndefinitelyOnSTM <- fromException exception -> pure ()
          outcome -> expectationFailure
            ("expected BlockedIndefinitelyOnSTM, got " <> show outcome)

    describe "withLivenessCheck" do
      it "doesn't let you add after-effects to dead actors" do
        actor <- act (pure ())
        _ <- within "target completion" (awaitStopped actor)
        atomically (withLivenessCheck addAfterEffectUnchecked actor (const (pure ())))
          `shouldThrow` isActorDead

newtype TargetDown = TargetDown (Maybe SomeException)

within :: String -> IO a -> IO a
within label action = timeout 5000000 action >>= \case
  Nothing -> expectationFailure message >> fail message
  Just result -> pure result
  where
    message = "timed out waiting for " <> label

awaitStopped :: Actor message -> IO Liveness
awaitStopped = atomically . await

tryActorDeadIO :: IO a -> IO (Either ActorDead a)
tryActorDeadIO = try

isActorDead :: ActorDead -> Bool
isActorDead (ActorDead _) = True

isLinkKill :: Either SomeException a -> Bool
isLinkKill = \case
  Left exception -> case fromException exception of
    Just (LinkKill _) -> True
    Nothing -> False
  Right _ -> False

isMurderKill :: Either SomeException a -> Bool
isMurderKill = \case
  Left exception -> case fromException exception of
    Just (MurderKill _) -> True
    Nothing -> False
  Right _ -> False

isSuccess :: Either SomeException a -> Bool
isSuccess = \case
  Left _ -> False
  Right _ -> True

isUnderflow :: Either SomeException a -> Bool
isUnderflow = \case
  Left exception -> isUnderflowException exception
  Right _ -> False

isUnderflowException :: SomeException -> Bool
isUnderflowException exception = case fromException exception of
  Just Underflow -> True
  _ -> False
