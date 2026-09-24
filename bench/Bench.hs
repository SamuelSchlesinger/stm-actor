{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE BlockArguments #-}
module Main where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Actor
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
import Control.Monad (forM_, forever, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Numeric.Natural (Natural)
import System.Environment (getArgs)

-- | Fan-in throughput: @senders@ threads send to one actor for one second.
-- Compares an unbounded mailbox with a bounded one, which exercises the
-- capacity accounting shared between senders and the actor.
--
-- With more senders than capacity permits, the bounded figure is dominated by
-- STM wakeups: every receive wakes every sender blocked on the full mailbox.
-- That cost grows with the number of capabilities, so compare runs at a fixed
-- @+RTS -N@ setting.
fanIn :: Int -> String -> Maybe Natural -> IO ()
fanIn senders label capacity = do
  received <- newIORef (0 :: Int)
  actor <- actWith defaultActorConfig { mailboxCapacity = capacity } $
    forever $ receive \() -> liftIO (modifyIORef' received (+ 1))
  stop <- newTVarIO False
  finished <- newEmptyMVar
  forM_ [1 .. senders] \_ -> forkIO do
    let loop !sent = do
          continue <- atomically do
            stopped <- readTVar stop
            if stopped then pure False else send actor () >> pure True
          if continue then loop (sent + 1) else putMVar finished (sent :: Int)
    loop 0
  threadDelay 1000000
  atomically (writeTVar stop True)
  sent <- sum <$> mapM (const (takeMVar finished)) [1 .. senders]
  murder actor
  _ <- atomically (awaitEffects actor)
  count <- readIORef received
  putStrLn
    (  label <> ": " <> show senders <> " senders, "
    <> show count <> " received, " <> show sent <> " sent"
    )

main :: IO ()
main = do
  args <- getArgs
  let senderCounts = case args of
        [] -> [1, 4, 16]
        _ -> map read args
  forM_ senderCounts \senders -> do
    fanIn senders "unbounded mailbox" Nothing
    fanIn senders "bounded mailbox (1024)" (Just 1024)
    when (senders /= last senderCounts) (putStrLn "")
