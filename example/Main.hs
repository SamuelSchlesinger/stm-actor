{-# LANGUAGE RecordWildCards,
             ExistentialQuantification,
             FlexibleContexts,
             ScopedTypeVariables,
             LambdaCase #-}

module Main where

import Control.Concurrent.Actor.Prelude
import System.Exit
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Control.Monad.State.Strict
import System.Random hiding (next)
import Control.Monad.Fail
import System.Environment

data Spec m env = forall msg a s. Spec {
  actionT :: ActionT msg (StateT s m) a,
  onFinish :: a -> m (),
  initState :: env -> m s
}

data ActiveSpec m env = forall msg a s. ActiveSpec {
  activeActionT :: ActionT msg (StateT s m) a,
  activeOnFinish :: a -> m (),
  activeInitState :: env -> m s,
  activeAddress :: Address msg,
  activeResult :: TMVar (Result a)
}

unactive :: ActiveSpec m env -> Spec m env
unactive ActiveSpec{..} = Spec activeActionT activeOnFinish activeInitState

data M = M {
  tid :: ThreadId,
  exc :: SomeException
}

type S m env = Map ThreadId (ActiveSpec m env)

type Supervisor m env = ActionT M (StateT (S m env) m) ()

supervisor0 :: (MonadBaseControl IO m, MonadFail m) => env -> Supervisor m env
supervisor0 env = do
  specs <- get
  if Map.null specs then do
    return ()
  else do
    m <- nextMaybe
    case m of
      Just M{..} -> do
        specs <- get
        case Map.lookup tid specs of
          Nothing -> supervisor0 env
          Just a -> do
            put $ Map.delete tid specs
            startSpec (unactive a) env
            supervisor0 env
      Nothing -> do
        yield
        forM_ (Map.toList specs) $ \(tid, ActiveSpec{..}) -> do
          m <- atomicallyM $ tryReadTMVar activeResult
          case m of
            Just (Success x) -> do
              put $ Map.delete tid specs
            _ -> return ()
        supervisor0 env

startSpec :: (MonadFail m, MonadBaseControl IO m) => Spec m env -> env -> ActionT M (StateT (S m env) m) ()
startSpec Spec{..} env = do
  m <- get
  s <- lift $ lift $ initState env
  (address, result) <- lift . lift $ evalStateT (spawnM (yield >> actionT)) s
  watch address M
  let activeSpec = ActiveSpec
                     actionT
                     onFinish
                     initState
                     address
                     result
  lift $ lift $ forkFinally (do
    ans <- atomicallyM $ readTMVar result
    case ans of
      Success a -> return a
      Failure e -> error "Sad") (\case
        Right a -> onFinish a
        Left  e -> return ())
  put $ Map.insert (addressThreadId address) activeSpec m

supervise :: (MonadFail m, MonadBaseControl IO m) => [Spec m env] -> env -> m (Address M, TMVar (Result ()))
supervise specs env = evalStateT (spawnM $ go specs env) Map.empty where
  go [] env = supervisor0 env
  go (spec : specs) env = do
    startSpec spec env
    go specs env

badboy :: ActionT () (StateT () IO) (ThreadId, Integer)
badboy = do
  x :: Integer <- liftBase $ randomRIO (1, 10)
  if x == 6 then do
    id <- myThreadId
    return (id, 0)
  else
    liftBase $ exitWith $ ExitFailure 1

test :: Int -> [Spec IO ()]
test n = take n $ repeat $ Spec badboy print (const $ return ())

main = do
  [nArg] <- getArgs
  let n = read nArg
  (address, result) <- supervise (test n) ()
  atomically $ readTMVar result
  return ()
