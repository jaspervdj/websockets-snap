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
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Enumerator               as E
import qualified Data.Enumerator.List          as EL
import           Data.IORef                    (newIORef, readIORef, writeIORef)
import           Data.Typeable                 (Typeable, cast)
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Connection as WS
import qualified Snap.Core                     as Snap
import qualified Snap.Internal.Http.Types      as Snap
import qualified Snap.Types.Headers            as Headers
import           System.IO.Streams             (InputStream, OutputStream)
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
copyIterateeToMVar :: MVar Chunk -> E.Iteratee ByteString IO ()
copyIterateeToMVar mvar = E.catchError go handler
  where
    go = do
        mbs <- EL.head
        case mbs of
            Just x  -> lift (putMVar mvar (Chunk x)) >> go
            Nothing -> lift (putMVar mvar Eof)

    handler se@(SomeException e) = case cast e of
        -- Clean exit
        Just ServerAppDone -> return ()
        -- Actual error
        Nothing            -> lift $ putMVar mvar $ Error se


--------------------------------------------------------------------------------
copyMVarToInputStream :: MVar Chunk -> IO (InputStream ByteString)
copyMVarToInputStream mvar = Streams.makeInputStream go
  where
    go = do
        chunk <- takeMVar mvar
        case chunk of
            Chunk x                 -> return (Just x)
            Eof                     -> return Nothing
            Error (SomeException e) -> throw e


--------------------------------------------------------------------------------
copyOutputStreamToIteratee :: E.Iteratee ByteString IO ()
                           -> IO (OutputStream Builder)
copyOutputStreamToIteratee iteratee0 = do
    ref <- newIORef =<< E.runIteratee iteratee0
    Streams.makeOutputStream (go ref)
  where
    go _   Nothing    = return ()
    go ref (Just bld) = do
        step <- readIORef ref
        case step of
            E.Continue f              -> do
                let chunks = BL.toChunks $ Builder.toLazyByteString bld
                step' <- E.runIteratee $ f $ E.Chunks chunks
                writeIORef ref step'
            E.Yield () _              -> throw WS.ConnectionClosed
            E.Error (SomeException e) -> throw e


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
    Snap.escapeHttp $ \tickle writeEnd -> do

        thisThread <- lift myThreadId
        mvar       <- lift newEmptyMVar
        is         <- lift $ copyMVarToInputStream mvar
        os         <- lift $ copyOutputStreamToIteratee writeEnd

        let options' = options
                    { WS.connectionOnPong = do
                            tickle (max 30)
                            WS.connectionOnPong options
                    }

            pc = WS.PendingConnection
                    { WS.pendingOptions = options'
                    , WS.pendingRequest = fromSnapRequest rq
                    , WS.pendingIn      = is
                    , WS.pendingOut     = os
                    }

        -- TODO: Spawn a ping thread on server accept
        _ <- lift $ forkIO $ app pc >> throwTo thisThread ServerAppDone
        copyIterateeToMVar mvar


--------------------------------------------------------------------------------
-- | Convert a snap request to a websockets request
fromSnapRequest :: Snap.Request -> WS.RequestHead
fromSnapRequest rq = WS.RequestHead
    { WS.requestPath    = Snap.rqURI rq
    , WS.requestHeaders = Headers.toList (Snap.rqHeaders rq)
    , WS.requestSecure  = Snap.rqIsSecure rq
    }
