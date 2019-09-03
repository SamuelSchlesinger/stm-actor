{-# LANGUAGE FlexibleInstances,
             MultiParamTypeClasses,
             RecordWildCards,
             ExistentialQuantification,
             FlexibleContexts,
             TypeFamilies,
             UndecidableInstances,
             TypeOperators,
             RankNTypes #-}

-- | 
-- Module      : Control.Concurrent.Actor
-- Copyright   : (c) Samuel Schlesinger 2019
-- License     : All Rights Reserved
-- Maintainer  : sgschlesinger@gmail.com
-- Portability : portable
--
-- = Local Actors using STM
-- 
-- In Haskell, we have access to a relatively
-- large number of lightweight threads. Leveraging
-- this, software transactional memory, and
-- the existential quantification GHC extension, we
-- create a domain specific language for describing actors
-- which have a mailbox and a number of other features.
-- 
-- We can send actors messages at their 'Address'.
-- 
-- > send :: MonadBase IO m => msg -> Address msg -> m ()
-- 
-- As an actor, we are able to receive and inspect a message.
-- 
-- @
--   weatherChecker = receive $ \\case
--     Sunny -> send "Come over" friend
--     Rainy -> send TurnOn netflix
-- @
-- 
-- We can run an 'ActionT' as an actor:
--
-- @
--   main = do
--     (address, result) <- spawnIO $ do
--       msg :: String <- next
--       return msg
--     send address \"Hello\"
--     waitForOutcome result >>= print
-- @
--
--  I have read many people saying that message passing
--  actor models do not work with Haskell because of the
--  type system, but I think this works pretty adequately,
--  and not only that, it sort of forces you to think about
--  the structure of your messages and the way they relate
--  to one another.  
module Control.Concurrent.Actor
    ( ActionT
    , Address
    , Result
    , checkForOutcome
    , checkForValue
    , waitForOutcome
    , LinkException(..)
    , (:->)(..)
    , spawnM
    , spawnMFinally
    , spawnIO
    , spawnIOFinally
    , spawn
    , hoistAction
    , hoistSpawn
    , hoistSpawnIO
    , hoistSpawnIOFinally
    , hoistSpawnMFinally
    , hoistSpawnM
    , link
    , watch
    , spawnLink
    , spawnWatch
    , next
    , nextMaybe
    , receive
    , send
    , flush
    , myAddress
    , killAddress
    , throwToAddress
    , addressThreadId
    , addressConvert
    , remoteCatch
    , remoteOnSuccess
    , onSuccess ) where

import Control.Concurrent.Lifted
import Control.Concurrent.STM
import Control.Monad.Trans.Control
import Control.Monad.Trans
import Control.Exception.Lifted
import Control.Monad.State.Class
import Control.Monad.Reader.Class
import Control.Monad.Base
import Control.Monad.Fail
import Prelude hiding (fail)
import Control.Monad hiding (fail)

-- | An 'ActionT' is a description of the computation
--   of an actor. It is encoded as a reader monad transformer with
--   access to a transactional message queue:
--
-- > TQueue msg
--
--   as well as to a transactional variable containing
--   a function which will be called upon exit, either
--   with 'Just' the exception it threw or 'Nothing':
--
-- > TMVar (Maybe SomeException -> IO ())
--

newtype ActionT msg m a = ActionT
  { unActionT :: TQueue msg
             -> TMVar (Maybe SomeException -> IO ())
             -> m a }

instance Functor f => Functor (ActionT msg f) where
  fmap f (ActionT act) = ActionT $ \mailbox onExit ->
    f <$> act mailbox onExit

instance MonadFail m => MonadFail (ActionT msg m) where
  fail x = lift (fail x)

instance Monad m => Applicative (ActionT msg m) where
  pure x = ActionT $ \mailbox onExit -> pure x
  ActionT fact <*> ActionT xact = ActionT $ \mailbox onExit -> do
    f <- fact mailbox onExit
    x <- xact mailbox onExit
    return $ f x

instance Monad m => Monad (ActionT msg m) where
  return = pure
  ActionT xact >>= f = ActionT $ \mailbox onExit -> do
    x <- xact mailbox onExit
    let ActionT yact = f x
    y <- yact mailbox onExit
    return y

instance MonadIO m =>  MonadIO (ActionT msg m) where
  liftIO io = ActionT $ \mailbox onExit -> do
    liftIO io

instance MonadBase b m => MonadBase b (ActionT msg m) where
  liftBase io = ActionT $ \mailbox onExit -> do
    liftBase io

instance MonadTrans (ActionT msg) where
  lift ma = ActionT $ \_  _  -> ma

instance MonadTransControl (ActionT msg) where
  type StT (ActionT msg) a = a
  liftWith run = ActionT $ \a b -> run (\(ActionT act) -> act a b)
  restoreT action = ActionT $ \_ _ -> action

instance MonadBaseControl IO m => MonadBaseControl IO (ActionT msg m) where
  type StM (ActionT msg m) a = StM m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM

-- | A 'LinkException' is the sort of exception which can be
--   thrown across actors when they have been linked.
data LinkException = LinkException ThreadId SomeException | LinkDone ThreadId
  deriving (Show)

instance Exception LinkException

instance MonadState s m => MonadState s (ActionT msg m) where
  get = lift get
  put a = lift (put a)
  state f = lift (state f)

instance MonadReader r m => MonadReader r (ActionT msg m) where
  ask = lift ask
  local f x = do
    x <- x
    lift (local f (return x))
  reader f = lift (reader f)

-- | An 'Address' is an outbox with a specific type you are
--   allowed to send it. Just because it has a specific type
--   doesn't mean that the actor at the other end of it takes
--   that type as input, it just means that you have an address
--   which knows how to send that actor that particular type.
data Address msg = forall msg'. Address {
  address :: !(TQueue msg'),
  onExit :: !(TMVar (Maybe SomeException -> IO ())),
  threadId :: !ThreadId,
  encode :: !(msg -> msg')
}

instance Eq (Address msg) where
  Address _ _ x _ == Address _ _ y _ = x == y

instance Ord (Address msg) where
  Address _ _ x _ >= Address _ _ y _ = x >= y
  Address _ _ x _ >  Address _ _ y _  = x >  y
  Address _ _ x _ <= Address _ _ y _ = x <= y
  Address _ _ x _ <  Address _ _ y _ = x <  y

instance Show (Address msg) where
  show (Address _ _ x _) = "Address " ++ show x

-- | The 'Result' of an actor's computation is either
--   an exception or a successful retrieval of the value.
newtype Result a = Result (TMVar (Either SomeException a))

-- | Waits for the result to complete, returning the outcome.
waitForOutcome :: MonadBase IO m => Result a -> m (Either SomeException a)
waitForOutcome (Result r) = liftBase $ atomically $ readTMVar r 

-- | Checks if the result is there, returning it if it is.
checkForOutcome :: MonadBase IO m => Result a -> m (Maybe (Either SomeException a))
checkForOutcome (Result r) = liftBase $ atomically $ tryReadTMVar r

-- | Checks if the value is there.
checkForValue :: MonadBase IO m => Result a -> m (Maybe a)
checkForValue (Result r) = liftBase $ atomically $ do
  x <- tryReadTMVar r
  case x of
    Nothing -> return Nothing
    Just (Left _) -> return Nothing
    Just (Right a) -> return (Just a)

-- | The 'spawnM' function takes an 'ActionT' description of an actor, and spawns
--   it as a live actor, returning its 'Address' and a 'Result' which will eventually
--   contain its result, if it ever converges.
spawnM :: (msg' :-> msg, MonadBaseControl IO m) => ActionT msg m a -> m (Address msg', Result a)
spawnM (ActionT act) = do
  address <- liftBase $ newTQueueIO
  onExit <- liftBase $ newTMVarIO $ \exception -> pure ()
  result <- liftBase $ newEmptyTMVarIO
  threadId <-  forkFinally (act address onExit) $ \res -> case res of
    Left e -> do
      f <- liftBase $ atomically $ do
        putTMVar result (Left e)
        readTMVar onExit
      liftBase $ f (Just e)
    Right a -> do
      f <- liftBase $ atomically $ do
        putTMVar result (Right a)
        readTMVar onExit
      liftBase $ f Nothing
  return (Address address onExit threadId convert, Result result)

-- | A hoisted version of 'spawnM'.
hoistSpawnM :: (msg' :-> msg, Monad m, MonadBaseControl IO n) => ActionT msg m a -> (forall x. m x -> n x) -> n (Address msg', Result a)
hoistSpawnM action nat = spawnM (hoistAction nat action)

-- | The 'spawnMFinally' function takes an 'ActionT' description of an actor as
--   well as some instructions on what to do when the action has been completed.
--   It then spawns it as a live actor, returning the 'Address' and a 'Result' which
--   will eventually contain its result, if it ever converges.
spawnMFinally :: (msg' :-> msg, MonadBaseControl IO m) => ActionT msg m a -> (Maybe SomeException -> IO ()) -> m (Address msg', Result a)
spawnMFinally (ActionT act) slurp = do
  address <- liftBase $ newTQueueIO
  onExit <- liftBase $ newTMVarIO slurp
  result <- liftBase $ newEmptyTMVarIO
  threadId <-  forkFinally (act address onExit) $ \res -> case res of
    Left e -> do
      f <- liftBase $ atomically $ do
        putTMVar result (Left e)
        readTMVar onExit
      liftBase $ f (Just e)
    Right a -> do
      f <- liftBase $ atomically $ do
        putTMVar result (Right a)
        readTMVar onExit
      liftBase $ f Nothing
  return (Address address onExit threadId convert, Result result)

-- | A hoisted version of 'spawnMFinally'.
hoistSpawnMFinally :: (msg' :-> msg, Monad m, MonadBaseControl IO n) => ActionT msg m a -> (Maybe SomeException -> IO ()) -> (forall x. m x -> n x) -> n (Address msg', Result a)
hoistSpawnMFinally action slurp nat = spawnMFinally (hoistAction nat action) slurp

-- | Like 'spawnM', but specialized to 'IO'.
spawnIO :: msg' :-> msg => ActionT msg IO a -> IO (Address msg', Result a)
spawnIO (ActionT act) = do
  address <- newTQueueIO
  onExit <- newTMVarIO $ \exception -> pure ()
  result <- newEmptyTMVarIO
  threadId <- forkFinally (act address onExit) $ \res -> case res of
    Left e -> do
      f <- atomically $ do
        putTMVar result (Left e)
        readTMVar onExit
      f (Just e)
    Right a -> do
      f <- atomically $ do
        putTMVar result (Right a)
        readTMVar onExit
      f Nothing
  return (Address address onExit threadId convert, Result result)

-- | A hoisted version of 'spawnIO'.
hoistSpawnIO :: (msg' :-> msg, Monad m) => ActionT msg m a -> (forall x. m x -> IO x) -> IO (Address msg', Result a)
hoistSpawnIO action nat = spawnIO $ hoistAction nat action

-- | Like 'spawnMFinally', but specialized to 'IO'.
spawnIOFinally :: msg' :-> msg => ActionT msg IO a -> (Maybe SomeException -> IO ()) -> IO (Address msg', Result a)
spawnIOFinally (ActionT act) slurp = do
  address <- newTQueueIO
  onExit <- newTMVarIO slurp
  result <- newEmptyTMVarIO
  threadId <-  forkFinally (act address onExit) $ \res -> case res of
    Left e -> do
      f <- atomically $ do
        putTMVar result (Left e)
        readTMVar onExit
      f (Just e)
    Right a -> do
      f <- atomically $ do
        putTMVar result (Right a)
        readTMVar onExit
      f Nothing
  return (Address address onExit threadId convert, Result result)

-- | A hoisted version of 'spawnIOFinally'.
hoistSpawnIOFinally :: (msg' :-> msg, Monad m) => ActionT msg m a -> (Maybe SomeException -> IO ()) -> (forall x. m x -> IO x) -> IO (Address msg', Result a)
hoistSpawnIOFinally action slurp nat = spawnIOFinally (hoistAction nat action) slurp

-- | Just 'spawnM', lifted to the 'ActionT' monad.
spawn :: (msg' :-> msg, MonadBaseControl IO m) => ActionT msg m a -> ActionT msg'' m (Address msg', Result a)
spawn action = lift $ spawnM action

-- | Using a natural transformation, hoist an 'ActionT'
--   from using one functor to another. 
hoistAction :: Monad m => (forall x. m x -> n x) -> ActionT msg m a -> ActionT msg n a
hoistAction nat action = ActionT $ \mailbox onExit -> nat $ unActionT action mailbox onExit

-- | A hoisted version of 'spawn'.
hoistSpawn :: (msg' :-> msg, Monad m, MonadBaseControl IO n) => ActionT msg m a -> (forall x. m x -> n x) -> ActionT msg'' n (Address msg', Result a)
hoistSpawn action nat = spawn $ hoistAction nat action

-- | Links the calling actor with the actor at the given
--   'Address' in the following sense: when I get an exception
--   or finish, the addressed actor will get a 'LinkException'
--   describing that. This is symmetric, so I will receive a
--   'LinkException in a similar way. It is also atomic, so a
--   link will never be established unilaterally. 
link :: MonadBaseControl IO m => Address msg -> ActionT msg' m ()
link Address{..} = ActionT $ \mailbox myOnExit -> do
  myThreadId <- myThreadId
  liftBase $ atomically $ do
    mine <- takeTMVar myOnExit
    theirs <- takeTMVar onExit
    putTMVar myOnExit $ \m -> case m of
      Just e -> do
        throwTo threadId (LinkException myThreadId e)
        mine m
      Nothing -> do
        throwTo threadId (LinkDone myThreadId)
        mine m
    putTMVar onExit $ \m -> case m of
      Just e -> do
        throwTo myThreadId (LinkException threadId e)
        theirs m
      Nothing -> do
        throwTo myThreadId (LinkDone threadId)
        theirs m

-- | The 'watch' function allows an actor to watch another actor at some 'Address' for
--   unhandled exceptions of any type, requesting that the other actor send
--   them a message when they have died, perhaps explaining why.
watch :: (MonadBase IO m, Exception e) => Address msg' -> (ThreadId -> Maybe e -> msg) -> ActionT msg m ()
watch Address{..} enc = do
  me <- myAddress
  liftBase $ atomically $ do
    theirs <- takeTMVar onExit
    putTMVar onExit $ \m -> case m of
      Just e -> do
        tid <- myThreadId
        case fromException e of
          Just e_ -> send (enc tid (Just e_)) me >> theirs m
          Nothing -> theirs m
      Nothing -> do
        tid <- myThreadId
        send (enc tid Nothing) me >> theirs m

-- | You should think about this function as being what
--   > spawn action >>= \(addr, res) -> link addr >> return (addr, res)
--   should be. That will generally work, it was used in the
--   implementation for a while, but here we have no gap between
--   spawning the actor and creating the link at all. 
spawnLink :: (msg' :-> msg, MonadBaseControl IO m) => ActionT msg m a -> ActionT msg'' m (Address msg', Result a)
spawnLink actionT = do
  me <- myAddressBasic
  let myId = addressThreadId me
  (them, result) <- lift $ spawnMFinally actionT $ \m -> do
    threadId <- myThreadId
    case m of
      Just e -> throwTo myId (LinkException threadId e)
      Nothing -> throwTo myId (LinkDone threadId)
  let theirId = addressThreadId them
  mine <- liftBase $ atomically $ takeTMVar $ onExit me
  liftBase $ atomically $ putTMVar (onExit me) $ \m -> case m of
   Just e -> do
     throwTo theirId (LinkException myId e)
     mine m
   Nothing -> do
     throwTo theirId (LinkDone myId)
     mine m
  return (them, result)

-- | This is to 'spawn' and 'watch' as 'spawnLink' is to 'spawn' and 'link'.
spawnWatch :: (msg' :-> msg, Exception e, MonadBaseControl IO m) => ActionT msg m a -> (ThreadId -> Maybe e -> msg'') -> ActionT msg'' m (Address msg', Result a)
spawnWatch actionT enc = do
  me <- myAddressBasic
  let myId = addressThreadId me
  (them, result) <- lift $ spawnMFinally actionT $ \m -> do
    threadId <- myThreadId
    case m of
      Just e -> case fromException e of
        Just e_ -> send (enc threadId (Just e_)) me
      Nothing -> send (enc threadId Nothing) me
  return (them, result)

-- | Waits for the next message in the queue.
next :: MonadBase IO m => ActionT msg m msg
next = ActionT $ \mailbox onExit -> do
  msg <- liftBase $ atomically $ readTQueue mailbox
  return msg

-- | Returns the next message in the queue if it is available. 
nextMaybe :: MonadBase IO m => ActionT msg m (Maybe msg)
nextMaybe = ActionT $ \mailbox onExit -> do
  msg <- liftBase $ atomically $ tryReadTQueue mailbox
  return msg

-- | This is a function which allows you to use LambdaCase to
--   mimic some of the Erlang syntax.
receive :: MonadBase IO m => (msg -> ActionT msg m a) -> ActionT msg m a
receive f = next >>= f

-- | This flushes out the rest of the messages from the queue.
flush :: MonadBase IO m => ActionT msg m [msg]
flush = ActionT $ \mailbox onExit -> do
  msgs <- liftBase . atomically $ flushTQueue mailbox
  return msgs

-- | Often, we have the situation where we want to expose a certain
--   interface to an actor which isn't transparent about what the
--   actor actually receives as values. We could have a customizable
--   address which includes a translation function, and this allows
--   for some interesting things, but by using this typeclass I am
--   able to do things like test for equality in a principled way
--   between addresses. 
class msg' :-> msg where
  convert :: msg' -> msg

instance a :-> a where
  convert = id

-- | Retrieves an 'Address' for the present actor.
myAddress :: (msg' :-> msg) => MonadBase IO m => ActionT msg m (Address msg')
myAddress = ActionT $ \mailbox onExit -> do
  tid <- liftBase $ myThreadId
  return $ Address mailbox onExit tid convert

-- | Retrieves an 'Address' for the present actor at the
--   actual message type that it receives.
myAddressBasic :: MonadBase IO m => ActionT msg m (Address msg)
myAddressBasic = ActionT $ \mailbox onExit -> do
  tid <- liftBase $ myThreadId
  return $ Address mailbox onExit tid id

-- | Send a message to an 'Actor' at an 'Address'.
send :: MonadBase IO m => msg -> Address msg -> m ()
send msg Address{..} = liftBase $ atomically $ writeTQueue address (encode msg)

-- | Kill the actor at the given 'Address'.
killAddress :: MonadBase IO m => Address msg -> ActionT msg' m ()
killAddress Address{..} = ActionT $ \_ _ -> do
  killThread threadId

-- | Convert an 'Address' to another type that the compiler knows 
--   how to send. 
addressConvert :: msg' :-> msg => Address msg -> Address msg'
addressConvert (Address x y z f) = Address x y z (f . convert)

-- | Retrieve the 'ThreadId' inside of an 'Address'.
addressThreadId :: Address msg -> ThreadId
addressThreadId Address{..} = threadId

-- | Throws an exception to the thread of the 'Address'.
throwToAddress :: (MonadBase IO m, Exception e) => Address msg -> e -> ActionT msg' m ()
throwToAddress Address{..} e = ActionT $ \_ _ -> do
  throwTo threadId e

-- | Adds a function which will handle an exception for the
--   actor at the given address if it
--   is uncaught by the actor.
remoteCatch :: (MonadBase IO m, Exception e) => Address msg -> (e -> IO ()) -> m ()
remoteCatch Address{..} c = do
  f <- liftBase $ atomically $ takeTMVar onExit
  liftBase $ atomically $ putTMVar onExit $ \m -> case m of
    Just e -> case fromException e of
      Just e_ -> c e_ >> f m
      Nothing -> f m
    Nothing -> f m

-- | Adds an 'IO' action which will run upon the successful termination
--   of the actor at the given 'Address'.
remoteOnSuccess :: MonadBase IO m => Address msg -> IO () -> m ()
remoteOnSuccess Address{..} a = do
  f <- liftBase $ atomically $ takeTMVar onExit
  liftBase $ atomically $ putTMVar onExit $ \m -> case m of
    Just _ -> f m
    Nothing -> a >> f m

-- | Adds an 'IO' action which will run upon the successful termination
--   of the present actor. 
onSuccess :: MonadBase IO m => IO () -> ActionT msg m ()
onSuccess a = ActionT $ \_ onExit -> do
  f <- liftBase $ atomically $ takeTMVar onExit
  liftBase $ atomically $ putTMVar onExit $ \m -> case m of
    Just _ -> f m
    Nothing -> a >> f m
