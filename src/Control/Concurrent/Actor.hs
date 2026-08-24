{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingVia #-}
{- |
Module: Control.Concurrent.Actor
Description: Process-local actors with transactional mailboxes
Copyright: (c) Samuel Schlesinger 2020
License: MIT
Maintainer: sgschlesinger@gmail.com
Stability: experimental
Portability: POSIX, Windows

This module provides lightweight, process-local actors backed by STM and
@stm-queue@'s incremental real-time FIFO queues. Each actor owns an unbounded or
bounded mailbox. Sending is an STM operation, so messages can be composed
atomically with application state; a send to a full bounded mailbox retries
until capacity becomes available. Receiving removes one message and runs its
handler in the actor's thread.

An actor has a single lifecycle transition from alive to stopped. The
transition records whether its action completed normally or threw, atomically
closes sends and after-effect registration, and drains queued messages.
'await' observes that transition without polling. Link and monitor
notifications are initiated next. The completion handler, the undelivered
message handler, and registered user after-effects then run in the actor's
terminating thread, with every effect attempted in registration order;
'awaitEffects' observes their completion.

'send' and 'addAfterEffect' are lifecycle-safe by default. The unchecked
'addAfterEffectUnchecked' operation avoids touching the lifecycle 'TVar'; use
it only when the caller already controls the actor lifecycle.

== Actors and garbage collection

An actor blocked in 'receive' whose mailbox is reachable from no other thread
can never receive another message. The runtime system detects this at the next
major garbage collection and throws 'Control.Exception.BlockedIndefinitelyOnSTM'
to the actor, which then stops with 'ThrewException' and runs its links,
monitors, and completion effects like any other failure. Dropping every t'Actor'
handle therefore reclaims the actor, but the failure cascades through links.
Note that an after-effect or monitor which captures the handle keeps the actor
alive.
-}
module Control.Concurrent.Actor
( ActionT
, Actor
  -- * Creating actors
, act
, actBounded
, actFinally
, actFinallyBounded
, actWith
, ActorConfig(..)
, defaultActorConfig
  -- * Sending
, send
, sendChecked
, trySend
, SendResult(..)
  -- * Receiving
, receive
, receiveSTM
, self
, hoistActionT
  -- * Lifecycle
, threadId
, livenessCheck
, Liveness(..)
, await
, awaitEffects
, ActorDead(..)
  -- * Completion effects
, addAfterEffect
, addAfterEffectChecked
, addAfterEffectUnchecked
, tryAddAfterEffect
, withLivenessCheck
  -- * Links and monitors
, link
, linkSTM
, LinkKill(..)
, monitor
, monitorSTM
  -- * Cancellation
, murder
, MurderKill(..)
) where

import Control.Applicative (Alternative)
import Control.Concurrent
    (ThreadId, forkFinally, forkIO, myThreadId, throwTo)
import Control.Concurrent.STM
    ( STM
    , TVar
    , atomically
    , check
    , modifyTVar'
    , newTVarIO
    , readTVar
    , retry
    , throwSTM
    , writeTVar
    )
import Control.Exception
    (Exception, SomeException, catch, finally, mask_, throwIO, try)
import Control.Monad (void)
import Control.Monad.Cont.Class (MonadCont)
import Control.Monad.Error.Class (MonadError)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.IO.Unlift (MonadUnliftIO(..))
import Control.Monad.Reader
    (MonadReader(ask, local), ReaderT(ReaderT))
import Control.Monad.RWS.Class (MonadRWS)
import Control.Monad.State.Class (MonadState)
import Control.Monad.Trans (MonadTrans(..))
import Control.Monad.Writer.Class (MonadWriter)
import Data.Queue
    (Queue, dequeue, enqueue, flush, newBoundedQueueIO, newQueueIO, tryEnqueue)
import Data.Functor.Contravariant (Contravariant(contramap))
import Numeric.Natural (Natural)

-- | A type that contains actions performed by an t'Actor'.
newtype ActionT message m a = ActionT
  { runActionT
    :: ActorContext message
    -> m a
  }

deriving via ReaderT (ActorContext message) m instance Functor m => Functor (ActionT message m)
deriving via ReaderT (ActorContext message) m instance Applicative m => Applicative (ActionT message m)
deriving via ReaderT (ActorContext message) m instance Monad m => Monad (ActionT message m)
deriving via ReaderT (ActorContext message) m instance MonadIO m => MonadIO (ActionT message m)
deriving via ReaderT (ActorContext message) instance MonadTrans (ActionT message)
deriving via ReaderT (ActorContext message) m instance MonadError e m => MonadError e (ActionT message m)
deriving via ReaderT (ActorContext message) m instance MonadWriter w m => MonadWriter w (ActionT message m)
deriving via ReaderT (ActorContext message) m instance MonadState s m => MonadState s (ActionT message m)
deriving via ReaderT (ActorContext message) m instance MonadCont m => MonadCont (ActionT message m)
deriving via ReaderT (ActorContext message) m instance MonadUnliftIO m => MonadUnliftIO (ActionT message m)
deriving via ReaderT (ActorContext message) m instance Alternative m => Alternative (ActionT message m)

instance MonadReader r m => MonadReader r (ActionT message m) where
  ask = ActionT (const ask)
  local f (ActionT ma) = ActionT (fmap (local f) ma)

instance (MonadWriter w m, MonadReader r m, MonadState s m) => MonadRWS r w s (ActionT message m)

data ActorContext message = ActorContext
  { receiveMessage :: STM message
  , actorHandle :: Actor message
  }

-- | A handle used to send messages, inspect lifecycle state, register
-- completion effects, and address the actor's thread.
data Actor message = Actor
  { addAfterEffect' :: AfterEffect -> STM ()
  , addTerminationEffect' :: AfterEffect -> STM ()
  , threadId' :: ThreadId
  , send' :: message -> STM ()
  , trySend' :: message -> STM Bool
  , actorState :: TVar ActorState
  , effectsFinished :: TVar Bool
  }

type Completion = Maybe SomeException

type AfterEffect = Completion -> IO ()

data ActorState
  = Running
  | Stopped Completion

-- | The liveness state of a particular t'Actor'.
data Liveness = Alive | Completed | ThrewException SomeException
  deriving Show

-- | Check the 'Liveness' of a particular t'Actor'.
livenessCheck :: Actor message -> STM Liveness
livenessCheck actor = do
  readTVar (actorState actor) >>= \case
    Running -> pure Alive
    Stopped completion -> pure (maybe Completed ThrewException completion)

-- | Wait until an actor's action has stopped. Unlike 'livenessCheck', this
-- transaction retries while the actor is 'Alive'. It can therefore be composed
-- atomically with other STM operations without polling or sleeping.
--
-- The lifecycle transition happens before the completion handler and
-- after-effects run, so this does not wait for those effects to finish; see
-- 'awaitEffects'.
--
-- @since 0.4.0.0
await :: Actor message -> STM Liveness
await actor = livenessCheck actor >>= \case
  Alive -> retry
  stopped -> pure stopped

-- | Wait until an actor has stopped and its completion handler, undelivered
-- message handler, and after-effects have all finished running, whether or
-- not any of them threw. Like 'await', this retries rather than polling.
--
-- @since 0.4.0.0
awaitEffects :: Actor message -> STM Liveness
awaitEffects actor = do
  liveness <- await actor
  readTVar (effectsFinished actor) >>= check
  pure liveness

-- | The exception thrown when a lifecycle-checked operation is attempted on an
-- actor which has already stopped. 'Nothing' denotes normal completion; 'Just'
-- contains the exception thrown by the actor's action.
data ActorDead = ActorDead (Maybe SomeException)
  deriving Show

instance Exception ActorDead

-- | Wrap 'addAfterEffectUnchecked' or another custom combinator in a liveness
-- check. This adds the lifecycle 'TVar' to the transaction's read set, but
-- prevents an operation from being accepted after the actor has stopped. If
-- the t'Actor' is 'Completed' or 'ThrewException', this throws an t'ActorDead'
-- exception with 'Nothing' or 'Just' the exception, respectively.
withLivenessCheck :: (Actor message -> x -> STM ()) -> Actor message -> x -> STM ()
withLivenessCheck f actor x = ensureAlive actor >> f actor x

ensureAlive :: Actor message -> STM ()
ensureAlive actor = readTVar (actorState actor) >>= \case
  Running -> pure ()
  Stopped completion -> throwSTM (ActorDead completion)

-- | Register an effect to run once the t'Actor' stops. All registered effects
-- run in registration order, after the completion handler; later effects are
-- still attempted if an earlier effect throws. This is how you can implement
-- your own functions like 'link', 'linkSTM', or 'monitorSTM'.
--
-- If the actor has already stopped, throw t'ActorDead'. The liveness check
-- and registration are one STM transaction, so actor completion cannot race
-- between them. Use 'tryAddAfterEffect' for a non-throwing variant, or
-- 'addAfterEffectUnchecked' to skip the check entirely.
addAfterEffect :: Actor message -> (Maybe SomeException -> IO ()) -> STM ()
addAfterEffect = withLivenessCheck addAfterEffectUnchecked

-- | Compatibility name for 'addAfterEffect'.
--
-- @since 0.4.0.0
addAfterEffectChecked :: Actor message -> (Maybe SomeException -> IO ()) -> STM ()
addAfterEffectChecked = addAfterEffect

-- | Register an after-effect without checking liveness. This avoids reading
-- the lifecycle 'TVar', but registering against an actor which has already
-- stopped stores an effect that can never run and is retained by the handle.
-- Use it only when the caller already controls the actor lifecycle.
--
-- @since 0.4.0.0
addAfterEffectUnchecked :: Actor message -> (Maybe SomeException -> IO ()) -> STM ()
addAfterEffectUnchecked = addAfterEffect'

-- | Attempt to register an after-effect. Return 'False' without registering it
-- if the actor has already stopped.
--
-- @since 0.4.0.0
tryAddAfterEffect :: Actor message -> (Maybe SomeException -> IO ()) -> STM Bool
tryAddAfterEffect = tryWhileAlive addAfterEffectUnchecked

-- | Retrieve the 'ThreadId' associated with this t'Actor'.
threadId :: Actor message -> ThreadId
threadId = threadId'

-- | Send a message to this t'Actor' only if it is alive. If it has already
-- stopped, throw t'ActorDead'. The liveness check and enqueue are atomic. On a
-- bounded actor this transaction retries while the mailbox is full; if the
-- actor stops while it is retrying, the transaction wakes and throws
-- t'ActorDead'.
send :: Actor message -> message -> STM ()
send actor message = ensureAlive actor >> send' actor message

-- | Compatibility name for 'send'.
--
-- @since 0.4.0.0
sendChecked :: Actor message -> message -> STM ()
sendChecked = send

-- | The result of a non-blocking send attempt.
--
-- @since 0.4.0.0
data SendResult
  = Sent
    -- ^ The message was enqueued.
  | MailboxFull
    -- ^ The actor was alive, but its bounded mailbox had no capacity.
  | ActorStopped (Maybe SomeException)
    -- ^ The actor had stopped. 'Nothing' denotes normal completion; 'Just'
    -- contains the exception thrown by its action.
  deriving Show

-- | Attempt to send a message without retrying. Return 'MailboxFull' when a
-- live bounded actor has no capacity, or 'ActorStopped' when the actor has
-- already stopped. The lifecycle check and capacity-aware enqueue are one STM
-- transaction.
--
-- @since 0.4.0.0
trySend :: Actor message -> message -> STM SendResult
trySend actor message = readTVar (actorState actor) >>= \case
  Running -> trySend' actor message >>= \accepted ->
    pure (if accepted then Sent else MailboxFull)
  Stopped completion -> pure (ActorStopped completion)

tryWhileAlive :: (Actor message -> x -> STM ()) -> Actor message -> x -> STM Bool
tryWhileAlive f actor x = readTVar (actorState actor) >>= \case
  Running -> f actor x >> pure True
  Stopped _ -> pure False

instance Eq (Actor message) where
  left == right = threadId' left == threadId' right

instance Show (Actor message) where
  show = show . threadId'

instance Contravariant Actor where
  contramap f actor = Actor
    { addAfterEffect' = addAfterEffect' actor
    , addTerminationEffect' = addTerminationEffect' actor
    , threadId' = threadId' actor
    , send' = send' actor . f
    , trySend' = trySend' actor . f
    , actorState = actorState actor
    , effectsFinished = effectsFinished actor
    }

-- | How to create an actor with 'actWith'. Start from 'defaultActorConfig'
-- and override fields with record update syntax.
--
-- @since 0.4.0.0
data ActorConfig message a = ActorConfig
  { mailboxCapacity :: Maybe Natural
    -- ^ 'Nothing' for an unbounded mailbox, or 'Just' the maximum number of
    -- queued messages. The message currently being handled is no longer queued
    -- and does not count against this capacity. A capacity of zero creates a
    -- mailbox to which no send can commit.
  , onCompletion :: Either SomeException a -> IO ()
    -- ^ Run in the actor's terminating thread with the result of its action,
    -- after link and monitor notifications have been initiated and before the
    -- undelivered message handler and user after-effects.
  , onUndelivered :: [message] -> IO ()
    -- ^ Run after 'onCompletion' with the messages which were still queued when
    -- the actor stopped, in mailbox order. It is not called when no messages
    -- were queued. Every committed 'send' either reaches a handler or reaches
    -- this function.
  , onEffectFailure :: SomeException -> IO ()
    -- ^ Called in the actor's terminating thread for each completion effect
    -- that throws, with that exception, before the remaining effects run. The
    -- default rethrows, so after every effect has been attempted the
    -- terminating thread rethrows the first such exception.
  }

-- | An unbounded mailbox and no-op handlers, except that effect failures are
-- rethrown.
--
-- @since 0.4.0.0
defaultActorConfig :: ActorConfig message a
defaultActorConfig = ActorConfig
  { mailboxCapacity = Nothing
  , onCompletion = const (pure ())
  , onUndelivered = const (pure ())
  , onEffectFailure = throwIO
  }

-- | Perform some t'ActionT' in a new thread. Once the action stops, record its
-- result, drain its mailbox, initiate link and monitor notifications, run the
-- supplied completion handler, and then drain all registered user
-- after-effects.
actFinally :: (Either SomeException a -> IO ()) -> ActionT message IO a -> IO (Actor message)
actFinally completionHandler =
  actWith defaultActorConfig { onCompletion = completionHandler }

-- | Like 'actFinally', but use a bounded FIFO mailbox with space for at most
-- the given number of queued messages. Sends retry transactionally while the
-- mailbox is full. The message currently being handled is no longer queued and
-- therefore does not count against this capacity. A capacity of zero creates a
-- mailbox to which no send can commit.
--
-- The mailbox is a bounded @stm-queue@ queue, which tracks free capacity as
-- split read and write credits. Senders and the actor therefore conflict on
-- capacity accounting once per @capacity@ sends rather than on every message.
--
-- @since 0.4.0.0
actFinallyBounded
  :: Natural
  -> (Either SomeException a -> IO ())
  -> ActionT message IO a
  -> IO (Actor message)
actFinallyBounded capacity completionHandler = actWith defaultActorConfig
  { mailboxCapacity = Just capacity
  , onCompletion = completionHandler
  }

-- | Perform some t'ActionT' in a new thread. Use 'await' to observe when its
-- action stops.
act :: ActionT message IO a -> IO (Actor message)
act = actWith defaultActorConfig

-- | Like 'act', but use a bounded FIFO mailbox with space for at most the
-- given number of queued messages. See 'actFinallyBounded'.
--
-- @since 0.4.0.0
actBounded :: Natural -> ActionT message IO a -> IO (Actor message)
actBounded capacity = actWith defaultActorConfig { mailboxCapacity = Just capacity }

-- | Perform some t'ActionT' in a new thread, configured by an t'ActorConfig'.
-- The other creation functions are specialisations of this one.
--
-- The mailbox is an @stm-queue@ queue. Its unbounded and bounded variants
-- share one type, so 'send' retries only when a bounded mailbox is full,
-- 'trySend' never retries, receiving releases bounded capacity, and shutdown
-- makes all capacity available again.
--
-- @since 0.4.0.0
actWith :: ActorConfig message a -> ActionT message IO a -> IO (Actor message)
actWith config (ActionT actionT) = do
  afterEffects <- newTVarIO []
  terminationEffects <- newTVarIO []
  mailbox <- maybe newQueueIO newBoundedQueueIO (mailboxCapacity config)
  stateVar <- newTVarIO Running
  finishedVar <- newTVarIO False
  let makeActor actorThread = Actor
        { addAfterEffect' = \afterEffect -> modifyTVar' afterEffects (afterEffect :)
        , addTerminationEffect' = \afterEffect ->
            modifyTVar' terminationEffects (afterEffect :)
        , threadId' = actorThread
        , send' = enqueue mailbox
        , trySend' = tryEnqueue mailbox
        , actorState = stateVar
        , effectsFinished = finishedVar
        }
  actorThread <- forkFinally
    (do
      currentThread <- myThreadId
      actionT (ActorContext (dequeue mailbox) (makeActor currentThread)))
    (finishActor config stateVar finishedVar mailbox terminationEffects afterEffects)
  pure (makeActor actorThread)

finishActor
  :: ActorConfig message a
  -> TVar ActorState
  -> TVar Bool
  -> Queue message
  -> TVar [AfterEffect]
  -> TVar [AfterEffect]
  -> Either SomeException a
  -> IO ()
finishActor config stateVar finishedVar mailbox terminationEffects afterEffects result = do
  (earlyEffects, effects, undelivered) <- atomically do
    writeTVar stateVar (Stopped completion)
    undelivered <- flush mailbox
    registeredEarly <- readTVar terminationEffects
    registered <- readTVar afterEffects
    writeTVar terminationEffects []
    writeTVar afterEffects []
    pure (reverse registeredEarly, reverse registered, undelivered)
  runAllEffects (onEffectFailure config)
    (  map ($ completion) earlyEffects
    <> [onCompletion config result]
    <> [onUndelivered config undelivered | not (null undelivered)]
    <> map ($ completion) effects
    )
    `finally` atomically (writeTVar finishedVar True)
  where
    completion = either Just (const Nothing) result

-- The terminating thread is already masked by 'forkFinally'; the explicit mask
-- keeps this function correct on its own. Asynchronous exceptions delivered to
-- an interruptible effect are caught like any other effect failure, so cleanup
-- is never truncated.
runAllEffects :: (SomeException -> IO ()) -> [IO ()] -> IO ()
runAllEffects onFailure effects = mask_ (go Nothing effects)
  where
    go :: Maybe SomeException -> [IO ()] -> IO ()
    go firstException [] = maybe (pure ()) throwIO firstException
    go firstException (effect : remaining) = try effect >>= \case
      Left exception -> try (onFailure exception) >>= \case
        Left handlerException ->
          go (rememberFirst firstException handlerException) remaining
        Right () -> go firstException remaining
      Right () -> go firstException remaining

    rememberFirst Nothing exception = Just exception
    rememberFirst remembered _ = remembered

-- | Receive a message and do some t'ActionT' with it.
receive :: MonadIO m => (message -> ActionT message m a) -> ActionT message m a
receive f = ActionT \ctx -> do
  message <- liftIO $ atomically (receiveMessage ctx)
  runActionT (f message) ctx

-- | Receive a message and, in the same transaction, produce some result.
receiveSTM :: MonadIO m => (message -> STM a) -> ActionT message m a
receiveSTM f = ActionT \ctx -> liftIO (atomically (receiveMessage ctx >>= f))

-- | Use a natural transformation to transform an t'ActionT' on one base
-- monad to another.
hoistActionT :: (forall x. m x -> n x) -> ActionT message m a -> ActionT message n a
hoistActionT f (ActionT actionT) = ActionT (fmap f actionT)

-- | The exception thrown when an actor we have 'link'ed with stops.
data LinkKill = LinkKill ThreadId
  deriving Show

instance Exception LinkKill

-- | Link the lifetime of the given actor to this one. When the given actor
-- stops, whether normally or exceptionally, it will throw a t'LinkKill'
-- exception to us with its 'ThreadId' attached. Linking to an actor that has
-- already stopped throws the same t'LinkKill' immediately.
--
-- Links are for cancellation. To be told that an actor stopped without being
-- interrupted, use 'monitor'.
link :: MonadIO m => Actor message -> ActionT message' m ()
link you = do
  me <- self
  liftIO $
    atomically (linkSTM me you)
      `catch` \(ActorDead _) -> throwIO (LinkKill (threadId you))

-- | Links the lifetime of the first actor to the second. When the second actor
-- stops, whether normally or exceptionally, it asynchronously throws a
-- t'LinkKill' exception to the first with the second actor's 'ThreadId'
-- attached. If either actor has already stopped, this transaction throws
-- t'ActorDead' instead of installing a link that can never be delivered.
--
-- Link delivery is initiated before the second actor's completion handler and
-- user after-effects. It uses a helper thread so a first actor which masks
-- asynchronous exceptions cannot block the second actor's cleanup.
linkSTM :: Actor message -> Actor message' -> STM ()
linkSTM alice bob = do
  ensureAlive alice
  ensureAlive bob
  addTerminationEffect' bob (const (signalLink alice bob))

signalLink :: Actor message -> Actor message' -> IO ()
signalLink alice bob = do
  _ <- forkIO $ throwTo (threadId alice) (LinkKill (threadId bob))
  pure ()

-- | Monitor the given actor from this one. When it stops, whether normally or
-- exceptionally, the message built from its completion is sent to our mailbox,
-- so it is handled like any other message rather than interrupting us. If the
-- given actor has already stopped, the message is sent immediately.
--
-- @since 0.4.0.0
monitor
  :: MonadIO m
  => Actor message'
  -> (Maybe SomeException -> message)
  -> ActionT message m ()
monitor target toMessage = do
  me <- self
  liftIO (atomically (monitorSTM me target toMessage))

-- | Make the first actor monitor the second. When the second actor stops, the
-- message built from its completion ('Nothing' for normal completion, 'Just'
-- the exception otherwise) is sent to the first actor. If the second actor has
-- already stopped, the message is sent in this transaction, retrying like
-- 'send' if the first actor's bounded mailbox is full. If the first actor has
-- already stopped, throw t'ActorDead'.
--
-- Like links, monitor notifications are initiated at the second actor's
-- lifecycle transition, before its completion handler and after-effects, and
-- are delivered from a helper thread which waits for mailbox capacity. A
-- notification to a first actor which has since stopped is dropped.
--
-- @since 0.4.0.0
monitorSTM
  :: Actor message
  -> Actor message'
  -> (Maybe SomeException -> message)
  -> STM ()
monitorSTM recipient target toMessage = do
  ensureAlive recipient
  readTVar (actorState target) >>= \case
    Stopped completion -> send' recipient (toMessage completion)
    Running -> addTerminationEffect' target \completion ->
      signalMonitor recipient (toMessage completion)

signalMonitor :: Actor message -> message -> IO ()
signalMonitor recipient message = void $ forkIO $
  atomically (send recipient message)
    `catch` \(ActorDead _) -> pure ()

-- | Returns the t'Actor' handle of the actor executing this action.
self :: Applicative m => ActionT message m (Actor message)
self = ActionT (pure . actorHandle)

-- | The exception thrown when we 'murder' an t'Actor'.
data MurderKill = MurderKill ThreadId
  deriving Show

instance Exception MurderKill

-- | Throw a t'MurderKill' exception to the given t'Actor' if it is still alive.
-- As with 'throwTo', this can block while the target is uninterruptibly
-- masking asynchronous exceptions. Once the actor has stopped this does
-- nothing, so completion effects are not interrupted; a murder that races the
-- lifecycle transition may still reach the terminating thread, where it is
-- recorded as an effect failure rather than truncating cleanup.
murder :: MonadIO m => Actor message -> m ()
murder actor = liftIO do
  murderer <- myThreadId
  atomically (livenessCheck actor) >>= \case
    Alive -> throwTo (threadId actor) (MurderKill murderer)
    _ -> pure ()
