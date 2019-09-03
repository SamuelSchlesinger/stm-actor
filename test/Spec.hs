{-# LANGUAGE
    ScopedTypeVariables #-}

import Control.Concurrent.Actor.Prelude

add :: TMVar Int -> Int -> ActionT () IO ()
add v i = liftBase $ atomically $ do
  x <- takeTMVar v
  putTMVar v (x + i)

main :: IO ()
main = do
  x <- atomically $ newTMVar 0
  results :: [(Address (), Result ())] <- mapM spawnIO [ add x 1 | _ <- [1..100]]
  atomically (readTMVar x) >>= print
