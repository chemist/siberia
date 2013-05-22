-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE OverloadedStrings #-}

module Main where

import           BasicPrelude                 hiding (FilePath, appendFile,
                                               concat, length, splitAt)
import qualified Prelude

import           Control.Concurrent           (forkIO, myThreadId, newMVar,
                                               threadDelay)
import           Control.Concurrent.Chan      (dupChan)

import           Data.ByteString              (concat, length)

import qualified Data.Map                     as Map

import           Network.BSD                  (getHostName)
import           Network.Socket               (Family (AF_INET),
                                               SockAddr (SockAddrInet),
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
import qualified Data.Collections             as Collections
import           Data.Text.IO                 (appendFile)
import           Paths_siberia
import           Radio.Internal
import           Radio.Web                    (web)
import           Snap.Http.Server             (quickHttpServe)
import           System.Directory


musicFolder :: String
musicFolder = "/music/"

emptyStateR::IO RadioStore
emptyStateR = do
    host <- getHostName
    a <- newMVar Map.empty
    return $ Store a (Just (host, 2000)) 


main::IO ()
main = do
    dataDir <- getDataDir
--     mainId <- myThreadId
    createDirectoryIfMissing True $ dataDir <> "/log"
    stateR <- emptyStateR
    -- | start web application
    void . forkIO $ quickHttpServe $ void $ runWeb web stateR 
    try $ runReaderT (load $ dataDir <> "/radiobase") stateR  :: IO (Either SomeException ())
    -- | open socket
    sock <- socket AF_INET Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (SockAddrInet (toEnum port) 0)
    listen sock 100
    -- | allways accept connection
    void . forever $ do
        (accepted, _) <- accept sock
        connected <- socketToStreams accepted
        forkIO $ runReaderT (connectHandler connected  `finally`  (liftIO $ sClose accepted)) stateR 
    sClose sock
    return ()


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
           -- | unknown rid
             say $ show request'
             say $ show headers'
             liftIO $ S.write (Just "ICY 404 Not Found\r\n") oS

    showType :: SomeException -> String
    showType = Prelude.show . typeOf

makeClient :: OutputStream ByteString -> Radio -> Application ()
makeClient oS radio = do
    chan <- getD radio :: Application Channel
    when (isNothing chan) $ do
        makeChannel radio
        liftIO $ threadDelay 1000000
    chan' <- getD radio :: Application Channel
    case chan' of
         Just chan'' -> do
             Just buf' <- getD radio :: Application (Maybe (Buffer ByteString))
             duplicate <- liftIO $ dupChan chan''
             start <- liftIO $ S.fromByteString successRespo
             input <- liftIO $ S.chanToInput duplicate
             birst <- liftIO $ getAll buf'
             say $ show $ "from birst" ++ (Prelude.show $ length birst)
             birst' <- liftIO $ S.fromByteString birst
             withoutMeta <- liftIO $ S.concatInputStreams [ birst', input ]
             getMeta <- return <$> getD radio :: Application (IO (Maybe Meta))
             say "supply start"
             liftIO $ S.supply start oS
             say "supply end"
             fin <- liftIO $ try $ connectWithAddMetaAndBuffering (Just 8192) getMeta 4096 withoutMeta oS  :: Application (Either SomeException ())
             either whenError whenGood fin
             say "make finally work"
         Nothing -> liftIO $ S.write (Just "ICY 423 Locked\r\n") oS
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


-- big = RI (RadioId "/big") (Url "http://radio.bigblueswing.com:8002") Nothing [] Nothing Nothing

testUrl :: ByteString
testUrl = "http://bigblueswing.com:2002"

testUrl1 :: ByteString
testUrl1 = "http://bigblueswing.com"

testUrl2 :: ByteString
testUrl2 = "http://bigblueswing.com:2002/asdf"

testUrl3 ::ByteString
testUrl3 = "http://bigblueswing.com/asdf"

testreq :: ByteString
testreq = concat [ "HTTP/1.0 200 OK\r\n"
                 , "Content-Type:audio/mpeg\r\n"
                 , "icy-br:128\r\n"
                 , "icy-description:UNC Charlotte's Radio Station\r\n"
                 , "icy-genre:College Progressive\r\n"
                 , "icy-name:Radio Free Charlotte\r\n"
                 , "icy-pub:1\r\n"
                 , "icy-url:http://rfclive.uncc.edu:8000/listen.m3u\r\n"
                 , "Server:Icecast 2.3.2\r\n"
                 , "Cache-Control: no-cache\r\n\r\n"
                 ]


