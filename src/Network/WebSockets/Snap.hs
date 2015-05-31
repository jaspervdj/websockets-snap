--------------------------------------------------------------------------------
-- | Snap integration for the WebSockets library
{-# LANGUAGE DeriveDataTypeable #-}
module Network.WebSockets.Snap
    ( runWebSocketsSnap
    , runWebSocketsSnapWith
    ) where


--------------------------------------------------------------------------------
import           Control.Concurrent            (forkIO, myThreadId, threadDelay)
import           Control.Concurrent.MVar       (MVar, newEmptyMVar, putMVar,
                                                takeMVar)
import           Control.Exception             (Exception (..),
                                                SomeException (..), finally,
                                                handle, throwIO, throwTo)
import           Control.Monad                 (forever)
import           Control.Monad.Trans           (lift)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString.Char8         as BC
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Enumerator               as E
import qualified Data.Enumerator.List          as EL
import           Data.IORef                    (newIORef, readIORef, writeIORef)
import           Data.Typeable                 (Typeable, cast)
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Connection as WS
import qualified Network.WebSockets.Stream     as WS
import qualified Snap.Core                     as Snap
import qualified Snap.Internal.Http.Types      as Snap
import qualified Snap.Types.Headers            as Headers


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
copyIterateeToMVar
    :: ((Int -> Int) -> IO ())
    -> MVar Chunk
    -> E.Iteratee ByteString IO ()
copyIterateeToMVar tickle mvar = E.catchError go handler
  where
    go = do
        mbs <- EL.head
        case mbs of
            Just x  -> do
                lift (tickle (max 60))
                lift (putMVar mvar (Chunk x))
                go
            Nothing -> lift (putMVar mvar Eof)

    handler se@(SomeException e) = case cast e of
        -- Clean exit
        Just ServerAppDone -> return ()
        -- Actual error
        Nothing            -> lift $ putMVar mvar $ Error se


--------------------------------------------------------------------------------
copyMVarToStream :: MVar Chunk -> IO (IO (Maybe ByteString))
copyMVarToStream mvar = return go
  where
    go = do
        chunk <- takeMVar mvar
        case chunk of
            Chunk x                 -> return (Just x)
            Eof                     -> return Nothing
            Error (SomeException e) -> throwIO e


--------------------------------------------------------------------------------
copyStreamToIteratee
    :: E.Iteratee ByteString IO ()
    -> IO (Maybe BL.ByteString -> IO ())
copyStreamToIteratee iteratee0 = do
    ref <- newIORef =<< E.runIteratee iteratee0
    return (go ref)
  where
    go _   Nothing   = return ()
    go ref (Just bl) = do
        step <- readIORef ref
        case step of
            E.Continue f              -> do
                let chunks = BL.toChunks bl
                step' <- E.runIteratee $ f $ E.Chunks chunks
                writeIORef ref step'
            E.Yield () _              -> throwIO WS.ConnectionClosed
            E.Error (SomeException e) -> throwIO e


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
    Snap.escapeHttp $ \tickle writeEnd -> do

        thisThread <- lift myThreadId
        mvar       <- lift newEmptyMVar
        parse      <- lift $ copyMVarToStream mvar
        write      <- lift $ copyStreamToIteratee writeEnd
        stream     <- lift $ WS.makeStream parse write

        let options' = options
                    { WS.connectionOnPong = do
                            tickle (max 60)
                            WS.connectionOnPong options
                    }

            pc = WS.PendingConnection
                    { WS.pendingOptions  = options'
                    , WS.pendingRequest  = fromSnapRequest rq
                    , WS.pendingOnAccept = forkPingThread tickle
                    , WS.pendingStream   = stream
                    }

        _ <- lift $ forkIO $ finally (app pc) $ do
            WS.close stream
            throwTo thisThread ServerAppDone
        copyIterateeToMVar tickle mvar


--------------------------------------------------------------------------------
-- | Start a ping thread in the background
forkPingThread :: ((Int -> Int) -> IO ()) -> WS.Connection -> IO ()
forkPingThread tickle conn = do
    _ <- forkIO pingThread
    return ()
  where
    pingThread = handle ignore $ forever $ do
        WS.sendPing conn (BC.pack "ping")
        tickle (min 15)
        threadDelay $ 30 * 1000 * 1000

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
