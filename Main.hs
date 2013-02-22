{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
module Main where

import Prelude (not, (++), String, Bool(..), (<), lookup, (-), Bool, show, snd, undefined, id, Show, otherwise, Int, ($), (>), (+), fst, (.), (*), (==), (/=), fromIntegral)
import Control.Monad
import Control.Monad.State
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import Control.Applicative ((<$>), liftA, (<*>))
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMChan
import System.IO (FilePath, hClose, print, IO, openBinaryFile, hClose, IOMode(..))
import Control.Exception (bracket)

import Data.Conduit
import Data.Conduit.Network
import Data.Conduit.TMChan
import Data.Conduit.List hiding (head, take, drop)
import qualified Data.Conduit.List as CL
import Data.Conduit.Binary (sourceLbs, head, take, takeWhile, lines)
import qualified Data.Conduit.Binary as CB
import Data.Conduit.Util 
import qualified Network.HTTP.Conduit as HTTP

import Data.ByteString (breakSubstring, length, split, dropWhile, spanEnd, ByteString, putStr, concat, last, init, null, breakByte, drop)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LB
import Data.Maybe
import Data.Word
import Data.Map (Map)
import qualified Data.Map as Map
import Debug.Trace
import qualified Data.ByteString.Char8 as C

type Buffer = TBMChan ByteString
type Channel = TMChan ByteString
type Clients = TMVar Int

type BC = (Buffer, Channel, Clients)

type Header = (ByteString, ByteString)

data RadioStream = Meta ByteString
                 | Headers [Header]
                 | Stream ByteString 
                 deriving (Show)
                 
                 
type Radio = ByteString
type RadioUrl = ByteString
                 
data ChannelInfo = ChannelInfo { radio::Radio
                               , url  ::RadioUrl
                               , buffer:: Buffer
                               , channel:: Channel
                               , clientPid:: Maybe ThreadId
                               , clients:: Int 
                               , connection :: Bool
                               , headers::Maybe RadioStream
                               , meta::Maybe RadioStream
                               }

type RadioState = MVar (Map Radio (MVar ChannelInfo))

type Port = Int

data Server = Server { port::Port
                     , radioState::RadioState
                     }

type ServerState = StateT Server IO


initServer::IO Server
initServer = do
    m <- newMVar Map.empty
    return $ Server 2000 m
    
main::IO ()
main = do
    serv <- initServer
    (_, s)  <- runStateT (addRadio "/bigblue" "http://radio.bigblueswing.com:8002") serv
    (_, s') <- runStateT (addRadio "/ah" "http://ru.ah.fm:80") s
    runResourceT $ runTCPServer (serverSettings (port s') "*4") $ server s'
    return ()
    
addRadio::Radio -> RadioUrl -> ServerState ()
addRadio radio url = do
    buffer <- liftIO $ newTBMChanIO 1000
    channel <- liftIO $ buff buffer
    Server{..} <- get
    info <- liftIO $ newMVar $ ChannelInfo radio url buffer channel Nothing 0 False Nothing Nothing
    let fun stMap = return $ Map.insert radio info stMap 
    liftIO $ modifyMVar_ radioState fun
     
buff::Buffer -> IO (TMChan ByteString)
buff buffer = do
    chan <- newTMChanIO
    forkIO $ copy buffer chan
    forkIO $ forever $ void . atomically $ readTMChan chan
    return chan
    
copy::TBMChan ByteString -> TMChan ByteString -> IO ()
copy buffer chan = forever $ do
    free <- atomically $ freeSlotsTBMChan buffer
    when (free > 100) $ atomically $ do
        slot <- readTBMChan buffer
        case slot of
             Just a -> writeTMChan chan a
             Nothing -> return ()
    
server::(Monad m, MonadResource m) => Server -> Application m
server st ad = do
    ((request,_):headers) <- appSource ad $$ parseHeaders id
    let radio = parseRequest request
    liftIO $ print "request"
    liftIO $ print radio
    isChannel <-  liftIO $ haveChannel radio $ radioState st
    connection <-  liftIO $ haveConnection isChannel radio $ radioState st
    liftIO $ print "headers"
    liftIO $ print headers
    liftIO $ print $ "is channel " ++ show isChannel ++ " is first " ++ show connection
    case (isChannel, connection) of
         (False, _) -> sourceList ["ICY 404 OK\r\n"] $$ appSink ad
         (True, False) -> do
             channelMVar <- liftIO $ getChannelMVar radio $ radioState st
             liftIO $ void . forkIO $ runResourceT $ startClientForServer channelMVar 
             startClient channelMVar (appSource ad) (appSink ad)
         (True, True) -> do
             channelMVar <- liftIO $ getChannelMVar radio $ radioState st
             startClient channelMVar (appSource ad) (appSink ad)
    return ()
        
-- | Когда подключается первый клиент к радиостанции, льем поток в трубу
startClientForServer :: MVar ChannelInfo ->  ResourceT IO ()
startClientForServer channelMVar = do
    url' <- liftIO $ url <$> readMVar channelMVar
    request <- HTTP.parseUrl $ C.unpack url'
    let port = HTTP.port request
        host = HTTP.host request
        path = HTTP.path request
        settings = clientSettings port host
-- | стартуем клиента до этого радио
    runTCPClient settings $ clientForServer channelMVar path
    return ()

clientForServer :: MVar ChannelInfo -> ByteString -> Application (ResourceT IO)
clientForServer mv path ad = do
    liftIO $ print "start client for server"
    let request = BS.concat ["GET ", path, " HTTP/1.1\r\nIcy-MetaData: 1\r\n\r\n"]
    sourceList [request] $$ appSink ad
    (l,((state,_):headers)) <- appSource ad $$  zipSinks getLength $ parseHeaders id
    liftIO $ print "client"
    liftIO $ print l
    liftIO $ print state
    liftIO $ print headers
    let metaInt = fromMaybe 0 $ do m <- lookup "icy-metaint" headers
                                   (i, _) <- C.readInt m
                                   return i
    meta' <- appSource ad $$ parseMeta metaInt l
    liftIO $ print meta'
    buffer' <- liftIO $ getBuffer mv
    liftIO $ setConnection mv
    liftIO $ print "make pipe server => buffer"
    appSource ad $$ sinkTBMChan buffer'
    

------------------------ client only --------------------------------------------------
 
startClient::(Monad m, MonadIO m) => MVar ChannelInfo -> Source m ByteString -> Sink ByteString m () -> m ()
startClient channelMVar sourceI sinkI = do
    let response = concat [ "ICY 200 OK\r\n"
                          , "icy-notice1: Haskell shoucast splitter\r\n"
                          , "icy-notice2: Good music here\r\n"
                          , "content-type:audio/mp3\r\n"
                          , "icy-pub:1\r\n"
                          , "icy-metaint:8192\r\n"
                          , "icy-br:64\r\n\r\n"
                          ]
    sourceList [response] $$ sinkI
    channel <- liftIO $ channel <$> readMVar channelMVar
    dup <- liftIO $ atomically $ dupTMChan channel
    sourceTMChan dup $$ sinkI
   
--------------------------------- internal ---------------------------------------------
-- | проверяем наличие канала
haveChannel::Radio -> RadioState -> IO Bool
haveChannel radio radioState = withMVar radioState (fun radio)
   where fun key rMap = return $ Map.member key rMap 
         
-- | есть соединение до радиостанции?
haveConnection::Bool -> Radio -> RadioState -> IO Bool
haveConnection isChannel radio' radioState'
              | isChannel == False = return False
              | otherwise = do
   ChannelInfo{..} <- fromJust <$> getChannel radio' radioState'
   return connection
   
setConnection :: MVar ChannelInfo -> IO ()
setConnection mv = modifyMVar_ mv $ \x -> return $ x { connection = True }
        
getBuffer :: MVar ChannelInfo -> IO Buffer
getBuffer mv = do
    ChannelInfo{..} <- readMVar mv
    return buffer
   
getChannel::MonadIO m => Radio -> RadioState -> m (Maybe ChannelInfo)
getChannel radio radioState = liftIO $ withMVar radioState (fun radio)
   where
     fun key rMap = let mChannel = Map.lookup key rMap
                    in  case mChannel of
                            Nothing -> return Nothing
                            Just m -> do
                                result <- liftIO $ readMVar m
                                return $ Just result
                                
getChannelMVar::MonadIO m => Radio -> RadioState -> m (MVar ChannelInfo)
getChannelMVar radio radioState = liftIO $ withMVar radioState (fun radio)
   where fun key rmap = return . fromJust $ Map.lookup key rmap
 
-- | парсим метаданные
parseMeta::(Monad m, MonadIO m) => Int -> Int -> Sink ByteString m LB.ByteString
parseMeta metaInt headerLength = do
    CB.drop (metaInt - headerLength)
    len <- CB.head 
    let len' = 16 * (fromIntegral $ fromJust len)
    CB.take len'
    
-- | размер после запроса
getLength::(Monad m, MonadIO m, MonadResource m) => Sink ByteString m Int
getLength = sinkState 0 (\state input -> do
    let (_,b) = breakSubstring "\r\n\r\n" input
    case (null b, state < 3) of
        (True, True) -> return $ StateProcessing $ state + 1 
        (True, False) -> return $ StateDone Nothing 0  
        (False, _) -> return $ StateDone Nothing $ length b -4)
                        return

charLF = 10
charCR = 13
charSpace = 32
charColon = 58

sinkLine::(MonadIO m,Monad m, MonadResource m) => Sink ByteString m ByteString
sinkLine = do
    bs <- fmap (killCR . concat) $ CB.takeWhile (/= charLF) =$ CL.consume
    CB.drop 1
    return bs
    
killCR::ByteString -> ByteString
killCR bs 
   | null bs = bs
   | last bs == charCR = init bs
   | otherwise = bs
   
parseRequest::ByteString -> Radio
parseRequest line = let (r:url:h) = split charSpace line
                    in url
 
parseHeader::Monad m => ByteString -> Sink ByteString m (ByteString, ByteString)
parseHeader bs = do
    let (key, bs2) = breakByte charColon bs
    return (strip key, strip $ drop 1 bs2)

strip::ByteString -> ByteString
strip = dropWhile (== charSpace) . fst . spanEnd (== charSpace)

    
parseHeaders::(Monad m, MonadIO m, MonadResource m) => ([Header] -> [Header]) -> Sink ByteString m [Header]
parseHeaders front = do
    line <- sinkLine
    if null line
       then return $ front []
       else do
           header <- parseHeader line
           parseHeaders $ front . (header:)
  
  

request::LB.ByteString
request = LB.fromChunks ["GET / HTTP/1.0\r\nUser-Agent: mpg123/1.14.4\r\nHost: radio.bigblueswing.com:8002\r\nAccept: audio/mpeg, audio/x-mpeg, audio/mp3, audio/x-mp3, audio/mpeg3, audio/x-mpeg3, audio/mpg, audio/x-mpg, audio/x-mpegaudio, application/octet-stream, audio/mpegurl, audio/mpeg-url, audio/x-mpegurl, audio/x-scpls, audio/scpls, application/pls, */*\r\nIcy-MetaData: 1\r\n\r\n"]

response::LB.ByteString
response = LB.fromChunks ["ICY 200 OK\r\nicy-notice1:<BR>This stream requires <a href=\"http://www.winamp.com/\">Winamp</a><BR>\r\nicy-notice2:SHOUTcast Distributed Network Audio Server/Linux v1.9.8<BR>\r\n"]

meta' = LB.fromChunks ["ncontent-type:audio/mpeg\r\nicy-pub:1\r\nicy-metaint:8192\r\nicy-br:64\r\n\r\n"]
    
-- http://radio.bigblueswing.com:8002/
    
-- http://ru.ah.fm/
