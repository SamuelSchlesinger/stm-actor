module Main where

import Control.Concurrent.Actor.Prelude
import System.Exit

exiter :: ActionT () IO ()
exiter = do
  liftBase $ exitWith ExitSuccess

watcher :: ActionT ExitCode IO ()
watcher = do
  (address, results) <- spawnWatch exiter id
  msg <- next
  liftBase $ print msg

main = do
  (address, result) <- spawnM watcher
  atomically $ readTMVar result
