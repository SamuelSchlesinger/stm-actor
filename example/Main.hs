{-# LANGUAGE RecordWildCards,
             ExistentialQuantification,
             FlexibleContexts,
             ScopedTypeVariables,
             LambdaCase,
             TypeOperators,
             MultiParamTypeClasses,
             TypeApplications #-}

module Main where

import Control.Concurrent.Actor.Prelude
import Control.Applicative (liftA2)
import Control.Monad.Reader
import Data.Hashable (Hashable)
import Data.HashMap.Strict (HashMap, (!))
import Data.List (partition)
import Control.Monad.Trans (lift)

-- | The class of things which are partially comparable. If 
-- `pcompare x y = Nothing`, we say that `x` and `y` are incomparable,
-- otherwise we say that they are comparable. Things which return 
-- `Just GT` or `Just EQ` induce a relation which should be transitive
-- and reflexive.
--
class Eq p => POrd p where
  pcompare :: p -> p -> Maybe Ordering

-- Temporary type for a tag
type Tag = String

data Spec msg m tag = Spec {
    act :: ActionT msg m ()
  , tag :: tag
}

data ActorSpec m tag = forall msg. ActorSpec { unActorSpec :: Spec msg m tag }

-- TODO: Supervisor logic
--------------------------------------------------------------------------------
-- The various Specs induce a sub-ordering of our partially order type "p" and
-- thus we can build the directed graph which corresponds to that
-- sub-ordering. When an actor dies, its tag as well as all of its `pops`
-- will be added to the restart queue. The supervisor will be keeping track
-- of the restart queue and will restart anything it can dequeue from
-- there.
--
-- I believe we can use `hoistSpawnMFinally _ _ lift` to do the spawning
-- with the current type signature.  

data Actor m tag = forall msg. Actor {
    spec :: Spec msg m tag
  , pops :: [ActorRef m tag]
  , tid  :: ThreadId
}

actorTag :: Actor m tag -> tag
actorTag Actor{..} = tag spec

type ActorRef m tag = TMVar (Actor m tag)

data Vars m tag = Vars {
    tagMap :: HashMap tag (ActorRef m tag)
  , restartQueue :: TMVar [tag]
}

data Dead tag = Dead tag

-- TODO
prepareVars
  :: ( Hashable tag
     , MonadBaseControl IO m
     , POrd tag ) 
    => [ActorSpec m tag] 
    -> m (Vars m tag)
prepareVars aspecs = undefined

startSpec :: MonadBaseControl IO m => Spec msg m tag -> ReaderT (Vars m tag) m ()
startSpec (Spec{..} :: Spec msg m tag) = void $ hoistSpawnMFinally @msg act _ _ 

-- TODO
restarter
  :: ( Hashable tag
     , MonadBaseControl IO m
     , POrd tag ) 
    => ActionT (Dead tag) (ReaderT (Vars m tag) m) ()
restarter = restartQueue <$> ask >>= atomicallyM . takeTMVar >>= go where
  go []       = threadDelay 10000 >> restarter
  go (x : xs) = do
    Actor{..} <- ((! x) . tagMap <$> ask) >>= atomicallyM . takeTMVar
    killThread tid
    lift $ startSpec spec


main = pure ()
