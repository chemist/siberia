-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main (
main
) where

import           BasicPrelude                 hiding (FilePath, appendFile,
                                               concat, length, splitAt)
import qualified Prelude

import           Control.Concurrent           (ThreadId, forkIO, killThread,
                                               myThreadId, newMVar, threadDelay)
import           Control.Concurrent.Chan      (dupChan, getChanContents)

import           Data.ByteString              (concat, length)

import qualified Data.Map                     as Map

import           Network.BSD                  (getHostName)
import           Network.Socket               (Family (AF_INET),
                                               SockAddr (SockAddrInet), Socket,
                                               SocketOption (ReuseAddr),
                                               SocketType (Stream), accept,
                                               bindSocket, defaultProtocol,
                                               listen, sClose, setSocketOption,
                                               socket)
import           System.IO.Streams            as S
import           System.IO.Streams.Attoparsec as S
import           System.IO.Streams.Concurrent as S

import           Data.Attoparsec.RFC2616      (Request (..), request)

import           Control.Monad.Reader
import qualified Control.Monad.State          as ST
import qualified Data.Collections             as Collections
import           Data.Text.IO                 (appendFile)
import           Paths_siberia
import           Siberia.Internal
import           Siberia.Web                  (web)
import           Snap.Http.Server             (quickHttpServe)
import           System.Directory


import           Control.Concurrent.MVar
import qualified Data.ByteString.Char8        as C
import           Data.IORef
import qualified Network.Socket.ByteString    as N
import           System.Mem
import           Blaze.ByteString.Builder                 (Builder)
import qualified Blaze.ByteString.Builder                 as Builder
import           Blaze.ByteString.Builder.Internal.Buffer (allNewBuffersStrategy)
import qualified Blaze.ByteString.Builder  as B (fromByteString)


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
    {-
    forkIO $ forever $ do
        -- start garbage collector every 30 s
        -- for test
        -- @TODO hello
        performGC
        threadDelay 30000000
        -}
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
        forkIO $ runReaderT (shoutHandler connected app  `finally`  (liftIO $ (say "close accepted" >> sClose accepted))) stateR
    sClose sock
    return ()
    
data SRequest = SRequest 
  { headers :: Headers
  , request' :: Request
  , radio   :: Radio
  }           | BadRequest Int ByteString
  deriving (Show, Eq) 
  
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

type SResponse = InputStream Builder 

type ShoutCast = SRequest -> Application SResponse

buffSize = 32768

shoutHandler :: (InputStream ByteString, OutputStream ByteString) -> ShoutCast -> Application ()
shoutHandler (is, os) app = do
    input <- app =<< (liftIO . parseRequest $ is)
    builder <- liftIO $ S.builderStreamWith (allNewBuffersStrategy buffSize) os
    liftIO $ S.connect input builder
    
app :: ShoutCast
app (BadRequest _ mes) = liftIO $ S.map B.fromByteString =<< S.fromByteString mes
app sRequest = appIf =<< (member $ radio sRequest)
    where 
    appIf False = liftIO $ S.map B.fromByteString =<< S.fromByteString "ICY 404 Not Found\r\n"
    appIf True  = client sRequest

client :: ShoutCast
client SRequest{..} = do
    let wait :: Int -> Application ()
        wait i 
          | i < 3 = do
              chan <- getD radio :: Application Channel
              case chan of
                   Just _ -> return ()
                   Nothing -> makeChannel radio >> (liftIO $ threadDelay 1000000) >> wait (i + 1)
          | otherwise = return ()
    wait 0
    chan' <- getD radio :: Application Channel 
    maybe chanError chanGood chan'
    where
    chanError = liftIO $ S.map B.fromByteString =<< S.fromByteString "ICY 423 Locked\r\n"
    chanGood chan'' = do
        pid <- liftIO $ myThreadId
        saveClientPid pid radio
        Just buf' <- getD radio :: Application (Maybe (Buffer ByteString))
        duplicate <- liftIO $ dupChan chan''
        okResponse <- liftIO $ S.map B.fromByteString =<< S.fromByteString successRespo
        (input, countOut) <- liftIO $ S.countInput =<< S.chanToInput duplicate
        countIn <- getD radio :: Application (IO Int64)
        catchSlowClient <- liftIO $ forkIO $ do
            -- @TODO must be killed
            start <- newIORef =<< countIn
            forever $ do
                s <- readIORef start
                cI <- countIn
                cO <- countOut
                when (((cI -s) -cO) > 300000) $ do
                    say $ "slow client detected " ++ show pid ++ " diff " ++ (show ((cI -s) -cO))
                    killThread pid
                    liftIO $! getChanContents duplicate
                    return ()
                threadDelay 5000000
        birst <- liftIO $ getAll buf'
        birst' <- liftIO $ S.fromByteString birst
        getMeta <- return <$> getD radio :: Application (IO (Maybe Meta))
        withMeta <- liftIO $ insertMeta (Just 8192) getMeta =<<  S.concatInputStreams [birst', input]
        liftIO $ S.concatInputStreams [okResponse, withMeta]
        
        
                    
makeClient :: OutputStream ByteString -> Radio -> Application ()
makeClient oS radio = do
    let wait :: Int -> Application ()
        wait i
          | i < 3 = do
              chan <- getD radio :: Application Channel
              case chan of
                 Just _ -> return ()
                 Nothing -> do
                     makeChannel radio
                     liftIO $ threadDelay 1000000
                     wait (i + 1)
          | otherwise = return ()
    wait 0
    chan' <- getD radio :: Application Channel
    pid <- liftIO $ myThreadId
    saveClientPid pid radio
    case chan' of
         Just chan'' -> do
             Just buf' <- getD radio :: Application (Maybe (Buffer ByteString))
             duplicate <- liftIO $ dupChan chan''
             start <- liftIO $ S.fromByteString successRespo
             (input, countOut) <- liftIO $ S.countInput =<< S.chanToInput duplicate
             countIn <- getD radio :: Application (IO Int64)
             catchSlowClient <- liftIO $ forkIO $ do
                 start <- newIORef =<<  countIn
                 forever $ do
                     s <- readIORef start
                     cI <- countIn
                     cO <- countOut
                     when (((cI - s) - cO) > 300000) $ do
                         say $ "slow client detected " ++ show pid ++ " diff " ++ (show ((cI - s) - cO))
                         killThread pid
                         !_ <- liftIO $! getChanContents duplicate
                         return ()
                     threadDelay 5000000
             birst <- liftIO $ getAll buf'
             say $ show $ "from birst" ++ (Prelude.show $ length birst)
             birst' <- liftIO $ S.fromByteString birst
             withoutMeta <- liftIO $ S.concatInputStreams [ birst', input ]
             getMeta <- return <$> getD radio :: Application (IO (Maybe Meta))
             say "supply start"
             liftIO $ S.supply start oS
             say "supply end"
             fin <- liftIO $ try $ connectWithAddMetaAndBuffering (Just 8192) getMeta 32752 withoutMeta oS  :: Application (Either SomeException ())
             either whenError whenGood fin
             say "make finally work"
             liftIO $ killThread catchSlowClient >> say "kill catchSlowClient"
             return ()
         Nothing -> liftIO $ S.write (Just "ICY 423 Locked\r\n") oS
    removeClientPid pid radio
    where
      whenError s = say $ "catched: " ++ show s
      whenGood _ = return ()

successRespo :: ByteString
successRespo = concat [ "ICY 200 OK\r\n"
                      , "icy-notice1: Siberia shoutcast server\r\n"
                      , "icy-notice2: Good music here\r\n"
                      , "content-type: audio/mpeg\r\n"
                      , "icy-name: Good music for avery one \r\n"
                      , "icy-url: http://localhost:2000/big \r\n"
                      , "icy-genre: Swing  Big Band  Jazz  Blues\r\n"
                      , "icy-pub: 1\r\n"
                      , "icy-metaint: 8192\n"
                      , "icy-br: 128\r\n\r\n"
                      ]


connectHandler::(InputStream ByteString, OutputStream ByteString) -> Application ()
connectHandler (iS, oS) = do
    -- если запрос сильно большой кидаем исключение
    sized <- liftIO $ S.throwIfProducesMoreThan 2048 iS
    -- пробуем парсить запрос
    result <- try $ liftIO $ S.parseFromStream request sized :: Application (Either SomeException (Request, Headers))
    either whenError whenGood result

    where

    whenError s
      | showType s == "TooManyBytesReadException" = liftIO $ S.write (Just "ICY 414 Request-URI Too Long\r\n") oS
      | otherwise                                = liftIO $ S.write (Just "ICY 400 Bad Request\r\n") oS

    whenGood (request', headers') = do
        let channel' = ById (RadioId $ requestUri request')
        is <- member channel'
        if is
          then do
             say "make connection"
             say $ show request'
             say $ show headers'
             makeClient oS channel'
          else do
           --  unknown rid
             say $ show request'
             say $ show headers'
             liftIO $ S.write (Just "ICY 404 Not Found\r\n") oS

    showType :: SomeException -> String
    showType = Prelude.show . typeOf


