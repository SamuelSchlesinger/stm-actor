module Main where

import MailboxWindTunnel (runCLI)
import System.Environment (getArgs)

main :: IO ()
main = getArgs >>= runCLI
