{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE BlockArguments #-}
module Main where

import Test.Hspec
import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad
import Control.Concurrent.MVar
import Control.Monad.IO.Class
import Control.Concurrent.Actor
import Control.Exception

main :: IO ()
main = hspec $ do
  describe "Control.Concurrent.Actor" do
    describe "actFinally" do
      it "does the thing on success" do
        mvar <- newEmptyMVar
        actFinally (either (const (putMVar mvar False)) (const (putMVar mvar True))) (pure ())
        takeMVar mvar `shouldReturn` True
      it "does the thing on error" do
        mvar <- newEmptyMVar
        actFinally (either (const (putMVar mvar True)) (const (putMVar mvar False))) (liftIO $ throwIO Underflow)
        takeMVar mvar `shouldReturn` True
    describe "act" do
      it "forks a real-live thread" do
        actorHandle <- act (forever $ pure ())
        killThread (threadId actorHandle)
    describe "receive" do
      it "can receive messages" do
        mvar <- newEmptyMVar
        actorHandle <- (act . receive) \msg -> do
          liftIO $ putMVar mvar msg
        atomically (send actorHandle ())
        liftIO $ takeMVar mvar
    describe "receiveSTM" do
      it "can receive messages" do
        tvar <- newTVarIO False
        actorHandle <- act (receiveSTM (writeTVar tvar))
        atomically (send actorHandle True)
        atomically $ readTVar tvar >>= \case { True -> pure (); False -> retry }
