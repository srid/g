{-# LANGUAGE GADTs #-}

module Main where

import Control.Concurrent.Async (race_)
import Control.Concurrent.STM (newTChanIO, readTChan, writeTChan)
import qualified Emanote.Pipeline as Pipeline
import qualified Emanote.WebServer as WS
import Emanote.Zk (Zk)
import qualified Emanote.Zk as Zk
import GHC.IO.Handle (BufferMode (LineBuffering), hSetBuffering)
import Main.Utf8 (withUtf8)
import Options.Applicative
import Reflex (Reflex (never))
import Reflex.Host.Headless (runHeadlessApp)
import System.FilePath (addTrailingPathSeparator)

cliParser :: Parser FilePath
cliParser =
  fmap
    addTrailingPathSeparator
    (strArgument (metavar "INPUT" <> help "Input directory path (.md files)"))

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  withUtf8 $ do
    inputDir <- execParser $ info (cliParser <**> helper) fullDesc
    ready <- newTChanIO @Zk
    race_
      -- Run the Reflex network that will produce the Zettelkasten (Zk)
      ( runHeadlessApp $ do
          zk <- Pipeline.run inputDir
          atomically $ writeTChan ready zk
          pure never
      )
      -- Start consuming the Zk as soon as it is ready.
      ( do
          zk <- atomically $ readTChan ready
          race_
            -- HTTP server
            (WS.run inputDir zk)
            -- Run TIncremental to process Reflex patches
            (Zk.run zk)
      )
