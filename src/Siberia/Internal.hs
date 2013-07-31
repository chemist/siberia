{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE TypeSynonymInstances   #-}
module Siberia.Internal (
  module Siberia.Data
  , client
  , load
  , save
  , say
  , connectWithRemoveMetaAndBuffering
  , saveClientPid
  , removeClientPid
  , insertMeta
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
import Network.URI
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
import Siberia.Streamer

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

client :: ShoutCast
client SRequest{..} = client' =<< getD radio 

client' :: Radio -> Application (InputStream Builder)
client' radio = maybe notConnected haveChannel =<<  (getD radio :: Application Channel)
    where
    haveChannel chan = do
        pid <- liftIO myThreadId
        saveClientPid pid radio
        Just buf' <- getD radio :: Application (Maybe (Buffer ByteString))
        duplicate <- liftIO $ dupChan chan
        okResponse <- liftIO $ S.map Builder.fromByteString =<< S.fromByteString successRespo
        (input, countOut) <- liftIO $ S.countInput =<< S.chanToInput duplicate
        countIn <- getD radio :: Application (IO Int64)
        -- killer here
        liftIO $ forkIO $ do
            start <- newIORef =<< countIn
            forever $ do
                s <- readIORef start
                cI <- countIn
                cO <- countOut
                when (cI - cO - s > 300000) $ do
                    say $ "slow client detected " ++ show pid ++ " diff " ++ (show (cI - cO - s))
                    killThread pid
                    void $! getChanContents duplicate
                    killThread =<< myThreadId
                    return ()
                threadDelay 5000000
        birst <- liftIO $ S.fromByteString =<< getAll buf'
        getMeta <- return <$> getD radio :: Application (IO (Maybe Meta))
        withMeta <- liftIO $ insertMeta (Just 8192) getMeta =<< S.concatInputStreams [birst, input]
        liftIO $ S.concatInputStreams [okResponse, withMeta]
    notConnected = do
        say "channel not connected, try create stream"
        let tryConnect :: Int -> Application (InputStream ByteString, Bool)
            tryConnect i | i < 3 = do 
                say "tryConnect"
                inputS <- try $ agent radio :: Application (Either SomeException (InputStream ByteString))
                case inputS of
                     Left _ -> do
                         setD radio (Nothing :: Maybe (Chan (Maybe ByteString)))
                         liftIO $ threadDelay 1000000
                         tryConnect (i + 1)
                     Right iS -> do
                         return $! (iS, True)
                         | otherwise = do
                             iS <- liftIO $ S.fromByteString "ICY 423 Locked\r\n"
                             return $! (iS, False)
        (inputStream, isGood) <- tryConnect 0
        if isGood 
           then do
               state <- ask
               let saveMeta :: Maybe Meta -> IO ()
                   saveMeta x = runReaderT (setD radio x) state
               chan <- liftIO newChan
               buf' <- liftIO $ new 20 :: Application (Buffer ByteString)
               setD radio (Just buf')
               metaInt <- unpackMeta <$> (lookupHeader "icy-metaint" <$> getD radio) :: Application (Maybe Int)
               chanStreamOutput <- liftIO $ S.chanToOutput chan
               (chanStreamInput, countInputBytes) <- liftIO $ S.countInput =<< S.chanToInput chan
               setD radio countInputBytes
               outputBuffer <- liftIO $ outputStreamFromBuffer buf'
               (p1, p2) <- liftIO $ connectWithRemoveMetaAndBuffering metaInt saveMeta 8192 inputStream chanStreamOutput
               p3 <- liftIO $ forkIO $ S.connect chanStreamInput outputBuffer
               setD radio $ Status 0 (Just p1) (Just p2) (Just p3) []
               setD radio (Just chan :: Maybe (Chan (Maybe ByteString)))
               haveChannel chan
           else liftIO $ S.map Builder.fromByteString inputStream
        
    
unpackMeta :: [ByteString] -> Maybe Int
unpackMeta meta' = do
    m <- listToMaybe meta'
    (a,_) <- C.readInt m
    return a
                   
    
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

-- | Parse stream, remove meta info from stream, bufferize, save meta info in state
connectWithRemoveMetaAndBuffering ::Maybe Int                -- ^meta int
                                  -> (Maybe Meta -> IO ())     -- ^save meta info to state
                                  -> Int                      -- ^buffer size
                                  -> InputStream ByteString   -- ^input stream
                                  -> OutputStream ByteString  -- ^output stream
                                  -> IO (ThreadId, ThreadId)  -- ^return pids
connectWithRemoveMetaAndBuffering Nothing _ buffSize is os = do
    builder <- S.builderStreamWith (allNewBuffersStrategy buffSize) os
    ps <- S.parserToInputStream (toBuilder bUFSIZ) is
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
toBuilder :: Int -> A.Parser (Maybe Builder)
toBuilder i = (A.endOfInput >> pure Nothing) <|> Just . Builder.fromByteString <$> A.take i

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

insertMeta :: Maybe Int -> IO (Maybe Meta) -> InputStream ByteString -> IO (InputStream Builder)
insertMeta Nothing _ is = S.map Builder.fromByteString is
insertMeta (Just metaInt) getMeta is = do
    chunked <- S.parserToInputStream (toBuilder metaInt) is
    metas   <- S.makeInputStream $ do
        m <- getMeta
        return $ Just $ maybe (Meta ("", 0)) id m
    refMeta <- newIORef $ Just (Meta ("", 0))
    withMeta <- S.zipWithM (fun refMeta) chunked metas
    ref <- newIORef 0
    return withMeta
    where
    fun:: IORef (Maybe Meta) -> Builder -> Meta -> IO Builder
    fun ref bs (Meta (meta', len)) = do
        result <- atomicModifyIORef ref (check meta' len)
        return $ if result
           then bs <> fromLen len <> Builder.fromByteString meta'
           else bs <> zero
    check :: ByteString -> Int -> Maybe Meta -> (Maybe Meta, Bool)
    check _ _ Nothing = (Nothing, False)
    check bs nl (Just (Meta (m, l))) =
      if bs == m
         then (Just (Meta (m,l)), False)
         else (Just (Meta (bs,nl)), True)

    fromLen :: Int -> Builder
    fromLen x = (Builder.fromWord8 . fromIntegral) $ truncate $ (fromIntegral x / 16)

    zero :: Builder
    zero = Builder.fromWord8 $ toEnum 0
    
-- | make stream from buffer
outputStreamFromBuffer :: Buffer ByteString -> IO (OutputStream ByteString)
outputStreamFromBuffer buf' = makeOutputStream f
   where
   f Nothing = return $! ()
   f (Just x) = update x buf'
{-# INLINE outputStreamFromBuffer #-}

portM :: String -> String
portM "" = "80"
portM x = tail x

-- | create stream
agent :: Radio -> Application (InputStream ByteString)
agent radio = agent' =<< (getD radio :: Application Radio)
  where
  agent' :: Radio -> Application (InputStream ByteString)
  -- proxy stream
  agent' radio@Proxy{} = do
      say "make proxy stream"
      (i, o) <- openConnection radio
      let path = C.pack . uriPath . url $ radio
          req = "GET " <> path <> " HTTP/1.0\r\nicy-metadata: 1\r\n\r\n"
      say "url from radio"
      say $ show $ url radio
      say "request to server"
      say $ show req
      requestStream <- liftIO $ S.fromByteString req
      liftIO $ S.connect requestStream o
      (response', headers') <- liftIO $ S.parseFromStream response i
      --  @TODO обработать исключения
      setD radio headers'
      say $ show response'
      say $ show headers'
      return i
      where
        -- | открываем соединение до стрим сервера
        openConnection :: Radio -> Application (InputStream ByteString, OutputStream ByteString)
        openConnection radio = do
            let host = uriRegName <$> (uriAuthority $ url radio)
                port = portM . uriPort <$> (uriAuthority $ url radio)
            say $ show host
            say $ show port
            is <- liftIO $ getAddrInfo (Just hints) host port
            let addr = head is
            let a = addrAddress addr
            s <- liftIO $  socket (addrFamily addr) Stream defaultProtocol
            liftIO $ Network.Socket.connect s a
            (i,o) <- liftIO $ S.socketToStreams s
            return (i, o)
            where
               hints = defaultHints {addrFlags = [AI_ADDRCONFIG, AI_NUMERICSERV]}

  -- local stream
  agent' radio@Local{} = do
      say "make local stream"
      reader <- ask
      handleIO <- liftIO $ newIORef Nothing
      liftIO $ makeInputStream $ f reader handleIO
      where
        getNextSong :: Application (Maybe FilePath)
        getNextSong = do
            playlist <- getD radio :: Application (Maybe Playlist)
            let file = uri . getValue <$> playlist
                RadioId channelDir = rid radio
            case uriScheme <$> file of
               Just "file:" -> checkFile (fromJust playlist) =<< localFile channelDir (uriPath . fromJust $ file) 
               Just "http:" -> checkFile (fromJust playlist) =<< localFile channelDir (uriToFileName . fromJust $ file) 
               _ -> return Nothing
               
        checkFile ::Playlist -> FilePath -> Application (Maybe FilePath)
        checkFile playlist file = maybe (bad playlist) (ok playlist file) =<< fst <$> (liftIO $ getAudio file)
        
        ok playlist file _ = do
            setD radio (Just $ goRight playlist)
            return $ Just file
            
        bad playlist = do
            let newPlaylist = Collections.tail playlist
            if Collections.null newPlaylist
               then return Nothing
               else do
                   setD radio (Just newPlaylist)
                   getNextSong

        localFile :: ByteString -> String -> Application String
        localFile channelDir fileName = do
            dataDir <- liftIO getDataDir
            return $ concat $ [dataDir, musicDirectory, (tail $ C.unpack channelDir), fileName]
            
        f:: Store -> IORef (Maybe (InputStream BS.ByteString)) -> IO (Maybe BS.ByteString)
        f reader channelIO = do
            maybeCh <- readIORef channelIO
            file <- runReaderT getNextSong reader
            case (maybeCh, file) of
                 (Nothing, Nothing) -> do
                     say "empty playlist"
                     return Nothing
                 (Nothing, Just file') -> do
                     say $ show file
                     --  channel <-  runFFmpeg file'
                     channel <- ratedStream file'
                     writeIORef channelIO $ Just channel
                     f reader channelIO
                 (Just ch, _) -> do
                     !chunk <- S.read ch
                     case chunk of
                          Just c -> return $! Just c
                          Nothing -> do
                              writeIORef channelIO Nothing
                              f reader channelIO

uriToFileName :: URI -> String
uriToFileName uri = let regName = uriRegName . fromJust $ uriAuthority uri
                        pathName = uriPath uri
                        fullName = regName ++ pathName
                    in Prelude.show $ hash fullName
                    
kill :: MProcess -> IO ()
kill (Just x) = killThread x
kill Nothing = return ()
        
saveClientPid :: Allowed m => ThreadId -> Radio -> m ()
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

removeClientPid :: Allowed m => ThreadId -> Radio -> m ()
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
        isLast <- liftIO $ case (r, newConnections == 0) of
             (Proxy{..}, True) -> do
                 say "last user go away"
                 say "kill proxy radio channel"
                 kill $ connectProcess oldStatus
                 kill $ chanProcess oldStatus
                 kill $ bufferProcess oldStatus
                 return True
             _ -> return False
        return $ if isLast 
                    then r { pid = newStatus, channel = Nothing, buff = Nothing }
                    else r { pid = newStatus }
           

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
           then return (False, error "Internal.create: Nothing here")
           else do
               mv <- liftIO $ newMVar withPort
               liftIO $ modifyMVar_ x $ \mi -> return $ Map.insert (rid r) mv mi
               return (True, withPort)
    remove r = do
        (Store x _) <- ask
        is <- member r
        say $ "remove channel" ++ show r ++ show is
        if is
           then do
               Status{..} <- getD r :: Allowed m => m Status
               M.mapM_ (liftIO . killThread) connectionsProcesses
               wait (getD r) 
               liftIO $ do
                   say "remove radio channel"
                   kill connectProcess
                   kill chanProcess
                   kill bufferProcess
                   modifyMVar_ x $ \mi -> return $ Map.delete (rid r) mi
               return True
           else return False
        where
        wait :: Allowed m => m Status -> m ()
        wait s = do
            Status{..} <- s
            case connectionsProcesses of
                 [] -> return ()
                 _ -> (liftIO $ threadDelay 200000) >> wait s 
    list = do
        (Store x _) <- ask
        liftIO $ withMVar x fromMVar
        where
          fromMVar :: Map RadioId (MVar Radio) -> IO [Radio]
          fromMVar y = Prelude.mapM (\(_, mv) -> withMVar mv return) $ Map.toList y
    info a = do
        (Store x _) <- ask
        r <- liftIO $ withMVar x $ \y -> return $ Map.lookup (rid a) y
        case r of
             Just x -> return x
             Nothing -> error "Internal.info Its imposible."
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
    setD = error "Internal.setD: Its imposible"

instance Allowed m => Detalization m URI where
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


