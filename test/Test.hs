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
    describe "murder" do
      it "kills actors" do
        mvar <- newEmptyMVar
        actor <- actFinally (either (const (putMVar mvar ())) (const (pure ()))) do
          liftIO $ threadDelay 1000000
        murder actor
        takeMVar mvar `shouldReturn` ()
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
    describe "linkSTM" do
      it "links actors too" do
        mvar <- newEmptyMVar
        diddler <- actFinally (either (const (putMVar mvar ())) (const (pure ()))) do
          liftIO $ threadDelay 1000000
        fiddler <- act do
          liftIO $ threadDelay 1000000
        atomically (linkSTM diddler fiddler)
        murder fiddler
        takeMVar mvar `shouldReturn` ()
    describe "self" do
      it "is the real Actor of actors" do
        mvar <- newEmptyMVar
        diddler <- act $ forever do
          me <- self
          liftIO (putMVar mvar me)
        them <- takeMVar mvar
        diddler `shouldBe` them
    describe "livenessCheck" do
      it "notes when an actor is Completed" do
        diddler <- act (pure ())
        threadDelay 1000000
        atomically (livenessCheck diddler) >>= \case
          Completed -> pure ()
          _ -> expectationFailure "Liveness check did not result in Completed"
      it "notes when an actor ThrewException" do
        diddler <- act (liftIO $ throwIO Underflow)
        threadDelay 1000000
        atomically (livenessCheck diddler) >>= \case
          ThrewException e -> pure ()
          _ -> expectationFailure "Liveness check did not result in ThrewException"
      it "notes when an actor is Alive" do
        diddler <- act (liftIO $ threadDelay 1000000)
        atomically (livenessCheck diddler) >>= \case
          Alive -> pure ()
          _ -> expectationFailure "Liveness check did not result in Alive"
    describe "withLivenessCheck" do
      it "doesn't let you add after effects to dead actors" do
        diddler <- act (pure ())
        threadDelay 1000000
        atomically (withLivenessCheck addAfterEffect diddler (const (pure ()))) `shouldThrow` \case
          ActorDead Nothing -> True
          _ -> False
      it "doesn't let you send messages to dead actors" do
        diddler <- act (pure ())
        threadDelay 1000000
        atomically (withLivenessCheck send diddler "HEY") `shouldThrow` \case
          ActorDead Nothing -> True
          _ -> False
