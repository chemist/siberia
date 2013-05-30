{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE TypeSynonymInstances   #-}
module Siberia.Internal (
  module Siberia.Data
  , makeChannel
  , load
  , save
  , say
  , connectWithRemoveMetaAndBuffering
  , connectWithAddMetaAndBuffering
  , saveClientPid
  , removeClientPid
  ) where

import           BasicPrelude                             hiding (FilePath, Map,
                                                           appendFile)
import           Control.Concurrent                       hiding (yield)
import           Data.Map                                 (Map)
import qualified Data.Map                                 as Map
import           Prelude                                  (FilePath)
import qualified Prelude

import           Data.Attoparsec                          (parseOnly)
import qualified Data.Attoparsec                          as A
import           Data.Attoparsec.RFC2616
import qualified Data.ByteString                          as BS
import qualified Data.ByteString.Char8                    as C
import qualified Data.ByteString.Lazy                     as LS
import           Data.IORef
import           Data.Maybe                               (fromJust)
import           Network.Socket
import           System.IO.Streams                        as S
import           System.IO.Streams.Attoparsec             as S
import           System.IO.Streams.Concurrent             as S
import           System.IO.Streams.Internal               as S

import           Control.Monad.Reader
import qualified Control.Monad.Reader                     as M

import           Blaze.ByteString.Builder                 (Builder)
import qualified Blaze.ByteString.Builder                 as Builder
import           Blaze.ByteString.Builder.Internal.Buffer (allNewBuffersStrategy)
import           Data.Binary                              (decode, encode)
import qualified Data.Collections                         as Collections
import           Data.Cycle
import           Data.IORef
import           Data.Text.Encoding                       as E
import           Data.Text.IO                             (appendFile)
import           Paths_siberia
import           Siberia.Data
import qualified System.Process                           as P

-- | for log messages
say :: MonadIO m => Text -> m ()
say x = putStrLn x

-- | save state to disk
save :: Allowed m => Prelude.FilePath -> m ()
save path = do
    l <- list :: Allowed m => m [Radio]
    say "save radio station"
    M.mapM_ (\x -> say $ show x ) l
    liftIO $ LS.writeFile path $ encode l

-- | load state from disk
load :: Allowed m => Prelude.FilePath -> m ()
load path = do
    l <- liftIO $ LS.readFile path
    let radio  = decode l :: [Radio]
    say "load next radio station"
    M.mapM_ (say . show) radio
    _ <- M.mapM_ create radio
    return ()


-- | create channel
makeChannel::Radio -> Application ()
makeChannel radio = do
    say "start make channel"
    radioStreamInput <- try $ getStream radio :: Application (Either SomeException (InputStream ByteString))
    either whenError whenGood radioStreamInput
    where
      whenError x = do
          say $ "Error when connection: " ++ show x
          setD radio (Nothing :: Maybe (Chan (Maybe ByteString)))
      whenGood radioStreamInput' = do
          say "start good"
          stateR <- ask
          let saveMeta :: Maybe Meta -> IO ()
              saveMeta x = runReaderT (setD radio x) stateR
          chan <- liftIO newChan
          buf' <- liftIO $ new 60 :: Application (Buffer ByteString)
          setD radio (Just buf')
          metaInt <- unpackMeta <$> (lookupHeader "icy-metaint" <$> getD radio) :: Application (Maybe Int)
          say "have meta int"
          say $ show metaInt
          chanStreamOutput <- liftIO $ S.chanToOutput chan
          (chanStreamInput, countInputBytes)  <- liftIO $ S.countInput =<< S.chanToInput  chan
          setD radio countInputBytes
          outputBuffer <- liftIO $ outputStreamFromBuffer buf'
          say "have output buffer"
          (p1,p2) <- liftIO $ connectWithRemoveMetaAndBuffering metaInt saveMeta 8192 radioStreamInput' chanStreamOutput
          p3 <-  liftIO $ forkIO $ S.connect chanStreamInput outputBuffer
          setD radio $ Status 0 (Just p1) (Just p2) (Just p3) []
          setD radio (Just chan :: Maybe (Chan (Maybe ByteString)))
          say "finish output buffer"
          --  TODO save pid
          return ()
      unpackMeta :: [ByteString] -> Maybe Int
      unpackMeta meta' = do
          m <- listToMaybe meta'
          (a,_) <- C.readInt m
          return a

-- | Parse stream, remove meta info from stream, bufferize, save meta info in state
connectWithRemoveMetaAndBuffering ::Maybe Int                -- ^meta int
                                  -> (Maybe Meta -> IO ())     -- ^save meta info to state
                                  -> Int                      -- ^buffer size
                                  -> InputStream ByteString   -- ^input stream
                                  -> OutputStream ByteString  -- ^output stream
                                  -> IO (ThreadId, ThreadId)  -- ^return pids
connectWithRemoveMetaAndBuffering Nothing _ buffSize is os = do
    builder <- S.builderStreamWith (allNewBuffersStrategy buffSize) os
    ps <- S.parserToInputStream toBuilder is
    x <- forkIO $ S.connect ps builder
    return (x,x)

connectWithRemoveMetaAndBuffering (Just metaInt) saveMeta buffSize is os = do
    builder <- S.builderStreamWith (allNewBuffersStrategy buffSize) os
    parsed <-  S.parserToInputStream (metaParser metaInt) is
    (isb, ism) <- S.unzip parsed
    osm <- S.makeOutputStream saveMeta
    x <- forkIO $ S.connect isb builder
    y <- forkIO $ S.connect ism osm
    return (x,y)
{-# INLINE connectWithRemoveMetaAndBuffering #-}

-- | builder parser
toBuilder :: A.Parser (Maybe Builder)
toBuilder = (A.endOfInput >> pure Nothing) <|> Just . Builder.fromByteString <$> A.take 32752

-- | meta info parser
metaParser :: Int -> A.Parser (Maybe (Builder, Meta))
metaParser metaInt = (A.endOfInput >> pure Nothing) <|> Just <$> do
    body <- A.take metaInt
    len <- toLen <$> A.take 1
    meta <- A.take len
    return (Builder.fromByteString body, Meta (meta, len))

-- | unpack meta info size
toLen :: ByteString -> Int
toLen x = let [w] = BS.unpack x
          in 16 * fromIntegral w

newtype Chunk = Chunk ByteString

-- | chunk parser
toChunks :: Int -> A.Parser (Maybe Chunk)
toChunks metaInt = (A.endOfInput >> pure Nothing) <|> Just . Chunk <$> A.take metaInt

-- | input >-< output and add meta info
connectWithAddMetaAndBuffering :: Maybe Int       -- ^ meta int
                               ->  IO (Maybe Meta) -- ^ get meta info
                               ->  Int             -- ^ buffer size
                               ->  InputStream ByteString -- ^ input stream
                               ->  OutputStream ByteString -- ^ output stream
                               ->  IO ()
connectWithAddMetaAndBuffering Nothing _ buffSize is os = do
    builder <- S.builderStreamWith (allNewBuffersStrategy buffSize) os
    ps <- S.parserToInputStream toBuilder is
    S.connect ps builder

connectWithAddMetaAndBuffering (Just metaInt) getMeta buffSize is os = do
    builder <- S.builderStreamWith (allNewBuffersStrategy buffSize) os
    chunked <- S.parserToInputStream (toChunks metaInt) is
    metas   <- S.makeInputStream $ do
        m <- getMeta
        return $ Just $ maybe (Meta ("", 0)) id m
    refMeta <- newIORef $ Just (Meta ("", 0))
    withMeta <- S.zipWithM (fun refMeta) chunked metas
    ref <- newIORef 0
    S.connect withMeta builder
    where
    fun:: IORef (Maybe Meta) -> Chunk -> Meta -> IO Builder
    fun ref (Chunk bs) (Meta (meta', len)) = do
        result <- atomicModifyIORef ref (check meta' len)
        return $ Builder.fromByteString $ if result
           then bs <> fromLen len <> meta'
           else bs <> zero

    check :: ByteString -> Int -> Maybe Meta -> (Maybe Meta, Bool)
    check _ _ Nothing = (Nothing, False)
    check bs nl (Just (Meta (m, l))) =
      if bs == m
         then (Just (Meta (m,l)), False)
         else (Just (Meta (bs,nl)), True)

    fromLen :: Int -> ByteString
    fromLen x = (BS.singleton . fromIntegral) $ truncate $ (fromIntegral x / 16)

    zero :: ByteString
    zero = BS.pack [toEnum 0]

{-# INLINE connectWithAddMetaAndBuffering #-}


-- | make stream from buffer
outputStreamFromBuffer :: Buffer ByteString -> IO (OutputStream ByteString)
outputStreamFromBuffer buf' = makeOutputStream f
   where
   f Nothing = return $! ()
   f (Just x) = update x buf'
{-# INLINE outputStreamFromBuffer #-}

-- | create stream
getStream :: Radio -> Application (InputStream ByteString)
getStream radio = getStream' =<< (getD radio :: Application Radio)
  where
  -- for testing only
  getStream' :: Radio -> Application (InputStream ByteString)
  getStream' (ById (RadioId "/test")) = liftIO $ S.fromGenerator $ genStream fakeRadioStream'
    where
      fakeRadioStream' :: [ByteString]
      fakeRadioStream' = BasicPrelude.map (\x -> (E.encodeUtf8 . show) x <> " ") [1.. ]

      genStream :: [ByteString] -> S.Generator ByteString ()
      genStream x = do
          let (start, stop) = splitAt 1024 x
          S.yield $ mconcat start
          liftIO $ threadDelay 100000
          genStream stop

  -- proxy stream
  getStream' radio@Proxy{} = do
      (i, o) <- openConnection radio
      let Url url' = url radio
      let Right path = parseOnly parsePath url'
          req = "GET " <> path <> " HTTP/1.0\r\nicy-metadata: 1\r\n\r\n"
      say "url from radio"
      say $ show url'
      say "request to server"
      say $ show req
      requestStream <- liftIO $ S.fromByteString req
      liftIO $ S.connect requestStream o
      (response', headers') <- liftIO $ S.parseFromStream response i
      --  @TODO обработать исключения
      setD radio headers'
      say $ show response'
      say $ show headers'
      say "makeConnect end"
      return i
      where
        -- | открываем соединение до стрим сервера
        openConnection :: Radio -> Application (InputStream ByteString, OutputStream ByteString)
        openConnection radio = do
            let Url url' = url radio
            let Right (hb, pb) = parseOnly parseUrl url'
                h = C.unpack hb
                p = C.unpack pb
            say $ show h
            say $ show p
            is <- liftIO $ getAddrInfo (Just hints) (Just h) (Just p)
            let addr = head is
            let a = addrAddress addr
            s <- liftIO $  socket (addrFamily addr) Stream defaultProtocol
            liftIO $ Network.Socket.connect s a
            (i,o) <- liftIO $ S.socketToStreams s
            return (i, o)
            where
               hints = defaultHints {addrFlags = [AI_ADDRCONFIG, AI_NUMERICSERV]}

  -- local stream
  getStream' radio@Local{} = do
      reader <- ask
      handleIO <- liftIO $ newIORef Nothing
      liftIO $ makeInputStream $ f reader handleIO
      where
        getNextSong :: Application (Maybe FilePath)
        getNextSong = do
            playList' <- getD radio :: Application (Maybe Playlist)
            let sfile = spath . getValue <$> playList'
                newPlayList = goRight <$> playList'
                RadioId channelDir = rid radio
            setD radio newPlayList
            dataDir <- liftIO getDataDir
            return $ (<$>) concat $ sequence [pure dataDir, pure musicDirectory, pure (tail $ C.unpack channelDir), pure "/", sfile]
        f:: Store -> IORef (Maybe (InputStream BS.ByteString)) -> IO (Maybe BS.ByteString)
        f reader channelIO = do
            maybeCh <- readIORef channelIO
            case maybeCh of
                 Nothing -> do
                     file <- runReaderT getNextSong reader
                     case file of
                          Nothing -> do
                              say "empty playlist"
                              return Nothing
                          Just file' -> do
                              say $ show file
                              channel <- runFFmpeg file'
                              writeIORef channelIO $ Just channel
                              f reader channelIO
                 Just ch -> do
                     !chunk <- S.read ch
                     case chunk of
                          Just c -> return $! Just c
                          Nothing -> do
                              writeIORef channelIO Nothing
                              f reader channelIO

-- buffer size
bUFSIZ = 32752

-- const ffmpeg
command :: String
command = "ffmpeg -re -i - -f mp3 -acodec copy -"

-- | create InputStream from file
runFFmpeg ::String ->  IO (S.InputStream BS.ByteString)
runFFmpeg filename = do
    (i, o, e, ph ) <- S.runInteractiveCommand command
    forkIO $ do nullOutput <- S.nullOutput
                S.withFileAsInput filename (fun i)
                S.connect e nullOutput
                exitCode <- P.waitForProcess ph
                say $ show exitCode
                say "next song"
    return o
    where fun :: S.OutputStream BS.ByteString -> S.InputStream BS.ByteString -> IO ()
          fun os is = S.connect is os

saveClientPid :: ThreadId -> Radio -> Application ()
saveClientPid t radio = savePid =<< info radio
    where 
    savePid mv = liftIO $ modifyMVar_ mv fun
    fun :: Radio -> IO Radio 
    fun r = let oldStatus = pid r
                newConnections = 1 + (connections oldStatus)
                newConnectionsProcesses = t:(connectionsProcesses oldStatus)
                
                newStatus = oldStatus { connections = newConnections
                                      , connectionsProcesses = newConnectionsProcesses
                                      }
            in return $ r { pid = newStatus }

removeClientPid :: ThreadId -> Radio -> Application ()
removeClientPid t mv = removePid =<< info mv
    where
    removePid mv = liftIO $ modifyMVar_ mv fun
    fun :: Radio -> IO Radio
    fun r = do
        let oldStatus = pid r
            newConnections = (connections oldStatus) - 1
            newConnectionsProcesses = Prelude.filter (/= t) (connectionsProcesses oldStatus)
            newStatus = oldStatus { connections = newConnections
                                  , connectionsProcesses = newConnectionsProcesses
                                  }
        liftIO $ forkIO $ case (r, newConnections == 0) of
             (Proxy{..}, True) -> do
                 say "last user go away"
                 say "kill proxy radio channel"
                 killThread $ fromJust $ connectProcess oldStatus
                 killThread $ fromJust $ chanProcess oldStatus
                 killThread $ fromJust $ bufferProcess oldStatus
             _ -> return ()
        return $ r { pid = newStatus }

instance Monoid a => RadioBuffer Buffer a where
    new n = do
        l <-  sequence $ replicate n (newIORef empty :: Monoid a => IO (IORef a))
        l' <- newIORef $ Collections.fromList l
        p <- newIORef $ Collections.fromList [1 .. n]
        s <- newIORef n
        return $ Buffer p l' s
    bufSize = readIORef . size
    current x = readIORef (active x) >>= return . getValue
    nextC   x = readIORef (active x) >>= return . rightValue
    lastBlock x = do
        position <- readIORef $ active x
        buf' <- readIORef $ buf x
        readIORef $ nthValue (getValue position) buf'
    update x y = do
        modifyIORef (active y) goRight
        position <- readIORef $ active y
        buf' <- readIORef $ buf y
        modifyIORef (nthValue (getValue position) buf') $ const x
        return ()
    getAll x = do
        s <- bufSize x
        position <- readIORef $ active x
        buf' <- readIORef $ buf x
        let res = takeLR s $ goLR (1 + getValue position) buf'
        mconcat <$> Prelude.mapM readIORef res

instance Allowed m => Storable m Radio where
    member (ById (RadioId "/test")) = return True
    member r = do
        (Store x _) <- ask
        liftIO $ withMVar x $ \y -> return $ rid r `Map.member` y
    create r = do
        (Store x hp) <- ask
        let withPort = addHostPort hp r
        is <- member r
        if is
           then return (False, undefined)
           else do
               mv <- liftIO $ newMVar withPort
               liftIO $ modifyMVar_ x $ \mi -> return $ Map.insert (rid r) mv mi
               return (True, withPort)
    remove r = do
        (Store x _) <- ask
        --  @TODO прибить все пользовательские потоки, прибить процессы из статуса
        is <- member r
        if is
           then do
               liftIO $ modifyMVar_ x $ \mi -> return $ Map.delete (rid r) mi
               return True
           else return False
    list = do
        (Store x _) <- ask
        liftIO $ withMVar x fromMVar
        where
          fromMVar :: Map RadioId (MVar Radio) -> IO [Radio]
          fromMVar y = Prelude.mapM (\(_, mv) -> withMVar mv return) $ Map.toList y
    info a = do
        (Store x _) <- ask
        liftIO $ withMVar x $ \y -> return $ fromJust $ Map.lookup (rid a) y
    --  @TODO catch exception

addHostPort::HostPort -> Radio -> Radio
addHostPort hp x = x { hostPort = hp }

-- | helpers
getter ::(Radio -> a) -> MVar Radio -> IO a
getter x =  flip  withMVar (return . x)

setter :: (Radio -> Radio) -> MVar Radio -> IO ()
setter x  =  flip modifyMVar_ (return . x)

instance Allowed m => Detalization m Radio where
    getD radio = info radio >>= liftIO . (flip withMVar return)
    setD = undefined

instance Allowed m => Detalization m Url where
    getD radio = info radio >>= liftIO . getter url
    setD radio a = info radio >>= liftIO . setter (\y -> y { url = a })

instance Allowed m => Detalization m Status where
    getD radio = info radio >>= liftIO . getter pid
    setD radio a = info radio >>= liftIO . setter (\y -> y { pid = a })
           
instance Allowed m => Detalization m Headers where
    getD radio = info radio >>= liftIO . getter headers
    setD radio a = info radio >>= liftIO . setter (\y -> y { headers = a })

instance Allowed m => Detalization m Channel where
    getD radio = info radio >>= liftIO . getter channel
    setD radio a = info radio >>= liftIO . setter (\y -> y { channel = a })

instance Allowed m => Detalization m (Maybe Meta) where
    getD radio = info radio >>= liftIO . getter meta
    setD _ (Just (Meta ("",0))) = return ()
    setD radio a = info radio >>= liftIO . setter (\y -> y { meta = a })

instance Allowed m => Detalization m (Maybe (Buffer ByteString)) where
    getD radio = info radio >>= liftIO . getter buff
    setD radio a = info radio >>= liftIO . setter (\y -> y { buff = a})

instance Allowed m => Detalization m (Maybe Playlist) where
    getD radio = do
        i <- info radio
        liftIO $ withMVar i fun
        where
          fun x@Local{} = return $ playlist x
          fun _ = return Nothing
    setD radio a = do
        i <- info radio
        liftIO $ void (try $ setter (\y -> y { playlist = a}) i :: IO (Either SomeException ()))

instance Allowed m => Detalization m (IO Int64) where
    getD radio = info radio >>= liftIO . getter countIO
    setD radio a = info radio >>= liftIO . setter (\y -> y {countIO = a})


