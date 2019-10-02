{-# LANGUAGE RecordWildCards,
             ExistentialQuantification,
             FlexibleContexts,
             ScopedTypeVariables,
             LambdaCase,
             TypeOperators,
             MultiParamTypeClasses #-}

module Main where

import Control.Concurrent.Actor.Prelude
import Control.Applicative (liftA2)
import Data.Hashable

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

data Actor m tag = forall msg. Actor {
    spec :: Spec msg m tag
  , pops :: [ActorRef m tag]
}

type ActorRef m tag = TVar (Actor m tag)

-- Supervisor logic
--------------------------------------------------------------------------------
-- The various Specs induce a sub-ordering of our partially order type "p" and
-- thus we can build the directed graph which corresponds to that
-- sub-ordering. When an actor dies, it will run up that graph and add
-- everything it sees to the restart-queue.

buildActors :: (Hashable tag, MonadBaseControl IO m) => [ActorSpec m tag] -> m [Actor m tag]
buildActors aspecs = undefined

main = pure ()
