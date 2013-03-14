-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           BasicPrelude                 hiding (concat)
import           Prelude                      ()
import qualified Prelude

import           Control.Concurrent           (forkIO, newMVar, threadDelay)

import           Data.ByteString              (concat)

import           Data.Map                     (singleton)
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

import           Radio.Data
import           Radio.Internal               (DataApi (..))
import           Radio.Web                    (web)


main::IO ()
main = do
    host <- getHostName
    stations <- makeRadioStation $ Just (host, 2000)
    forkIO $ web stations
    sock <- socket AF_INET Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (SockAddrInet (toEnum port) 0)
    listen sock 100
    forever $ do
        (accepted, _) <- accept sock
        connected <- socketToStreams accepted
        forkIO $ connectHandler connected stations >> sClose accepted
    sClose sock
    return ()



makeRadioStation ::HostPort -> IO Radio
makeRadioStation hp = do
    inf <- newMVar $ big hp
    r <- newMVar $ singleton (RadioId "/big") inf
    return $ Radio r hp

big::HostPort -> RadioInfo
big = RI (RadioId "/big") (Url "http://radio.bigblueswing.com:8002") Nothing [] Nothing Nothing

showType :: SomeException -> String
showType = Prelude.show . typeOf

connectHandler::(InputStream ByteString, OutputStream ByteString) -> Radio -> IO ()
connectHandler (inputS, outputS) radio = do
    sized <- S.throwIfProducesMoreThan 2048 inputS
    result <- try $ S.parseFromStream request sized ::IO (Either SomeException (Request, Headers))
    either badRequest goodRequest result
    where
        badRequest s | showType s == "TooManyBytesReadException" = S.write (Just "ICY 414 Request-URI Too Long\r\n") outputS
                     | otherwise                                = S.write (Just "ICY 400 Bad Request\r\n") outputS

        goodRequest (request', headers') = do
            idInBase <- (RadioId $ requestUri request') `member` radio
            if idInBase
               then do
                   !chan <- chanG radio (RadioId $ requestUri request')
                   threadDelay 1000000
                   print request'
                   print headers'
                   start <- S.fromByteString successRespo
                   input <- S.chanToInput (fromJust chan)
                   S.supply start outputS
                   S.connect input outputS
                   return ()
               else do
                   -- | unknown radio id
                   print request'
                   print headers'
                   S.write (Just "ICY 404 Not Found\r\n") outputS

testUrl :: ByteString
testUrl = "http://bigblueswing.com:2002"

testUrl1 :: ByteString
testUrl1 = "http://bigblueswing.com"

testUrl2 :: ByteString
testUrl2 = "http://bigblueswing.com:2002/asdf"

testUrl3 ::ByteString
testUrl3 = "http://bigblueswing.com/asdf"

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


