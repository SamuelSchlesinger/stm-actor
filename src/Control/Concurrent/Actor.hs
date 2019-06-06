{-# LANGUAGE FlexibleInstances,
             MultiParamTypeClasses,
             RecordWildCards,
             ExistentialQuantification,
             FlexibleContexts,
             TypeFamilies,
             UndecidableInstances,
             TypeOperators #-}

module Control.Concurrent.Actor
    ( ActionT, Address, Result(..), LinkException(..), (:->)(..),
      spawnM, spawnIO, spawn, link, watch, spawnLink, spawnWatch,
      next, nextMaybe, receive, send, flush,
      myAddress, killAddress, throwToAddress ) where

import Control.Concurrent.Lifted
import Control.Concurrent.STM
import Control.Monad.Trans.Control
import Control.Monad.Trans
import Control.Exception.Lifted
import Control.Monad.State.Class
import Control.Monad.Base
import Control.Monad

newtype ActionT msg m a = ActionT
  { unActionT :: TQueue msg
             -> TMVar (SomeException -> IO ())
             -> m a }

instance Functor f => Functor (ActionT msg f) where
  fmap f (ActionT act) = ActionT $ \mailbox onExit ->
    f <$> act mailbox onExit

instance (Functor m, Monad m) => Applicative (ActionT msg m) where
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

data LinkException e = LinkException ThreadId e
  deriving (Show, Eq)

instance Exception e => Exception (LinkException e)

data Address msg = forall msg'. Address {
  address :: !(TQueue msg'),
  onExit :: !(TMVar (SomeException -> IO ())),
  threadId :: ThreadId,
  encode :: msg -> msg'
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

data Result a = Failure SomeException
              | Success a
  deriving Show

instance Functor Result where
  fmap f (Failure e) = Failure e
  fmap f (Success a) = Success (f a)

spawnM :: MonadBaseControl IO m => ActionT msg m a -> m (Address msg, TMVar (Result a))
spawnM (ActionT act) = do
  address <- liftBase $ newTQueueIO
  onExit <- liftBase $ newTMVarIO $ \exception -> pure ()
  result <- liftBase $ newEmptyTMVarIO
  threadId <-  forkFinally (act address onExit) $ \res -> case res of
    Left e -> do
      f <- liftBase $ atomically $ do
        putTMVar result (Failure e)
        readTMVar onExit
      liftBase $ f e
    Right a -> do
      liftBase $ atomically $ do
        putTMVar result (Success a)
      return ()
  return (Address address onExit threadId id, result)

spawnIO :: ActionT msg IO a -> IO (Address msg, TMVar (Result a))
spawnIO (ActionT act) = do
  address <- newTQueueIO
  onExit <- newTMVarIO $ \exception -> pure ()
  result <- newEmptyTMVarIO
  threadId <- forkFinally (act address onExit) $ \res -> case res of
    Left e -> do
      f <- atomically $ do
        putTMVar result (Failure e)
        readTMVar onExit
      f e
    Right a -> do
      atomically $ do
        putTMVar result (Success a)
      return ()
  return (Address address onExit threadId id, result)

spawn :: MonadBaseControl IO m => ActionT msg m a -> ActionT msg' m (Address msg, TMVar (Result a))
spawn action = lift $ spawnM action

link :: MonadBaseControl IO m => Address msg -> ActionT msg' m ()
link Address{..} = ActionT $ \mailbox myOnExit -> do
  myThreadId <- myThreadId
  liftBase $ atomically $ do
    mine <- takeTMVar myOnExit
    theirs <- takeTMVar onExit
    putTMVar myOnExit $ \e -> do
      throwTo threadId (LinkException myThreadId e)
      mine e
    putTMVar onExit $ \e -> do
      throwTo myThreadId (LinkException threadId e)
      theirs e

watch :: (MonadBase IO m, Exception e) => Address msg' -> (e -> msg) -> ActionT msg m ()
watch Address{..} enc = do
  me <- myAddress
  liftBase $ atomically $ do
    theirs <- takeTMVar onExit
    putTMVar onExit $ \e -> do
      case fromException e of
        Just e_ -> send (enc e_) me >> theirs e
        Nothing -> theirs e

spawnLink :: MonadBaseControl IO m => ActionT msg m a -> ActionT msg' m (Address msg, TMVar (Result a))
spawnLink actionT = do
  (addr, result) <- spawn actionT
  link addr
  return (addr, result)

spawnWatch :: (Exception e, MonadBaseControl IO m) => ActionT msg' m a -> (e -> msg) -> ActionT msg m (Address msg', TMVar (Result a))
spawnWatch actionT enc = do
  (addr, result) <- spawn actionT
  watch addr enc
  return (addr, result)

next :: MonadBase IO m => ActionT msg m msg
next = ActionT $ \mailbox onExit -> do
  msg <- liftBase $ atomically $ readTQueue mailbox
  return msg

nextMaybe :: MonadBase IO m => ActionT msg m (Maybe msg)
nextMaybe = ActionT $ \mailbox onExit -> do
  msg <- liftBase . atomically $ tryReadTQueue mailbox
  return msg

receive :: MonadBase IO m => (msg -> ActionT msg m a) -> ActionT msg m a
receive f = next >>= f

flush :: MonadBase IO m => ActionT msg m [msg]
flush = ActionT $ \mailbox onExit -> do
  msgs <- liftBase . atomically $ flushTQueue mailbox
  return msgs

class msg' :-> msg where
  convert :: msg' -> msg

instance a :-> a where
  convert = id

myAddress :: (msg' :-> msg) => MonadBase IO m => ActionT msg m (Address msg')
myAddress = ActionT $ \mailbox onExit -> do
  tid <- liftBase $ myThreadId
  return $ Address mailbox onExit tid convert

send :: MonadBase IO m => msg -> Address msg -> m ()
send msg Address{..} = liftBase $ atomically $ writeTQueue address (encode msg)

killAddress :: MonadBase IO m => Address msg -> ActionT msg' m ()
killAddress Address{..} = ActionT $ \_ _ -> do
  killThread threadId

throwToAddress :: (MonadBase IO m, Exception e) => Address msg -> e -> ActionT msg' m ()
throwToAddress Address{..} e = ActionT $ \_ _ -> do
  throwTo threadId e
