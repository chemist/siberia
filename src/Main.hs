-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
    
module Main where

import BasicPrelude 
import Prelude ()
import qualified Prelude as Prelude

import Control.Concurrent hiding (yield)

import Data.ByteString (breakSubstring, split, spanEnd, breakByte)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Char8 as C

import Data.Maybe (fromJust)
import qualified Data.Map as Map
import Debug.Trace
import Data.Text (unpack)

import System.IO.Streams as S
import System.IO.Streams.Attoparsec as S
import Network.Socket 

import Data.Word (Word8)
import Control.Applicative
import Data.Attoparsec.RFC2616
import Data.Typeable (typeOf)


    
port :: Int
port = 2000

newtype RadioId = RadioId ByteString deriving (Show, Ord, Eq)
newtype Url = Url ByteString deriving (Show, Ord, Eq)
newtype Meta = Meta (ByteString, Int) deriving (Show, Ord, Eq)
type Headers = [Header]

data RadioInfo = RI { rid :: RadioId
                    , url :: Url
                    , pid :: Maybe ThreadId
                    , headers :: Headers
                    , meta    :: Maybe Meta
                    } deriving (Show, Ord, Eq)

newtype Radio = Radio (MVar (Map RadioId (MVar RadioInfo)))

class SettingsById a where
    member   :: RadioId -> a -> IO Bool
    urlG     :: a -> RadioId -> IO Url
    urlS     :: a -> RadioId -> Url -> IO ()
    pidG     :: a -> RadioId -> IO (Maybe ThreadId)
    pidS     :: a -> RadioId -> Maybe ThreadId -> IO ()
    headersG :: a -> RadioId -> IO Headers
    headersS :: a -> RadioId -> Headers -> IO ()
    metaG    :: a -> RadioId -> IO (Maybe Meta)
    metaS    :: a -> RadioId -> Maybe Meta -> IO ()
    
instance SettingsById Radio where
    member rid (Radio radio) = withMVar radio $ \x -> return $ rid `Map.member` x
    urlG = undefined
    urlS = undefined
    pidG = undefined
    pidS = undefined
    headersG = undefined
    headersS = undefined
    metaG = undefined
    metaS = undefined

main::IO ()
main = do
    stations <- makeRadioStation
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
    
makeRadioStation ::IO Radio
makeRadioStation = do
    info <- newMVar big
    r <- newMVar $ Map.singleton (RadioId "/big") info
    return $ Radio r

big::RadioInfo
big = RI (RadioId "/big") (Url "http://radio.bigblueswing.com:8002") Nothing [] Nothing

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
                     
        goodRequest (request', headers) = do
            idInBase <- (RadioId $ requestUri request') `member` radio
            if idInBase 
               then do
                   start <- S.fromByteString successRespo
                   let fun file = do
                       S.supply start outputS
                       S.connect file outputS
                   S.withFileAsInput "music.mp3" fun
                   
               else do
                   -- | unknown radio id
                   print request'
                   print headers
                   S.write (Just "ICY 404 Not Found\r\n") outputS
    

successRespo :: ByteString
successRespo = BS.concat [ "ICY 200 OK\r\n"
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


