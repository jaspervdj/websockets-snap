{-# LANGUAGE OverloadedStrings #-}

import           Control.Monad      (forever)
import qualified Data.Text          as T
import qualified Network.WebSockets as WS

main :: IO ()
main = WS.runServer "127.0.0.1" 8000 $ \p -> do
  conn <- WS.acceptRequest p
  meow conn

meow :: WS.Connection -> IO ()
meow conn = forever $ do
    msg <- WS.receiveData conn
    WS.sendTextData conn $ msg `T.append` ", meow"
