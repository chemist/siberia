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

import           BasicPrelude
import           Control.Concurrent                       hiding (yield)
import qualified Data.Map                                 as Map
import           Prelude                                  ()
import qualified Prelude

import           Data.Attoparsec                          (parseOnly)
import           Data.Attoparsec.RFC2616
import qualified Data.Attoparsec as A
import qualified Data.ByteString                          as BS
import qualified Data.ByteString.Char8                    as C
import qualified Data.ByteString.Lazy                     as LS
import           Data.Maybe                               (fromJust)
import           Network.Socket
import           System.IO.Streams                        as S
import           System.IO.Streams.Attoparsec             as S
import           System.IO.Streams.Concurrent             as S

import           Control.Monad.Reader
import qualified Control.Monad.Reader                     as R

import           Blaze.ByteString.Builder                 (Builder)
import qualified Blaze.ByteString.Builder                 as Builder
import           Blaze.ByteString.Builder.Internal.Buffer
                                                           (allNewBuffersStrategy)
import           Data.Binary                              (encode, decode)
import qualified Data.Collections                         as Collections
import           Data.Cycle
import           Data.IORef
import           Data.Text.Encoding                       as E
import           Radio.Data
import Control.Applicative hiding (empty)

say :: (Show a, MonadIO m) => a -> m ()
say = liftIO . print

save :: Allowed m => Prelude.FilePath -> m ()
save path = do
    l <- list :: Allowed m => m [Radio]
    liftIO $ LS.writeFile path $ encode l

load :: Allowed m => Prelude.FilePath -> m ()
load path = do
    l <- liftIO $ LS.readFile path
    R.mapM_ create $ (decode l :: [Radio])
    return ()

-- | создаем канал
makeChannel::Radio -> Application ()
makeChannel radio = do
    say "start make channel"
    radioStreamInput <- try $ makeConnect radio :: Application (Either SomeException (InputStream ByteString))
    either whenError whenGood radioStreamInput
    where
      whenError x = do
          say $ "Error when connection: " ++ show x
          set radio $ (Nothing :: Maybe (Chan (Maybe ByteString)))
      whenGood radioStreamInput' = do
          say "start good"
          state <- ask
          let saveMeta :: Maybe Meta -> IO ()
              saveMeta x = runReaderT (set radio x) state
          chan <- liftIO $ newChan
          buf' <- liftIO $ new 60 :: Application (Buffer ByteString)
          set radio (Just buf')
          metaInt <- unpackMeta <$> (lookupHeader "icy-metaint" <$> get radio) :: Application (Maybe Int)
          say "have meta int"
          say metaInt
          chanStreamOutput <- liftIO $ S.chanToOutput chan
          chanStreamInput  <- liftIO $ S.chanToInput  chan
          outputBuffer <- liftIO $ bufferToOutput buf'
          say "have output buffer"
--          void . liftIO $ forkIO $ connectWithRemoveMetaAndBuffering metaInt saveMeta  8192 radioStreamInput'  chanStreamOutput
          liftIO $ connectWithRemoveMetaAndBuffering metaInt saveMeta 8192 radioStreamInput' chanStreamOutput
          void . liftIO $ forkIO $ S.connect chanStreamInput outputBuffer
          set radio $ (Just chan :: Maybe (Chan (Maybe ByteString)))
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
    let strategy = allNewBuffersStrategy buffSize
    builder <- S.builderStreamWith strategy os
    ps <- S.parserToInputStream toBuilder is
    x <- forkIO $ S.connect ps builder
    return (x,x)
connectWithRemoveMetaAndBuffering (Just metaInt) saveMeta buffSize is os = do
    let strategy = allNewBuffersStrategy buffSize
    builder <- S.builderStreamWith strategy os
    parsed <- S.parserToInputStream (metaParser metaInt) is
    (isb, ism) <- S.unzip parsed
    osm <- S.makeOutputStream saveMeta
    x <- forkIO $ S.connect isb builder
    y <- forkIO $ S.connect ism osm
    return (x,y)
{-# INLINE connectWithRemoveMetaAndBuffering #-}

toBuilder :: A.Parser (Maybe Builder)
toBuilder = (A.endOfInput >> pure Nothing) <|> Just <$> (A.take 4096 >>= return . Builder.fromByteString)

metaParser :: Int -> A.Parser (Maybe (Builder, Meta))
metaParser metaInt = (A.endOfInput >> pure Nothing) <|> Just <$> do
    body <- A.take metaInt
    len <- toLen <$> A.take 1 
    meta <- A.take len
    return (Builder.fromByteString body, Meta (meta, len))

toLen :: ByteString -> Int
toLen x = let [w] = BS.unpack x
          in 16 * fromIntegral w


connectWithAddMetaAndBuffering :: Maybe Int   -- ^ meta int
                               ->  IO (Maybe Meta) -- ^ получить мета информацию
                               ->  Int   -- ^ размер буфера
                               ->  InputStream ByteString
                               ->  OutputStream ByteString
                               ->  IO ()
connectWithAddMetaAndBuffering Nothing _ buffSize is os = do
    let strategy = allNewBuffersStrategy buffSize
    builder <- S.builderStreamWith strategy os
    loop builder
    where
    loop builder = do
        !m <- S.read is
        maybe (S.write Nothing builder) writeChunks m
        where 
        writeChunks :: ByteString -> IO ()
        writeChunks bs = S.write (Just $ Builder.fromByteString bs) builder >> loop builder
        
connectWithAddMetaAndBuffering (Just metaInt) getMeta buffSize is os = do
    let strategy = allNewBuffersStrategy buffSize
    builder <- S.builderStreamWith strategy os
    loop builder metaInt metaInt ""
    where
    fromLen :: Int -> ByteString
    fromLen x = (BS.singleton . fromIntegral) $ truncate $ (fromIntegral x / 16)
    
    zero :: ByteString
    zero = BS.pack $ [toEnum 0]

    loop builder metaInt' whereNextMetaInt oldMeta = do
        !m <- S.read is
        maybe (S.write Nothing builder) (writeChunks whereNextMetaInt oldMeta) m
        where  
        sendBS :: ByteString -> IO ()
        sendBS bs = S.write (Just $ Builder.fromByteString bs) builder

        writeChunks :: Int -> ByteString -> ByteString -> IO ()
        writeChunks nextMeta oldMeta' bs = do
            meta' <- getMeta
            case (nextMeta >= BS.length bs, meta') of
                 -- | чанк маленький, уходим выше за новым чанком
                 (True, _) -> do
                     sendBS bs
                     loop builder metaInt' (nextMeta - BS.length bs) oldMeta'
                 -- | чанк большой, meta info отсутствует, шлем zero каждый metaInt
                 (False, Nothing) -> do
                     let (from, to) = BS.splitAt nextMeta bs
                     sendBS from
                     writeChunks (metaInt' + 1) oldMeta' $ mconcat [zero, to]
                 (False, Just (Meta (meta'', metaSize))) -> do
                     let (from, to) = BS.splitAt nextMeta bs
                     sendBS from
                     if meta'' /= oldMeta'
                        then do
                            print $ "insert meta with size " ++  show metaSize
                            print $ "meta " ++ meta''
                            writeChunks (metaInt' + 1 + BS.length meta'')  meta'' $ mconcat [fromLen metaSize, meta'', to]
                        else do
                            writeChunks (metaInt' + 1) oldMeta' $ mconcat [zero, to]
{-# INLINE connectWithAddMetaAndBuffering #-}


bufferToOutput :: Buffer ByteString -> IO (OutputStream ByteString)
bufferToOutput buf' = makeOutputStream f
   where
   f Nothing = return $! ()
   f (Just x) = update x buf'
{-# INLINE bufferToOutput #-}

-- | создаем соединение до стрим сервера
makeConnect :: Radio -> Application (InputStream ByteString)
makeConnect (ById (RadioId "/test")) = do
    i <- liftIO $ fakeInputStream
    say "test radio stream"
    say "test radio stream"
    say "test radio stream"
    say "test radio stream"
    return i
makeConnect radio = do
   (i, o) <- openConnection radio
   Url u <- get radio
   let Right path = parseOnly parsePath u
       req = mconcat ["GET ", path, " HTTP/1.0\r\nicy-metadata: 1\r\n\r\n"]
   say "url from radio"
   say u
   say "request to server"
   say req
   getStream <- liftIO $ S.fromByteString req
   liftIO $ S.connect getStream o
   (response', headers') <- liftIO $ S.parseFromStream response i
   -- | @TODO обработать исключения
   set radio headers'
   say response'
   say headers'
   say "makeConnect end"
   return i


fakeRadioStream' :: [ByteString]
fakeRadioStream' = BasicPrelude.map (\x -> mconcat [(E.encodeUtf8 . show) x , " "]) [1.. ]

fakeInputStream :: IO (S.InputStream ByteString)
fakeInputStream = S.fromGenerator $ genStream fakeRadioStream'

genStream :: [ByteString] -> S.Generator ByteString ()
genStream x = do
    let (start, stop) = splitAt 1024 x
    S.yield $ mconcat start
    liftIO $ threadDelay 100000
    genStream stop


-- | открываем соединение до стрим сервера
openConnection :: Radio -> Application (InputStream ByteString, OutputStream ByteString)
openConnection radio = do
    Url url' <- get radio
    let Right (hb, pb) = parseOnly parseUrl url'
        h = C.unpack hb
        p = C.unpack pb
    say h
    say p
    is <- liftIO $ getAddrInfo (Just hints) (Just h) (Just p)
    let addr = head is
    let a = addrAddress addr
    s <- liftIO $  socket (addrFamily addr) Stream defaultProtocol
    liftIO $ Network.Socket.connect s a
    (i,o) <- liftIO $ S.socketToStreams s
    return (i, o)
    where
       hints = defaultHints {addrFlags = [AI_ADDRCONFIG, AI_NUMERICSERV]}

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
        (Store x _) <- ask
        liftIO $ withMVar x $ \y -> return $ (rid r) `Map.member` y
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
    -- | @TODO catch exception
    --



addHostPort::HostPort -> Radio -> Radio
addHostPort hp x = x { hostPort = hp }

-- | helpers
getter ::(Radio -> a) -> MVar Radio -> IO a
getter x y =  flip  withMVar (return . x)  y

setter :: (Radio -> Radio) -> MVar Radio -> IO ()
setter x y =  flip modifyMVar_ (return . x)  y

instance Allowed m => Detalization m Url where
    get radio = info radio >>= liftIO . getter url
    set radio a = info radio >>= liftIO . setter (\y -> y { url = a })

instance Allowed m => Detalization m Headers where
    get radio = info radio >>= liftIO . getter headers
    set radio a = info radio >>= liftIO . setter (\y -> y { headers = a })

instance Allowed m => Detalization m Channel where
    get radio = info radio >>= liftIO . getter channel
    set radio a = info radio >>= liftIO . setter (\y -> y { channel = a })

instance Allowed m => Detalization m (Maybe Meta) where
    get radio = info radio >>= liftIO . getter meta
    set radio (Just (Meta ("",0))) = return ()
    set radio a = info radio >>= liftIO . setter (\y -> y { meta = a })

instance Allowed m => Detalization m (Maybe (Buffer ByteString)) where
    get radio = info radio >>= liftIO . getter buff
    set radio a = info radio >>= liftIO . setter (\y -> y { buff = a})


