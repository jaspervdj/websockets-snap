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
import           Control.Concurrent            (forkIO, myThreadId)
import           Control.Concurrent.MVar       (MVar, newEmptyMVar, putMVar,
                                                takeMVar)
import           Control.Exception             (Exception (..),
                                                SomeException (..), throw,
                                                throwTo)
import           Control.Monad.Trans           (lift)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString.Builder       as BSBuilder
import qualified Data.ByteString.Builder.Extra as BSBuilder
import qualified Data.ByteString.Lazy          as BL
--import qualified Data.Enumerator               as E
import           Data.IORef                    (newIORef, readIORef, writeIORef)
import           Data.Monoid                   ((<>))
import           Data.Typeable                 (Typeable, cast)
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Connection as WS
import qualified Network.WebSockets.Stream     as WS
import qualified Snap.Core                     as Snap
import qualified Snap.Internal.Http.Types      as Snap
import qualified Snap.Types.Headers            as Headers
import           System.IO.Streams             (InputStream, OutputStream)
import qualified System.IO.Streams             as Streams
import qualified System.IO.Streams.Combinators as Streams


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


--------------------------------------------------------------------------------
-- | Variant of 'runWebSocketsSnap' which allows custom options
runWebSocketsSnapWith :: WS.ConnectionOptions
                      -> WS.ServerApp
                      -> Snap.Snap ()
runWebSocketsSnapWith options app = do
  rq <- Snap.getRequest
  Snap.escapeHttp $ \tickle readEnd writeEnd -> do

    let debugRead s = do
          putStrLn "About to read"
          r <- Streams.read s
          putStrLn $ "Read " ++ show r
          return r

    let debugWrite v s = do
          putStrLn $ "About to write " ++ show (BSBuilder.toLazyByteString <$> v)
          r <- Streams.write v s
          putStrLn $ "Wrote"

    thisThread <- myThreadId
    stream <- WS.makeStream
              (Streams.read readEnd)
              (\v ->
                 Streams.write (((<> BSBuilder.flush) . BSBuilder.lazyByteString) <$> v) writeEnd
              )

    let options' = options
                   { WS.connectionOnPong = do
                        tickle (max 30)
                        WS.connectionOnPong options
                   }

        pc = WS.PendingConnection
               { WS.pendingOptions = options'
               , WS.pendingRequest = fromSnapRequest rq
               , WS.pendingOnAccept = \_ -> return ()
               , WS.pendingStream   = stream
               }
    app pc >> throwTo thisThread ServerAppDone


--------------------------------------------------------------------------------
-- | Convert a snap request to a websockets request
fromSnapRequest :: Snap.Request -> WS.RequestHead
fromSnapRequest rq = WS.RequestHead
    { WS.requestPath    = Snap.rqURI rq
    , WS.requestHeaders = Headers.toList (Snap.rqHeaders rq)
    , WS.requestSecure  = Snap.rqIsSecure rq
    }

    
