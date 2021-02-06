{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}

module Emanote where

import Control.Concurrent.Async (race_)
import Control.Concurrent.STM (newTChanIO, readTChan, writeTChan)
import qualified Emanote.Pipeline as Pipeline
import qualified Emanote.WebServer as WS
import Emanote.Zk (Zk)
import qualified Emanote.Zk as Zk
import Options.Applicative
import Reflex (Reflex (never))
import Reflex.Host.Headless (runHeadlessApp)
import Relude

emanoteMain :: FilePath -> IO ()
emanoteMain inputDir = do
  emanoteMainWith inputDir (WS.run inputDir)

emanoteMainWith :: FilePath -> (Zk -> IO ()) -> IO ()
emanoteMainWith inputDir f = do
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
          -- Custom action
          (f zk)
          -- Run TIncremental to process Reflex patches
          (Zk.run zk)
    )