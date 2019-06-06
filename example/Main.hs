{-# LANGUAGE RecordWildCards,
             ExistentialQuantification,
             FlexibleContexts,
             ScopedTypeVariables #-}

module Main where

import Control.Concurrent.Actor.Prelude
import System.Exit
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Monad.State.Strict
import System.Random

data Spec m env = forall msg a s. Spec {
  actionT :: ActionT msg (StateT s m) a,
  onFinish :: a -> m (),
  init :: env -> m s
}

data ActiveSpec m env = forall msg a s. ActiveSpec {
  activeActionT :: ActionT msg (StateT s m) a,
  activeOnFinish :: a -> m (),
  activeInit :: env -> m s,
  activeAddress :: Address msg,
  activeResult :: TMVar (Result a)
}

data M = M {
  tid :: ThreadId,
  exc :: SomeException
}

type S m env = Map ThreadId (ActiveSpec m env)

type Supervisor m env = ActionT M (StateT (S m env) m) ()

supervisor0 :: MonadBaseControl IO m => env -> Supervisor m env
supervisor0 env = do
  specs <- get
  m <- nextMaybe
  case m of
    Just M{..} -> do
      specs <- get
      case Map.lookup tid specs of
        Nothing -> supervisor1 env
        Just ActiveSpec{..} -> do
          s <- lift . lift $ activeInit env
          (address, result) <- lift . lift $ evalStateT (spawnM (threadDelay 100 >> activeActionT)) s
          watch address M
          let activeSpec' = ActiveSpec
                             activeActionT
                             activeOnFinish
                             activeInit
                             address
                             result
          put $ Map.delete tid $ Map.insert (addressThreadId address) activeSpec' specs
          supervisor1 env
    Nothing -> supervisor1 env

supervisor1 :: MonadBaseControl IO m => env -> Supervisor m env
supervisor1 env = do
  specs <- get
  if Map.null specs then do
    return ()
  else do
    forM_ (Map.toList specs) $ \(tid, ActiveSpec{..}) -> do
      res <- atomicallyM $ tryReadTMVar activeResult
      case res of
        Just (Success a) -> do
          lift $ lift $ activeOnFinish a
          put $ Map.delete tid specs
        _ -> return ()
    supervisor0 env

supervise :: MonadBaseControl IO m => [Spec m env] -> env -> m (Address M, TMVar (Result ()))
supervise specs env = evalStateT (spawnM $ go specs env) Map.empty where
  go [] env = supervisor0 env
  go (Spec{..} : specs) env = do
    m <- get
    s <- lift . lift $ init env
    (address, result) <- lift . lift $ evalStateT (spawnM (threadDelay 100 >> actionT)) s
    watch address M
    let activeSpec  = ActiveSpec
                       actionT
                       onFinish
                       init
                       address
                       result
    put $ Map.insert (addressThreadId address) activeSpec m
    go specs env

badboy :: ActionT () (StateT () IO) Integer
badboy = do
  x :: Integer <- liftBase $ randomRIO (1, 10)
  if x == 6 then
    return 0
  else
    liftBase $ exitWith $ ExitFailure 1



test :: [Spec IO ()]
test = [Spec badboy print (const $ return ())]

main = do
  (address, result) <- supervise test ()
  atomically $ readTMVar result
  return ()
