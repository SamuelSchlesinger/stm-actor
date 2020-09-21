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
) where

import Control.Concurrent
import Control.Monad.IO.Class
import Control.Monad.Trans
import Control.Monad.Reader
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

instance Functor m => Functor (ActionT message m) where
  fmap f (ActionT act) = ActionT (fmap f . act)

instance Applicative m => Applicative (ActionT message m) where
  pure x = ActionT \_ctx -> pure x
  ActionT af <*> ActionT ax = ActionT \ctx -> af ctx <*> ax ctx

instance Monad m => Monad (ActionT message m) where
  ActionT ax >>= f = ActionT \ctx -> do
    x <- ax ctx
    runActionT (f x) ctx

instance MonadIO m => MonadIO (ActionT message m) where
  liftIO io = ActionT \_ctx -> liftIO io

instance MonadTrans (ActionT message) where
  lift a = ActionT \_ctx -> a

instance MonadReader r m => MonadReader r (ActionT message m) where
  ask = lift ask
  local f (ActionT ma) = ActionT \ctx -> local f (ma ctx)

data ActorContext message = forall a. ActorContext
  { onError      :: TVar (Either SomeException a -> IO ())
  , messageQueue :: Queue message
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
  threadId <- forkFinally (act ctx) (\result -> atomically (readTVar onError) >>= ($ result))
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
