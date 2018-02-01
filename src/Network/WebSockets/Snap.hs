--------------------------------------------------------------------------------
-- | Snap integration for the WebSockets library
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
module Network.WebSockets.Snap
    ( runWebSocketsSnap
    , runWebSocketsSnapWith
    ) where


--------------------------------------------------------------------------------
import           Control.Concurrent            (forkIO, myThreadId, threadDelay)
import           Control.Exception             (Exception (..),
                                                SomeException (..), handle,
                                                throwTo)
import           Control.Monad                 (forever)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString.Builder       as BSBuilder
import qualified Data.ByteString.Builder.Extra as BSBuilder
import qualified Data.ByteString.Char8         as BC
import           Data.Typeable                 (Typeable, cast)
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Connection as WS
import qualified Network.WebSockets.Stream     as WS
import qualified Snap.Core                     as Snap
import qualified Snap.Types.Headers            as Headers
import qualified System.IO.Streams             as Streams


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
runWebSocketsSnap
    :: Snap.MonadSnap m
    => WS.ServerApp
    -> m ()
runWebSocketsSnap = runWebSocketsSnapWith WS.defaultConnectionOptions


--------------------------------------------------------------------------------
-- | Variant of 'runWebSocketsSnap' which allows custom options
runWebSocketsSnapWith
  :: Snap.MonadSnap m
  => WS.ConnectionOptions
  -> WS.ServerApp
  -> m ()
runWebSocketsSnapWith options app = do
  rq <- Snap.getRequest
  Snap.escapeHttp $ \tickle readEnd writeEnd -> do

    thisThread <- myThreadId
    stream <- WS.makeStream (Streams.read readEnd)
              (\v -> do
                  Streams.write (fmap BSBuilder.lazyByteString v) writeEnd
                  Streams.write (Just BSBuilder.flush) writeEnd
              )

    let options' = options
                   { WS.connectionOnPong = do
                        tickle (max 45)
                        WS.connectionOnPong options
                   }

        pc = WS.PendingConnection
               { WS.pendingOptions  = options'
               , WS.pendingRequest  = fromSnapRequest rq
               , WS.pendingOnAccept = forkPingThread tickle
               , WS.pendingStream   = stream
               }
    app pc >> throwTo thisThread ServerAppDone


--------------------------------------------------------------------------------
-- | Start a ping thread in the background
forkPingThread :: ((Int -> Int) -> IO ()) -> WS.Connection -> IO ()
forkPingThread tickle conn = do
    _ <- forkIO pingThread
    return ()
  where
    pingThread = handle ignore $ forever $ do
        WS.sendPing conn (BC.pack "ping")
        tickle (max 60)
        threadDelay $ 10 * 1000 * 1000

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
