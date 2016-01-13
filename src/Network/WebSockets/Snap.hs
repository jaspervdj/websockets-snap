{-# LANGUAGE OverloadedStrings #-} -- TODO for testing
{-# LANGUAGE FlexibleContexts #-}  -- TODO for testing

--------------------------------------------------------------------------------
-- | Snap integration for the WebSockets library
{-# LANGUAGE DeriveDataTypeable #-}
module Network.WebSockets.Snap
    ( runWebSocketsSnap
    , runWebSocketsSnapWith
    ) where


--------------------------------------------------------------------------------
import           Blaze.ByteString.Builder      (Builder)
import qualified Blaze.ByteString.Builder      as Builder
import           Control.Concurrent            (forkIO, myThreadId, threadDelay)
import           Control.Concurrent.MVar       (MVar, newEmptyMVar, putMVar,
                                                takeMVar)
import           Control.Exception             (Exception (..),
                                                SomeException (..), handle,
                                                throw, throwTo)
import           Control.Monad                 (forever)
import           Control.Monad.IO.Class        (liftIO)
import           Control.Monad.Trans           (lift)
import           Data.Bool                     (bool)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString.Char8         as BC
import qualified Data.ByteString.Builder       as BSBuilder
import qualified Data.ByteString.Builder.Extra as BSBuilder
import qualified Data.ByteString.Lazy          as BL
import           Data.IORef                    (newIORef, readIORef, writeIORef)
import           Data.Monoid                   ((<>))
import           Data.Typeable                 (Typeable, cast)
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Connection as WS
import qualified Network.WebSockets.Stream     as WS
import qualified Snap.Core                     as Snap
import qualified Snap.Internal.Http.Types      as Snap
import qualified Snap.Types.Headers            as Headers
import           System.IO                     (hFlush, stdout)
import           System.IO.Streams             (InputStream, OutputStream)
import qualified System.IO.Streams             as Streams
import Data.ByteString.Builder.Extra           (flush)
import qualified System.IO.Streams.Combinators as Streams
import qualified System.IO.Streams.Handle      as Streams
import qualified System.IO.Streams.Debug       as Streams


--------------------------------------------------------------------------------
data Chunk
    = Chunk ByteString
    | Eof
    | Error SomeException
    deriving (Show)


--------------------------------------------------------------------------------
data ServerAppDone = ServerAppDone
    deriving (Eq, Ord, Show, Typeable)


--------------------------------------------------------------------------------
instance Exception ServerAppDone where
    toException ServerAppDone       = SomeException ServerAppDone
    fromException (SomeException e) = cast e


--------------------------------------------------------------------------------
-- | The following function escapes from the current 'Snap.Snap' handler, and
-- continues processing the 'WS.WebSockets' action. The action to be executed
-- takes the 'WS.Request' as a parameter, because snap has already read this
-- from the socket.
runWebSocketsSnap :: WS.ServerApp
                  -> Snap.Snap ()
runWebSocketsSnap = runWebSocketsSnapWith WS.defaultConnectionOptions


dropEmpty :: String -> Maybe String
dropEmpty s = bool (Just s) Nothing (null s)

--------------------------------------------------------------------------------
-- | Variant of 'runWebSocketsSnap' which allows custom options
runWebSocketsSnapWith :: WS.ConnectionOptions
                      -> WS.ServerApp
                      -> Snap.Snap ()
runWebSocketsSnapWith options app = do
  rq <- Snap.getRequest
  Snap.escapeHttp $ \tickle readEnd writeEnd -> do
    let tickle' f = print "(calling Tickle)" >> tickle f
    readEnd'  <- Streams.lockingInputStream  readEnd
    writeEnd' <- Streams.lockingOutputStream writeEnd

    readEnd'' <- Streams.debugInput id "InputStream: " Streams.stdout readEnd'
    writeEnd'' <- Streams.debugOutput (BL.toStrict . BSBuilder.toLazyByteString) "OutputStream: " Streams.stdout writeEnd'

    thisThread <- myThreadId
    stream <- WS.makeStream (tickle (max 20) >> Streams.read readEnd'')
              (\v -> Streams.write (fmap BSBuilder.lazyByteString v) writeEnd'' >>
                     Streams.write (Just flush) writeEnd'')
    liftIO $ print "Done making stream"

    let options' = options
                   { WS.connectionOnPong = do
                        print "GOT A PONG"
                        hFlush stdout
                        tickle' (max 30)
                        WS.connectionOnPong options
                   }

        pc = WS.PendingConnection
               { WS.pendingOptions  = options'
               , WS.pendingRequest  = fromSnapRequest rq
               , WS.pendingOnAccept = forkPingThread tickle'
               , WS.pendingStream   = stream
               }
    app pc >> print "app exited" >> throwTo thisThread ServerAppDone


--------------------------------------------------------------------------------
-- | Start a ping thread in the background
forkPingThread :: ((Int -> Int) -> IO ()) -> WS.Connection -> IO ()
forkPingThread tickle conn = do
    _ <- forkIO pingThread
    return ()
  where
    pingThread = handle ignore $ forever $ do
        WS.sendPing conn (BC.pack "ping")
        print "TICKLING"
        tickle (min 30)
        threadDelay $ 5 * 1000 * 1000

    ignore :: SomeException -> IO ()
    ignore _   = return ()


--------------------------------------------------------------------------------
-- | Convert a snap request to a websockets request
fromSnapRequest :: Snap.Request -> WS.RequestHead
fromSnapRequest rq = WS.RequestHead
    { WS.requestPath    = Snap.rqURI rq
    , WS.requestHeaders = Headers.toList (Snap.rqHeaders rq)
    , WS.requestSecure  = Snap.rqIsSecure rq
    }
