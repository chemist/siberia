{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TypeSynonymInstances   #-}
module Radio.Internal (
  module Radio.Data
  , makeChannel
  , load
  , save
  , say
  , connectWithRemoveMetaAndBuffering
  , connectWithAddMetaAndBuffering
  ) where

import           BasicPrelude                             hiding (FilePath, Map, 
                                                           appendFile)
import           Control.Concurrent                       hiding (yield)
import qualified Data.Map.Lazy                                 as Map
import Data.Map (Map)
import           Prelude                                  (FilePath)
import qualified Prelude

import           Data.Attoparsec                          (parseOnly)
import qualified Data.Attoparsec                          as A
import           Data.Attoparsec.RFC2616
import qualified Data.ByteString                          as BS
import qualified Data.ByteString.Char8                    as C
import qualified Data.ByteString.Lazy                     as LS
import           Data.Maybe                               (fromJust)
import           Network.Socket
import           System.IO.Streams                        as S
import           System.IO.Streams.Attoparsec             as S
import           System.IO.Streams.Combinators            as S
import           System.IO.Streams.Concurrent             as S

import           Control.Monad.RWS.Lazy
import qualified Control.Monad.RWS.Lazy                   as M

import           Blaze.ByteString.Builder                 (Builder)
import qualified Blaze.ByteString.Builder                 as Builder
import           Blaze.ByteString.Builder.Internal.Buffer (allNewBuffersStrategy)
import           Control.Applicative                      hiding (empty)
import           Data.Binary                              (decode, encode)
import qualified Data.Collections                         as Collections
import           Data.Cycle
import           Data.IORef
import           Data.Text.Encoding                       as E
import           Data.Text.IO                             (appendFile)
import           Debug.Trace
import           Radio.Data
import           System.IO                                (Handle, IOMode (..),
                                                           hClose,
                                                           openBinaryFile)
import qualified System.Process                           as P
import Paths_siberia

say x = tell . Logger $ x ++ "\n"

save :: Allowed m => Prelude.FilePath -> m ()
save path = do
    l <- list :: Allowed m => m [Radio]
    say "save radio station"
    M.mapM_ (\x -> say $ show x ) l
    liftIO $ LS.writeFile path $ encode l

load :: Allowed m => Prelude.FilePath -> m ()
load path = do
    l <- liftIO $ LS.readFile path
    let radio  = decode l :: [Radio]
    say "load next radio station"
    M.mapM_ (\x -> say $ show x) radio
    _ <- M.mapM_ create radio
    return ()


-- | создаем канал
makeChannel::Radio -> Application ()
makeChannel radio = do
    say "start make channel"
    radioStreamInput <- try $ getStream radio :: Application (Either SomeException (InputStream ByteString))
    either whenError whenGood radioStreamInput
    where
      whenError x = do
          say $ "Error when connection: " ++ show x
          setD radio $ (Nothing :: Maybe (Chan (Maybe ByteString)))
      whenGood radioStreamInput' = do
          say "start good"
          stateR <- ask
          stateS <- get
          let saveMeta :: Maybe Meta -> IO ()
              saveMeta x = do (_, _, Logger w) <- runRWST (setD radio x) stateR stateS
                              dataDir <- getDataDir
                              appendFile (dataDir <> logFile) w
          chan <- liftIO $ newChan
          buf' <- liftIO $ new 60 :: Application (Buffer ByteString)
          setD radio (Just buf')
          metaInt <- unpackMeta <$> (lookupHeader "icy-metaint" <$> getD radio) :: Application (Maybe Int)
          say "have meta int"
          say $ show metaInt
          chanStreamOutput <- liftIO $ S.chanToOutput chan
          chanStreamInput  <- liftIO $ S.chanToInput  chan
          outputBuffer <- liftIO $ bufferToOutput buf'
          say "have output buffer"
          (p1,p2) <- liftIO $ connectWithRemoveMetaAndBuffering metaInt saveMeta 8192 radioStreamInput' chanStreamOutput
          p3 <-  liftIO $ forkIO $ S.connect chanStreamInput outputBuffer
          setD radio $ Status 0 (Just p1) (Just p2) (Just p3) []
          setD radio (Just chan :: Maybe (Chan (Maybe ByteString)))
          say "finish output buffer"
          -- | @TODO save pid
          return ()
      unpackMeta :: [ByteString] -> Maybe Int
      unpackMeta meta' = do
          m <- listToMaybe meta'
          (a,_) <- C.readInt m
          return a

connectWithRemoveMetaAndBuffering ::Maybe Int                -- ^ meta int
                                  -> (Maybe Meta -> IO ())   -- ^ запись мета информации в состояние
                                  -> Int                      -- ^ размер чанка для буферизированного вывода
                                  -> InputStream ByteString   -- ^ входной поток
                                  -> OutputStream ByteString  -- ^ выходной поток
                                  -> IO (ThreadId, ThreadId)
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

toBuilder :: A.Parser (Maybe Builder)
toBuilder = (A.endOfInput >> pure Nothing) <|> Just . Builder.fromByteString <$> A.take 32752

metaParser :: Int -> A.Parser (Maybe (Builder, Meta))
metaParser metaInt = (A.endOfInput >> pure Nothing) <|> Just <$> do
    body <- A.take metaInt
    len <- toLen <$> A.take 1
    meta <- A.take len
    return (Builder.fromByteString body, Meta (meta, len))

toLen :: ByteString -> Int
toLen x = let [w] = BS.unpack x
          in 16 * fromIntegral w

newtype Chunk = Chunk ByteString

toChunks :: Int -> A.Parser (Maybe Chunk)
toChunks metaInt = (A.endOfInput >> pure Nothing) <|> Just . Chunk <$> A.take metaInt

connectWithAddMetaAndBuffering :: Maybe Int       -- ^ meta int
                               ->  IO (Maybe Meta) -- ^ получить мета информацию
                               ->  Int             -- ^ размер буфера
                               ->  InputStream ByteString
                               ->  OutputStream ByteString
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
    zero = BS.pack $ [toEnum 0]

{-# INLINE connectWithAddMetaAndBuffering #-}


bufferToOutput :: Buffer ByteString -> IO (OutputStream ByteString)
bufferToOutput buf' = makeOutputStream f
   where
   f Nothing = return $! ()
   f (Just x) = update x buf'
{-# INLINE bufferToOutput #-}

getStream :: Radio -> Application (InputStream ByteString)
getStream radio = getStream' =<< (getD radio :: Application (RadioInfo RadioId))

getStream' :: Radio -> Application (InputStream ByteString)
-- * тестовый поток
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

-- * proxy поток
getStream' radio@Proxy{} = do
    (i, o) <- openConnection radio
    let Url url' = url radio
    let Right path = parseOnly parsePath url'
        req = "GET " <> path <> " HTTP/1.0\r\nicy-metadata: 1\r\n\r\n"
    say "url from radio"
    say $ show url'
    say "request to server"
    say $ show req
    getStream <- liftIO $ S.fromByteString req
    liftIO $ S.connect getStream o
    (response', headers') <- liftIO $ S.parseFromStream response i
    -- | @TODO обработать исключения
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

-- * поток с локальных файлов
getStream' radio@Local{} = do
    state <- get
    reader <- ask
    handleIO <- liftIO $ newIORef Nothing
    liftIO $ makeInputStream $ f state reader handleIO
    where
      getNextSong :: Application (Maybe FilePath)
      getNextSong = do
          playList' <- getD radio :: Application (Maybe Playlist)
          let sfile = spath . getValue <$> playList'
              newPlayList = goRight <$> playList'
              RadioId channelDir = rid radio
          setD radio newPlayList
          dataDir <- liftIO $ getDataDir
          return $ (<$>) concat $ sequence [pure dataDir, pure musicDirectory, pure (tail $ C.unpack channelDir), pure "/", sfile]
      f:: State -> RadioStore -> IORef (Maybe (InputStream BS.ByteString)) -> IO (Maybe BS.ByteString)
      f state reader channelIO = do
          maybeCh <- readIORef channelIO
          case maybeCh of
               Nothing -> do
                   (file, _) <- evalRWST getNextSong reader state
                   case file of
                        Nothing -> do
                            print "empty playlist"
                            return Nothing
                        Just file' -> do
                            print file
                            channel <- runFFmpeg file'
                            writeIORef channelIO $ Just channel
                            f state reader channelIO
               Just ch -> do
                   !chunk <- S.read ch
                   case chunk of
                        Just c -> return $! Just c
                        Nothing -> do
                            writeIORef channelIO Nothing
                            f state reader channelIO
                                     
bUFSIZ = 32752

command :: String
command = "ffmpeg -re -i - -f mp3 -acodec copy -"


runFFmpeg ::String ->  IO (S.InputStream BS.ByteString)
runFFmpeg filename = do
    (i, o, e, ph ) <- S.runInteractiveCommand command
    forkIO $ do nullOutput <- S.nullOutput
                S.withFileAsInput filename (fun i)
                S.connect e nullOutput
                exitCode <- P.waitForProcess ph
                print exitCode
                print "next song"
    return o
    where fun :: S.OutputStream BS.ByteString -> S.InputStream BS.ByteString -> IO ()
          fun os is = S.connect is os




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
        modifyIORef (nthValue (getValue position) buf') $ \_ -> x
        return ()
    getAll x = do
        s <- bufSize x
        position <- readIORef $ active x
        buf' <- readIORef $ buf x
        let res = takeLR s $ goLR (1 + getValue position) buf'
        mconcat <$> Prelude.mapM (\y -> readIORef y) res

instance Allowed m => Storable m Radio where
    member (ById (RadioId "/test")) = return True
    member r = do
        (Store x _ _) <- ask
        liftIO $ withMVar x $ \y -> return $ (rid r) `Map.member` y
    create r = do
        (Store x hp _) <- ask
        let withPort = addHostPort hp r
        is <- member r
        if is
           then return (False, undefined)
           else do
               mv <- liftIO $ newMVar withPort
               liftIO $ modifyMVar_ x $ \mi -> return $ Map.insert (rid r) mv mi
               return (True, withPort)
    remove r = do
        (Store x _ _) <- ask
        is <- member r
        if is
           then do
               liftIO $ modifyMVar_ x $ \mi -> return $ Map.delete (rid r) mi
               return True
           else return False
    list = do
        (Store x _ _) <- ask
        liftIO $ withMVar x fromMVar
        where
          fromMVar :: Map RadioId (MVar Radio) -> IO [Radio]
          fromMVar y = Prelude.mapM (\(_, mv) -> withMVar mv return) $ Map.toList y
    info a = do
        (Store x _ _) <- ask
        liftIO $ withMVar x $ \y -> return $ fromJust $ Map.lookup (rid a) y
    -- | @TODO catch exception
    


addHostPort::HostPort -> Radio -> Radio
addHostPort hp x = x { hostPort = hp }

-- | helpers
getter ::(Radio -> a) -> MVar Radio -> IO a
getter x =  flip  withMVar (return . x)

setter :: (Radio -> Radio) -> MVar Radio -> IO ()
setter x  =  flip modifyMVar_ (return . x)

instance Allowed m => Detalization m (RadioInfo RadioId) where
    getD radio = do
        i <- info radio 
        liftIO $ withMVar i $ \x -> return x
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
    setD radio (Just (Meta ("",0))) = return ()
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



