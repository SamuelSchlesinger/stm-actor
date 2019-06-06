{-# LANGUAGE FlexibleContexts #-}

module Control.Concurrent.Actor.Prelude
  ( module Control.Concurrent.Lifted,
    module Control.Exception.Lifted,
    module Control.Monad.State.Class,
    module Control.Monad.Trans,
    module Control.Monad.Base,
    module Control.Monad.Trans.Control,
    module Control.Monad,
    module Control.Concurrent.Actor,
    module Control.Concurrent.STM,
    module System.Mem.Weak,
    module Numeric.Natural,
    atomicallyM,
    newTVarM, readTVarM, registerDelayM, mkWeakTVarM,
    newTMVarM, newEmptyTMVarM, mkWeakTMVarM,
    newTChanM, newBroadcastTChanM,
    newTQueueM ) where

import Numeric.Natural
import Control.Concurrent.Lifted
import Control.Monad.Trans.Control
import Control.Monad.Trans
import Control.Exception.Lifted
import Control.Monad.State.Class
import Control.Monad.Base
import Control.Monad
import Control.Concurrent.Actor
import Control.Concurrent.STM
import qualified Control.Concurrent.STM as STM
import System.Mem.Weak

atomicallyM :: MonadBase IO m => STM a -> m a
atomicallyM = liftBase . STM.atomically

newTVarM :: MonadBase IO m => a -> m (TVar a)
newTVarM = liftBase . newTVarIO

readTVarM :: MonadBase IO m => TVar a -> m a
readTVarM = liftBase . readTVarIO

registerDelayM :: MonadBase IO m => Int -> m (TVar Bool)
registerDelayM = liftBase . registerDelay

mkWeakTVarM :: MonadBase IO m => TVar a -> IO () -> m (Weak (TVar a))
mkWeakTVarM tv io = liftBase (mkWeakTVar tv io)

newTMVarM :: MonadBase IO m => a -> m (TMVar a)
newTMVarM = liftBase . newTMVarIO

newEmptyTMVarM :: MonadBase IO m => m (TMVar a)
newEmptyTMVarM = liftBase newEmptyTMVarIO

mkWeakTMVarM :: MonadBase IO m => TMVar a -> IO () -> m (Weak (TMVar a))
mkWeakTMVarM tv io = liftBase (mkWeakTMVar tv io)

newTChanM :: MonadBase IO m => m (TChan a)
newTChanM = liftBase newTChanIO

newBroadcastTChanM :: MonadBase IO m => m (TChan a)
newBroadcastTChanM = liftBase newBroadcastTChanIO

newTQueueM :: MonadBase IO m => m (TQueue a)
newTQueueM = liftBase newTQueueIO

newTBQueueM :: MonadBase IO m => Natural -> m (TBQueue a)
newTBQueueM n = liftBase (newTBQueueIO n)
