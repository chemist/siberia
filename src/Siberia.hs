-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main ( main
) where

import           BasicPrelude                             hiding (FilePath,
                                                           appendFile, concat,
                                                           length, splitAt)
import qualified Prelude

import           Control.Concurrent                       (ThreadId, forkIO,
                                                           killThread,
                                                           myThreadId, newMVar,
                                                           threadDelay)
import           Control.Concurrent.Chan                  (dupChan,
                                                           getChanContents)

import           Data.ByteString                          (concat, length)

import qualified Data.Map                                 as Map

import           Network.BSD                              (getHostName)
import           Network.Socket                           (Family (AF_INET), SockAddr (SockAddrInet),
                                                           Socket, SocketOption (ReuseAddr),
                                                           SocketType (Stream),
                                                           accept, bindSocket,
                                                           defaultProtocol,
                                                           listen, sClose,
                                                           setSocketOption,
                                                           socket)
import           System.IO.Streams                        as S
import           System.IO.Streams.Attoparsec             as S
import           System.IO.Streams.Concurrent             as S

import           Data.Attoparsec.RFC2616                  (Request (..),
                                                           request)

import           Control.Monad.Reader
import qualified Control.Monad.State                      as ST
import qualified Data.Collections                         as Collections
import           Data.Text.IO                             (appendFile)
import           Paths_siberia
import           Siberia.Internal
import           Siberia.Web                              (web)
import           Snap.Http.Server                         (quickHttpServe)
import           System.Directory


import           Blaze.ByteString.Builder                 (Builder)
import qualified Blaze.ByteString.Builder                 as Builder
import qualified Blaze.ByteString.Builder                 as B (fromByteString)
import           Blaze.ByteString.Builder.Internal.Buffer (allNewBuffersStrategy)
import           Control.Concurrent.MVar
import qualified Data.ByteString.Char8                    as C
import           Data.IORef
import qualified Network.Socket.ByteString                as N
import           System.Mem


-- | const directory with music files
musicFolder :: String
musicFolder = "/music/"

-- | empty state
emptyStateR::IO Store
emptyStateR = do
    host <- getHostName
    a <- newMVar Map.empty
    return $ Store a (Just (host, 2000))

-- | start server
main::IO ()
main = do
    dataDir <- getDataDir
--     mainId <- myThreadId
    createDirectoryIfMissing True $ dataDir <> "/log"
    stateR <- emptyStateR
    --  start web application
    void . forkIO $ quickHttpServe $ void $ runWeb web stateR
    try $ runReaderT (load $ dataDir <> "/radiobase") stateR  :: IO (Either SomeException ())
    --  open socket
    sock <- socket AF_INET Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (SockAddrInet (toEnum port) 0)
    listen sock 10000
    --  allways accept connection
    void . forever $ do
        (accepted, _) <- accept sock
        connected <- socketToStreams accepted
        forkIO $ do
            pid <- myThreadId
            rmv <- newEmptyMVar
            let cleanAll = do
                liftIO $ say "close accepted"
                liftIO $ sClose accepted
                sreq <- liftIO $ readMVar rmv
                case sreq of
                     BadRequest{} -> return ()
                     SRequest{..} -> removeClientPid pid radio
            runReaderT (shoutHandler connected app rmv `finally`  cleanAll) stateR
    sClose sock
    return ()

shoutHandler :: (InputStream ByteString, OutputStream ByteString) -> ShoutCast -> MVar SRequest -> Application ()
shoutHandler (is, os) app rmv = do
    input <- app =<< (\x -> (liftIO $ putMVar rmv x) >> return x) =<< (liftIO . parseRequest $ is)
    builder <- liftIO $ S.builderStreamWith (allNewBuffersStrategy buffSize) os
    liftIO $ S.connect input builder

buffSize = 32768

parseRequest :: InputStream ByteString -> IO SRequest
parseRequest is = do
    sized <- S.throwIfProducesMoreThan 2048 is
    result <- try $ S.parseFromStream request sized :: IO (Either SomeException (Request, Headers))
    return $ either pError good result
    where
    showType :: SomeException -> String
    showType = Prelude.show . typeOf
    pError s
       | showType s == "TooManyBytesReadException" = BadRequest 414 "ICY 414 Request-URI Too Long\r\n"
       | otherwise                                = BadRequest 400 "ICY 400 Bad Request\r\n"
    good (req, h) = SRequest h req (ById (RadioId $ requestUri req))

app :: ShoutCast
app (BadRequest _ mes) = liftIO $ S.map B.fromByteString =<< S.fromByteString mes
app sRequest = appIf =<< (member $ radio sRequest)
    where
    appIf False = liftIO $ S.map B.fromByteString =<< S.fromByteString "ICY 404 Not Found\r\n"
    appIf True  = client sRequest


