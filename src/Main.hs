-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
    
module Main where

import Prelude ()
import BasicPrelude

import Control.Monad.State 
import Control.Monad.Trans.Resource
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMChan

import Data.Conduit
import Data.Conduit.Network
import Data.Conduit.TMChan
import Data.Conduit.List hiding (head, take, drop)
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Binary as CB
import Data.Conduit.Util 
import qualified Network.HTTP.Conduit as HTTP

import Data.ByteString (breakSubstring, split, spanEnd, breakByte)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Char8 as C

import Data.Maybe (fromJust)
import qualified Data.Map as Map
import Debug.Trace

--------------------------------------- Types ---------------------------------------------------
    
type Buffer = TBMChan ByteString
type Channel = TMChan ByteString
type Clients = TMVar Int

type Headers = [(ByteString, ByteString)]
type Meta = ByteString
type Radio = ByteString
type RadioUrl = ByteString
                 
data ChannelInfo = ChannelInfo { radio::Radio
                               , url  ::RadioUrl
                               , buffer:: Buffer
                               , channel:: Channel
                               , clientPid:: Maybe ThreadId
                               , clients:: Int 
                               , connection :: Bool
                               , headers::Headers
                               , meta::Maybe Meta
                               }

type RadioState = MVar (Map Radio (MVar ChannelInfo))

type Port = Int

data Server = Server { port::Port
                     , radioState::RadioState
                     }

type ServerState = StateT Server IO

---------------------------------------- Main --------------------------------------------------
   
main::IO ()
main = do
    m <- newMVar Map.empty
    (_, s)  <- runStateT (addRadio "/bigblue" "http://radio.bigblueswing.com:8002") $ Server 2000 m
    (_, s') <- runStateT (addRadio "/ah" "http://ru.ah.fm:80") s
    runResourceT $ runTCPServer (serverSettings (port s') "*4") $ server s'
    return ()
    
-- | добавляем поток в радио
addRadio::Radio -> RadioUrl -> ServerState ()
addRadio radio url = do
    buffer <- liftIO $ newTBMChanIO 16384
    channel <- liftIO $ buff buffer
    Server{..} <- get
    info <- liftIO $ newMVar $ ChannelInfo radio url buffer channel Nothing 0 False [] Nothing
    let fun stMap = return $ Map.insert radio info stMap 
    liftIO $ modifyMVar_ radioState fun
     
-- | Создаем процесс для переноса потока с буфера в канал, 
-- | и процесс для очистки канала, для каждой радиостанции.
-- @todo добавить пиды процессов в состояние
buff::Buffer -> IO (TMChan ByteString)
buff buffer = do
    chan <- newTMChanIO
    forkIO $ copy buffer chan
    forkIO $ forever $ void . atomically $ readTMChan chan
    return chan
    
-- | Гоним поток с буфера в канал.
copy::TBMChan ByteString -> TMChan ByteString -> IO ()
copy buffer chan = forever $ do
    free <- atomically $ freeSlotsTBMChan buffer
    case free < 8192 of
         True -> atomically $ do
             slot <- readTBMChan buffer
             case slot of
                  Just a -> writeTMChan chan a
                  Nothing -> return ()
         False -> threadDelay 10000    
             
--------------------------------------- Server ---------------------------------------------------
    
-- | Создаем сервер
server::(Monad m, MonadResource m) => Server -> Application m
server st ad = do
    ((req,_):headers) <- appSource ad $$ parseHeaders id
    let radio = parseRequest req
    say ("request"::String)
    say radio
    connection <-  liftIO $ isRadioAndConnect radio $ radioState st
    say ("headers"::String)
    say headers
    say $ "(radio, connection) " ++ show connection
    case connection of
         (False, _) -> sourceList ["ICY 404 OK\r\n"] $$ appSink ad
         (True, False) -> do
             channelMVar <- liftIO $ getChannelMVar radio $ radioState st
             liftIO $ void . forkIO $ runResourceT $ startClientForServer channelMVar 
             startClient channelMVar (appSink ad)
         (True, True) -> do
             channelMVar <- liftIO $ getChannelMVar radio $ radioState st
             startClient channelMVar (appSink ad)
    return ()
        
-- | Когда подключается первый клиент к радиостанции, создаем коннект до радиостанции.
startClientForServer :: MVar ChannelInfo ->  ResourceT IO ()
startClientForServer channelMVar = do
    url' <- liftIO $ url <$> readMVar channelMVar
    req <- HTTP.parseUrl $ C.unpack url'
    let port = HTTP.port req
        host = HTTP.host req
        path = HTTP.path req
        settings = clientSettings port host
-- | Делаем соединение до радиостанции.
    runTCPClient settings $ clientForServer channelMVar path
    return ()

-- | Парсим инфу с радиостанции, льем поток в буфер.
clientForServer :: MVar ChannelInfo -> ByteString -> Application (ResourceT IO)
clientForServer mv path ad = do
    say ("start client for server"::String)
    let req = BS.concat ["GET ", path, " HTTP/1.1\r\nIcy-MetaData: 1\r\n\r\n"]
    sourceList [req] $$ appSink ad
    (l, (st,_):headers) <- appSource ad $$  zipSinks getLength $ parseHeaders id
    let metaInt = fromMaybe 0 $ do m <- lookup "icy-metaint" headers
                                   (i, _) <- C.readInt m
                                   return i
    meta'' <- appSource ad $$ parseMeta metaInt l
    say $ "set meta"
    say $ BS.concat $ LB.toChunks meta''
    liftIO $ setMeta mv $ BS.concat $ LB.toChunks meta''
    buffer' <- liftIO $ getBuffer mv
    liftIO $ setConnection mv
    say "headers from server"
    say headers
    say ("make pipe server => buffer"::String)
    appSource ad $$ sinkTBMChan buffer'
    

--------------------------------------- Client  --------------------------------------------------
 
-- | Обрабатываем клиента, копируем канал, и берем поток оттуда.
    
startClient ::(Monad m, MonadIO m) => MVar ChannelInfo -> Sink ByteString m () -> m ()
startClient channelMVar sinkI = do
    connection <- liftIO $ getConnection channelMVar
    if connection
       then startClient' channelMVar sinkI
       else do
           liftIO $ threadDelay 500000
           startClient channelMVar sinkI
           
startClient'::(Monad m, MonadIO m) => MVar ChannelInfo -> Sink ByteString m () -> m ()
startClient' channelMVar sinkI = do
    let resp = concat [ "ICY 200 OK\r\n"
                      , "icy-notice1: Haskell shoucast splitter\r\n"
                      , "icy-notice2: Good music here\r\n"
                      ]
                          
        resp1 = concat [ "content-type: audio/mpeg\r\n"
                       , "icy-name: Good music for avery one \r\n"
                       , "icy-url: http://localhost:2000/bigblue \r\n"
                       , "icy-genre: Swing  Big Band  Jazz  Blues\r\n"
                       , "icy-pub: 1\r\n"
                       , "icy-metaint: 8192\r\n"
                       , "icy-br: 64\r\n\r\n"
                       ]
    sourceList [resp] $$ sinkI
    sourceList [resp1] $$ sinkI
    channel <- liftIO $ channel <$> readMVar channelMVar
    !maybeMeta <- liftIO $ meta <$> readMVar channelMVar
    dup <- liftIO $ atomically $ dupTMChan channel
    say "meta here"
    say $ maybeMeta
    case maybeMeta of
         Nothing -> sourceTMChan dup $$ sinkI
         Just meta'' -> do
             let size = truncate $ (fromIntegral . BS.length) meta'' / 16 
                 metaInfo = case compare (16 * size) $ BS.length meta'' of
                                  EQ -> trace "EQ" BS.concat [(BS.singleton . fromIntegral) size, meta'']
                                  GT -> trace "GT" BS.concat [(BS.singleton . fromIntegral) (size + 1), meta'', BS.replicate (16 * (1 + size) - BS.length meta'') 0]
                                  LT -> undefined
             say "meta info"
             say metaInfo
             say $ BS.length metaInfo
             sourceTMChan dup $= addMeta metaInfo 8192  $$ sinkI
             
addMeta::Monad m => ByteString -> Int -> Conduit ByteString m ByteString
addMeta h n = conduitState (0, 0) push close
  where push (st, len) input 
           | st == 0 = 
              if BS.length input > n - len
                   then trace "insert meta" return $ StateProducing (1, 0) [BS.concat [one, h, two]]
                   else return $ StateProducing (0, len + BS.length input) [input]
           | otherwise = return $ StateProducing (1, 0) [input] 
              where (one, two) = BS.splitAt (n - len) input
           
        close state = return []
        
--------------------------------------- Internal ---------------------------------------------
    
say::(Show a, MonadIO m) => a -> m ()
say = liftIO . print
       
-- | Проверяем наличие радиостанции с таким именем, и наличие соединения до радиостанции.
isRadioAndConnect::Radio -> RadioState -> IO (Bool, Bool)
isRadioAndConnect radio' radioState' = do
    maybeChannel <- withMVar radioState' $ fun radio'
    case maybeChannel of
         Nothing -> return (False, False)
         Just ChannelInfo{..} -> return (True, connection)
    where
         fun key rMap = case key `Map.lookup` rMap of
                             Nothing -> return Nothing
                             Just m -> do
                                 result <- liftIO $ readMVar m
                                 return $ Just result
    
-- | Ставим флаг соединения в ChannelInfo
setConnection :: MVar ChannelInfo -> IO ()
setConnection mv = modifyMVar_ mv $ \x -> return $ x { connection = True }

-- | Выставляем мета информацию в ChannelInfo
setMeta::MVar ChannelInfo -> Meta -> IO ()
setMeta mv meta'' = modifyMVar_ mv $ \x -> return $ x { meta = Just meta'' }
        
-- | Получаем буфер 
getBuffer :: MVar ChannelInfo -> IO Buffer
getBuffer mv = buffer <$> readMVar mv
    
-- | Есть или нет соединение до радиостанции
getConnection :: MVar ChannelInfo -> IO Bool
getConnection mv = connection <$> readMVar mv
    
-- | Получаем канал
getChannelMVar::MonadIO m => Radio -> RadioState -> m (MVar ChannelInfo)
getChannelMVar radio radioState = liftIO $ withMVar radioState (fun radio)
   where fun key rmap = return . fromJust $ Map.lookup key rmap
 
-- | парсим метаданные
parseMeta::(Monad m, MonadIO m) => Int -> Int -> Sink ByteString m LByteString
parseMeta metaInt headerLength = do
    CB.drop (metaInt - headerLength)
    len <- CB.head 
    let toInt = fromIntegral . fromJust
        len' = 16 * toInt len
    CB.take len'
    
-- | размер после запроса
getLength::(Monad m, MonadIO m, MonadResource m) => Sink ByteString m Int
getLength = sinkState 0 push close
    where
       push st input = do
          let (_,b) = breakSubstring "\r\n\r\n" input
          case (BS.null b, st < 3) of
              (True, True) -> return $ StateProcessing $ st + 1 
              (True, False) -> return $ StateDone Nothing 0  
              (False, _) -> return $ StateDone Nothing $ BS.length b -4
       close = return 

charLF, charCR, charSpace, charColon :: Word8
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
   | BS.null bs = bs
   | BS.last bs == charCR = BS.init bs
   | otherwise = bs
   
parseRequest::ByteString -> Radio
parseRequest line = let (_:url:_) = split charSpace line
                    in url
 
parseHeader::Monad m => ByteString -> Sink ByteString m (ByteString, ByteString)
parseHeader bs = do
    let (key, bs2) = breakByte charColon bs
    return (strip key, strip $ BS.drop 1 bs2)

strip::ByteString -> ByteString
strip = BS.dropWhile (== charSpace) . fst . spanEnd (== charSpace)

    
parseHeaders::(Monad m, MonadIO m, MonadResource m) => (Headers -> Headers) -> Sink ByteString m Headers
parseHeaders front = do
    line <- sinkLine
    if BS.null line
       then return $ front []
       else do
           header <- parseHeader line
           parseHeaders $ front . (header:)
  
  

request, response, meta' :: LByteString
request = LB.fromChunks ["GET / HTTP/1.0\r\nUser-Agent: mpg123/1.14.4\r\nHost: radio.bigblueswing.com:8002\r\nAccept: audio/mpeg, audio/x-mpeg, audio/mp3, audio/x-mp3, audio/mpeg3, audio/x-mpeg3, audio/mpg, audio/x-mpg, audio/x-mpegaudio, application/octet-stream, audio/mpegurl, audio/mpeg-url, audio/x-mpegurl, audio/x-scpls, audio/scpls, application/pls, */*\r\nIcy-MetaData: 1\r\n\r\n"]
response = LB.fromChunks ["ICY 200 OK\r\nicy-notice1:<BR>This stream requires <a href=\"http://www.winamp.com/\">Winamp</a><BR>\r\nicy-notice2:SHOUTcast Distributed Network Audio Server/Linux v1.9.8<BR>\r\n"]
meta' = LB.fromChunks ["ncontent-type:audio/mpeg\r\nicy-pub:1\r\nicy-metaint:8192\r\nicy-br:64\r\n\r\n"]
    
-- http://radio.bigblueswing.com:8002/
    
-- http://ru.ah.fm/
