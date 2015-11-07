--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
module Main where


--------------------------------------------------------------------------------
import           Control.Concurrent      (forkIO, threadDelay)
import           Control.Exception       (finally)
import           Control.Monad           (forever, unless)
import           Control.Monad.IO.Class  (liftIO)
import qualified Data.ByteString         as B
import qualified Data.ByteString.Char8   as BC
import qualified Data.Text               as T
import qualified Network.WebSockets      as WS
import qualified Network.WebSockets.Snap as WS
import           Snap.Core               (Snap)
import qualified Snap.Core               as Snap
import qualified Snap.Http.Server.Config as Snap
import qualified Snap.Http.Server        as Snap
import qualified Snap.Util.FileServe     as Snap
import qualified System.IO               as IO
import qualified System.Process          as Process


--------------------------------------------------------------------------------
app :: Snap ()
app = Snap.route
    [ ("",               Snap.ifTop $ Snap.serveFile "console.html")
    , ("console.js",     Snap.serveFile "console.js")
    , ("console/:shell", console)
    , ("style.css",      Snap.serveFile "style.css")
    , ("text",           WS.runWebSocketsSnap consoleApp2)
    , ("meow",           WS.runWebSocketsSnap meow)
    ]


--------------------------------------------------------------------------------
console :: Snap ()
console = do
    Just shell <- Snap.getParam "shell"
    WS.runWebSocketsSnap $ consoleApp $ BC.unpack shell


meow :: WS.PendingConnection -> IO ()
meow p = do
  conn <- WS.acceptRequest p
  forever $ do
    msg <- WS.receiveData conn
    WS.sendTextData conn $ msg `T.append` ", meow"


--------------------------------------------------------------------------------
consoleApp :: String -> WS.ServerApp
consoleApp shell pending = do
    liftIO $ putStrLn "STARTING CONSOLE APP"
    (stdin, stdout, stderr, phandle) <- Process.runInteractiveCommand shell
    liftIO $ putStrLn "ACCEPTREQUEST waiting"
    conn                             <- WS.acceptRequest pending
    liftIO $ putStrLn "ACCEPTREQUEST returned"

    liftIO $ putStrLn "FORKING copyHandle etc"
    _ <- forkIO $ copyHandleToConn stdout conn
    _ <- forkIO $ copyHandleToConn stderr conn
    _ <- forkIO $ copyConnToHandle conn stdin
    liftIO $ putStrLn "DONE FORKING copyHandle etc"

    liftIO $ putStrLn "WAITING for processes to finish"
    exitCode <- Process.waitForProcess phandle
    liftIO $ putStrLn "PROCESS FINISHED"
    putStrLn $ "consoleApp ended: " ++ show exitCode


consoleApp2 :: WS.ServerApp
consoleApp2 pending = do
  conn <- WS.acceptRequest pending
  putStrLn "console2"
  forever $ do
    WS.sendTextData conn ("HELLO!" :: T.Text)
    putStrLn "Sent data"
    threadDelay 500000

--------------------------------------------------------------------------------
copyHandleToConn :: IO.Handle -> WS.Connection -> IO ()
copyHandleToConn h c = do
    bs <- B.hGetSome h 1024
    unless (B.null bs) $ do
        putStrLn $ "> " ++ show bs
        WS.sendTextData c bs
        copyHandleToConn h c


--------------------------------------------------------------------------------
copyConnToHandle :: WS.Connection -> IO.Handle -> IO ()
copyConnToHandle c h = flip finally (IO.hClose h) $ forever $ do
    bs <- WS.receiveData c
    putStrLn $ "< " ++ show bs
    B.hPutStr h bs
    IO.hFlush h


--------------------------------------------------------------------------------
main :: IO ()
main = Snap.httpServe config app
  where
    config =
        --Snap.setErrorLog  Snap.ConfigNoLog $
        --Snap.setAccessLog Snap.ConfigNoLog $
        -- Snap.defaultConfig
        (Snap.setPort 8000 mempty)
