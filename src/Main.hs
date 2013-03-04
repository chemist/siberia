-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
    
module Main where

import Prelude (show, Show(..))
import BasicPrelude hiding (show, Show(..))

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
import Data.Text (unpack)

--------------------------------------- Types ---------------------------------------------------
    
type Buffer = TBMChan ByteString
type Channel = TMChan ByteString
type Clients = TMVar Int

type Headers = [(ByteString, ByteString)]
type Meta = ByteString
type Radio = ByteString
type RadioUrl = ByteString
type MetaInt = Int
                 
data ChannelInfo = ChannelInfo { radio::Radio
                               , url  ::RadioUrl
                               , buffer:: Buffer
                               , channel:: Channel
                               , clientPid:: Maybe ThreadId
                               , clients:: Int 
                               , connection :: Bool
                               , headers::Headers
                               , meta::Maybe Meta
                               , headerLength :: Int
                               }
                               
instance Show ChannelInfo where
    show ChannelInfo{..} = show radio ++ " " ++ show url ++ " " ++ show clients ++ " " ++ show connection 

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
    info <- liftIO $ newMVar $ ChannelInfo radio url buffer channel Nothing 0 False [] Nothing 0
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
    slot <- atomically $ readTBMChan buffer
    case slot of
         Just a -> atomically $ writeTMChan chan a
         Nothing -> threadDelay 10000
             
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
    (st,_):headers' <- appSource ad $= getHeaderLength mv $$  parseHeaders id
    !_ <- setHeaders mv headers'
    !buffer' <- liftIO $ getBuffer mv
    !_ <- setConnection mv
    say "headers from server"
    say headers'
    say ("make pipe server => buffer"::String)
    appSource ad $$ parseMeta mv =$ sinkTBMChan buffer'
    

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
    !channel <- liftIO $ channel <$> readMVar channelMVar
    !maybeMeta <- liftIO $ meta <$> readMVar channelMVar
    !dup <- liftIO $ atomically $ dupTMChan channel
    case maybeMeta of
         Nothing -> sourceTMChan dup $$ sinkI
         Just meta'' -> do
             let size = truncate $ (fromIntegral . BS.length) meta'' / 16 
                 metaInfo = case compare (16 * size) $ BS.length meta'' of
                                  EQ -> BS.concat [(BS.singleton . fromIntegral) size, meta'']
                                  GT -> BS.concat [(BS.singleton . fromIntegral) (size + 1), meta'', BS.replicate (16 * (1 + size) - BS.length meta'') 0]
                                  LT -> undefined
             say "meta info"
             say metaInfo
             say $ BS.length metaInfo
             a <- liftIO $ readMVar channelMVar
             say a
             sourceTMChan dup $= addMeta metaInfo 8192 $$ sinkI
             
addMeta::(Monad m, MonadIO m) => Meta -> MetaInt -> Conduit ByteString m ByteString
addMeta input position = loop input position (0, 0)
    where
      loop ::(Monad m, MonadIO m) =>  ByteString -> Int -> (Int, Int) -> Conduit ByteString m ByteString
      loop meta metaInt (st, len) = do
          chunk <- await
          case (chunk, st) of
               (Nothing, _) -> trace "nothing" return ()
               (Just chunk', 0) -> do
                   let (one, two) = BS.splitAt (metaInt -len) chunk'
                   if BS.length chunk' > metaInt - len
                      then do yield $ one ++ input ++ two 
                              loop meta metaInt (1, 0)
                      else do yield chunk'
                              loop meta metaInt (0, len + BS.length chunk')
               (Just chunk', _) -> do
                   yield chunk' 
                   loop meta metaInt (1, 0)
                   
        
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
setConnection :: (Monad m, Functor m, MonadIO m) => MVar ChannelInfo -> m ()
setConnection mv = void . liftIO $ forkIO $ do
    threadDelay 500000
    modifyMVar_ mv $ \x -> return $ x { connection = True }

-- | Выставляем мета информацию в ChannelInfo
setMeta::MVar ChannelInfo -> Meta -> IO ()
setMeta mv meta'' = do
    !_ <- modifyMVar_ mv $ \x -> return $ x { meta = Just meta'' }
    return ()
        
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
parseMeta::(Monad m, MonadIO m) => MVar ChannelInfo -> Conduit ByteString m ByteString
parseMeta mv = do
    channel <- liftIO $ readMVar mv
    let headers' = headers channel
    say headers'
    let metaInt = fromMaybe 0 $ do m <- lookup "icy-metaint" headers'
                                   (i, _) <- C.readInt m
                                   return i
    let headerLength' =  headerLength channel
    say headerLength'
    loop (0::Int, metaInt - headerLength')
    where 
      loop (1, _) = do
          chunk <- await
          case chunk of
               Nothing -> return ()
               Just chunk' -> do
                   yield chunk'
                   loop (1, 0)
      loop (0, st) = do
          chunk <- await
          case chunk of 
               Nothing -> return ()
               Just chunk' -> if st > BS.length chunk' 
                                then loop (0, st - BS.length chunk')
                                else do
                                    let (h, t) = BS.splitAt st chunk'
                                        len' = 1 + 16 * (fromIntegral . BS.head) t
                                        (m, l) = BS.splitAt len' t
                                    say "parse meta"
                                    say  $ BS.tail m
                                    liftIO $ setMeta mv $ BS.tail m
                                    yield $ BS.concat [h, l]
                                    loop (1, 0)
                   
 
getHeaderLength::(Monad m, MonadIO m, MonadResource m) => MVar ChannelInfo -> Conduit ByteString m ByteString
getHeaderLength info = loop (0::Int)
  where 
    loop st = do
        chunk <- await
        let (_, stream) = breakSubstring "\r\n\r\n" $ fromJust chunk
        case (isJust chunk, st < 3) of
             (False, _) -> return ()
             (True, False) -> yield $ fromJust chunk
             (True, True) -> if BS.null stream
                    then do
                        yield $ fromJust chunk
                        loop $ st + 1
                    else do !_ <- setHeaderLength info $ BS.length stream - 4
                            yield $ fromJust chunk
                            loop 3
                            
setHeaderLength::(Monad m, MonadIO m) => MVar ChannelInfo -> Int -> m ()
setHeaderLength mv hl = liftIO $ modifyMVar_ mv $ \x -> return $ x { headerLength = hl }

getHeaderLengthM mv = headerLength <$> readMVar mv

setHeaders mv headers' = liftIO $ modifyMVar_ mv $ \x -> return $ x { headers = headers' }

-- | размер после запроса
getLength::(Monad m, MonadIO m, MonadResource m) => Sink ByteString m Int
getLength = loop (0::Int)
  where
    loop st = do
        chunk <- await 
        let (_, stream) = breakSubstring "\r\n\r\n" $ fromJust chunk
        case (isJust chunk, st < 3) of
             (False, _) -> return 0
             (True, True) -> if BS.null stream 
                                       then loop $ st + 1
                                       else return $ BS.length stream - 4
             (True, False ) ->  return 0

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
  

------ testing ----
  

request, response, meta' :: LByteString
request = LB.fromChunks ["GET / HTTP/1.0\r\nUser-Agent: mpg123/1.14.4\r\nHost: radio.bigblueswing.com:8002\r\nAccept: audio/mpeg, audio/x-mpeg, audio/mp3, audio/x-mp3, audio/mpeg3, audio/x-mpeg3, audio/mpg, audio/x-mpg, audio/x-mpegaudio, application/octet-stream, audio/mpegurl, audio/mpeg-url, audio/x-mpegurl, audio/x-scpls, audio/scpls, application/pls, */*\r\nIcy-MetaData: 1\r\n\r\n"]
response = LB.fromChunks ["ICY 200 OK\r\nicy-notice1:<BR>This stream requires <a href=\"http://www.winamp.com/\">Winamp</a><BR>\r\nicy-notice2:SHOUTcast Distributed Network Audio Server/Linux v1.9.8<BR>\r\n"]
meta' = LB.fromChunks ["ncontent-type:audio/mpeg\r\nicy-pub:1\r\nicy-metaint:8192\r\nicy-br:64\r\n\r\n"]
    
-- http://radio.bigblueswing.com:8002/
    
-- http://ru.ah.fm/
    

sink :: Sink ByteString IO ()
sink = do
        mstr <- await
        case mstr of
           Nothing -> return ()
           Just str -> do
               liftIO $ BS.putStrLn str
               sink
               
testS ::ByteString
testS = "qwertyuiopasdfghjklzxcvbnm"

m::ByteString
m = "AAA"


