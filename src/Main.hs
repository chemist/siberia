-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           BasicPrelude                 hiding (concat)
import qualified Prelude

import           Control.Concurrent           (forkIO, newMVar, threadDelay)

import           Data.ByteString              (concat)

import           Data.Map                     (singleton, empty)
import qualified Data.Map  as Map
import           Data.Maybe                   (fromJust)

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

import Control.Monad.Reader
import           Radio.Data
import           Radio.Internal
import           Radio.Web                    (web)
import           Snap.Http.Server    (quickHttpServe)


main::IO ()
main = do
    state <- emptyState
    -- | start web application
    forkIO $ quickHttpServe $ runWeb web state
    -- | open socket 
    sock <- socket AF_INET Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (SockAddrInet (toEnum port) 0)
    listen sock 100
    -- | allways accept connection
    forever $ do
        (accepted, _) <- accept sock
        connected <- socketToStreams accepted
        forkIO $ runReaderT (connectHandler connected  `finally`  (liftIO $ sClose accepted)) state
    sClose sock
    return ()
    
connectHandler::(InputStream ByteString, OutputStream ByteString) -> Application ()
connectHandler (iS, oS) = do
    sized <- liftIO $ S.throwIfProducesMoreThan 2048 iS
    result <- try $ liftIO $ S.parseFromStream request sized :: Application (Either SomeException (Request, Headers))
    either whenError whenGood result
    
    where
    whenError s 
      | showType s == "TooManyBytesReadException" = liftIO $ S.write (Just "ICY 414 Request-URI Too Long\r\n") oS
      | otherwise                                = liftIO $ S.write (Just "ICY 400 Bad Request\r\n") oS
    whenGood (request, headers) = do
        let channel = ById (RadioId $ requestUri request)
        is <- member $ channel
        if is
        then do
          liftIO $ print "make connection"
          liftIO $ print request
          liftIO $ print headers
          makeClient oS channel
        else do
           -- | unknown rid
          liftIO $ print request
          liftIO $ print headers
          liftIO $ S.write (Just "ICY 404 Not Found\r\n") oS
          
    showType :: SomeException -> String
    showType = Prelude.show . typeOf

makeClient :: OutputStream ByteString -> Radio -> Application ()
makeClient oS radio = do
    makeChannel radio
    liftIO $ threadDelay 1000000
    chan <- get radio :: Application Channel
    case chan of
         Just chan' -> do
             start <- liftIO $ S.fromByteString successRespo
             input <- liftIO $ S.chanToInput chan'
             liftIO $ S.supply start oS
             liftIO $ S.connect input oS
         Nothing -> liftIO $ S.write (Just "ICY 423 Locked\r\n") oS
    
emptyState::IO RadioStore
emptyState = do
    host <- getHostName
    a <- newMVar Map.empty
    return $ Store a (Just (host, 2000))
    
successRespo :: ByteString
successRespo = concat [ "ICY 200 OK\r\n"
                      , "icy-notice1: Haskell shoucast splitter\r\n"
                      , "icy-notice2: Good music here\r\n"
                      , "content-type: audio/mpeg\r\n"
                      , "icy-name: Good music for avery one \r\n"
                      , "icy-url: http://localhost:2000/big \r\n"
                      , "icy-genre: Swing  Big Band  Jazz  Blues\r\n"
                      , "icy-pub: 1\r\n"
                      , "icy-metaint: 0\n"
                      , "icy-br: 64\r\n\r\n"
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


