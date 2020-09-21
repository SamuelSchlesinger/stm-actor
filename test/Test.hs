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
import Control.Monad.Reader
import Control.Monad.Trans
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
    describe "receive" do
      it "can receive messages" do
        mvar <- newEmptyMVar
        actor <- (act . receive) \msg -> do
          liftIO $ putMVar mvar msg
        atomically (send actor ())
        liftIO $ takeMVar mvar
    describe "receiveSTM" do
      it "can receive messages" do
        tvar <- newTVarIO False
        actor <- act (receiveSTM (writeTVar tvar))
        atomically (send actor True)
        atomically do
          readTVar tvar >>= \case
            True -> pure ()
            False -> retry
    describe "hoistActionT" do
      it "hoists ActionTs" do
        tvar <- newTVarIO (Right False)
        actor <- (act . hoistActionT (flip runReaderT True)) do
          stuff <- ask
          liftIO (putStrLn "Heya")
          if stuff then liftIO (atomically $ writeTVar tvar (Right True))
                   else liftIO (atomically $ writeTVar tvar (Left ()))
        atomically
          (readTVar tvar >>= \case
            Right True -> pure "Yay, we can hoist ReaderT actions"
            Right False -> retry
            Left () -> pure "Boo!")
          `shouldReturn` "Yay, we can hoist ReaderT actions"
    describe "link" do
      it "links actors" do
        mvar <- newEmptyMVar
        diddler <- act do
          liftIO $ threadDelay 1000000
          liftIO $ throwIO Underflow
        fiddler <- actFinally (either (const (putMVar mvar ())) (const (pure ()))) do
          link diddler
          forever do
            liftIO $ threadDelay 1000
        takeMVar mvar `shouldReturn` ()

