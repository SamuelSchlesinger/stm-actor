{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GADTs #-}
{- |
Module: Control.Concurrent.Actor
Description: A basic actor model in Haskell
Copyright: (c) Samuel Schlesinger 2020
License: MIT
Maintainer: sgschlesinger@gmail.com
Stability: experimental
Portability: POSIX, Windows
-}
module Control.Concurrent.Actor
( ActionT
, Actor(..)
, actFinally
, act
, receiveSTM
, receive
, hoistActionT
, link
, actor'sThreadId
) where

import Control.Concurrent
import Control.Monad.IO.Class
import Control.Monad.Trans
import Control.Monad.Reader
import Control.Monad.State.Class
import Control.Monad.Reader.Class
import Control.Monad.Writer.Class
import Control.Monad.RWS.Class
import Control.Monad.Error.Class
import Control.Monad.Cont.Class
import Control.Concurrent.STM
import Control.Exception
import Data.Functor.Contravariant
import Data.Queue

-- | A type that contains the actions that 'Actor's will do.
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

instance MonadReader r m => MonadReader r (ActionT message m) where
  ask = ActionT (const ask)
  local f (ActionT ma) = ActionT (fmap (local f) ma)

instance (MonadWriter w m, MonadReader r m, MonadState s m) => MonadRWS r w s (ActionT message m)

data ActorContext message = forall a. ActorContext
  { onError      :: TVar (Either SomeException a -> IO ())
  , messageQueue :: Queue message
  , actorThreadId :: ThreadId
  }

-- | A handle to do things to actors, like sending them messages, fiddling
-- with their threads, or adding an effect that will occur after they've
-- finished executing.
data Actor message = Actor
  { addAfterEffect :: (Maybe SomeException -> IO ()) -> STM ()
  , threadId :: ThreadId
  , send :: message -> STM ()
  }

instance Contravariant Actor where
  contramap f (Actor addAfterEffect threadId send) = Actor addAfterEffect threadId (send . f)

-- | Perform some 'ActionT' in a thread, with some cleanup afterwards.
actFinally :: (Either SomeException a -> IO ()) -> ActionT message IO a -> IO (Actor message)
actFinally errorHandler (ActionT act) = do
  onError <- atomically $ newTVar errorHandler
  messageQueue <- atomically newQueue
  let ctx = ActorContext onError messageQueue
  threadId <- forkFinally (do { tid <- myThreadId; act (ActorContext onError messageQueue tid) }) (\result -> atomically (readTVar onError) >>= ($ result))
  pure $ Actor
    (\afterEffect -> modifyTVar onError (\f x -> f x <* afterEffect (leftToMaybe x)))
    threadId
    (enqueue messageQueue)
  where
    leftToMaybe (Left x) = Just x
    leftToMaybe _ = Nothing

-- | Perform some 'ActionT' in a thread.
act :: ActionT message IO a -> IO (Actor message)
act = actFinally (const (pure ()))
 
-- | Receive a message and do some 'ActionT' with it.
receive :: MonadIO m => (message -> ActionT message m a) -> ActionT message m a
receive f = ActionT \ctx -> do
  message <- liftIO $ atomically $ dequeue (messageQueue ctx)
  runActionT (f message) ctx

-- | Receive a message and, in the same transaction, produce some result.
receiveSTM :: MonadIO m => (message -> STM a) -> ActionT message m a
receiveSTM f = ActionT \ctx -> liftIO (atomically (dequeue (messageQueue ctx) >>= f))

-- | Use a natural transformation to transform an 'ActionT' on one base
-- monad to another.
hoistActionT :: (forall a. m a -> n a) -> ActionT message m a -> ActionT message n a
hoistActionT f (ActionT act) = ActionT (fmap f act)

data LinkKill = LinkKill ThreadId
  deriving Show

instance Exception LinkKill

-- | Link the lifetime of the given actor to this one. If the given actor
-- dies, it will throw a 'LinkKill' exception to us with its 'ThreadId'
-- attached to it.
link :: MonadIO m => Actor message -> ActionT message' m ()
link actor = do
  tid <- actor'sThreadId
  liftIO . atomically $ addAfterEffect actor (\_mexc -> do { tid' <- myThreadId; throwTo tid (LinkKill tid') })

-- | Returns the 'ThreadId' of the actor executing this action. This is
-- possibly more efficient than 'liftIO'ing 'myThreadId', but more than
-- that, it gives us the ability to grab it in arbitrary 'Applicative'
-- contexts, rather than only in 'MonadIO' ones.
actor'sThreadId :: Applicative m => ActionT message' m ThreadId
actor'sThreadId = ActionT \(ActorContext _ _ tid) -> pure tid
