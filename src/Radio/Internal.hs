{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TypeSynonymInstances   #-}
module Radio.Internal (module Radio.Data, getMetaInfo, makeChannel, load, save, connectWithRemoveMetaAndBuffering, connectWithAddMetaAndBuffering) where

import           BasicPrelude
import           Control.Concurrent                       hiding (yield)
import qualified Data.Map                                 as Map
import           Prelude                                  ()
import qualified Prelude

import           Data.Attoparsec                          (parseOnly)
import           Data.Attoparsec.RFC2616
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
import           Data.Binary
import qualified Data.Collections                         as Collections
import           Data.Cycle
import           Data.IORef
import           Data.Text.Encoding                       as E
import           Radio.Data
import qualified Radio.Data                               as D

save :: D.Allowed m => Prelude.FilePath -> m ()
save path = do
    l <- D.list :: D.Allowed m => m [D.Radio]
    liftIO $ LS.writeFile path $ encode l

load :: D.Allowed m => Prelude.FilePath -> m ()
load path = do
    l <- liftIO $ LS.readFile path
    R.mapM_ D.create $ (decode l :: [D.Radio])
    return ()

-- | создаем канал
makeChannel::D.Radio -> D.Application ()
makeChannel radio = do
    liftIO $ print "start make channel"
    radioStreamInput <- try $ makeConnect radio :: D.Application (Either SomeException (InputStream ByteString))
    either whenError whenGood radioStreamInput
    where
      whenError x = do
          liftIO $ print $ "Error when connection: " ++ show x
          D.set radio $ (Nothing :: Maybe (Chan (Maybe ByteString)))
      whenGood radioStreamInput' = do
          liftIO $ print "start good"
          state <- ask
          let saveMeta :: Maybe D.Meta -> IO ()
              saveMeta x = runReaderT (D.set radio x) state
          chan <- liftIO $ newChan
          buf' <- liftIO $ D.new 100 :: D.Application (D.Buffer ByteString)
          D.set radio (Just buf')
          metaInt <- unpackMeta <$> (lookupHeader "icy-metaint" <$> D.get radio) :: D.Application (Maybe Int)
          liftIO $ print "have meta int"
          liftIO $ print metaInt
          chanStreamOutput <- liftIO $ S.chanToOutput chan
          chanStreamInput  <- liftIO $ S.chanToInput  chan
          outputBuffer <- liftIO $ bufferToOutput buf'
          liftIO $ print "have output buffer"
          void . liftIO $ forkIO $ connectWithRemoveMetaAndBuffering metaInt saveMeta  4096 radioStreamInput'  chanStreamOutput
          void . liftIO $ forkIO $ S.connect chanStreamInput outputBuffer
          D.set radio $ (Just chan :: Maybe (Chan (Maybe ByteString)))
          -- | @TODO save pid
          return ()
      unpackMeta :: [ByteString] -> Maybe Int
      unpackMeta meta' = do
          m <- listToMaybe meta'
          (a,_) <- C.readInt m
          return a

connectWithRemoveMetaAndBuffering ::Maybe Int                -- ^ meta int
                                  -> (Maybe D.Meta -> IO ())   -- ^ запись мета информации в состояние
                                  -> Int                      -- ^ размер чанка для буферизированного вывода
                                  -> InputStream ByteString   -- ^ входной поток
                                  -> OutputStream ByteString  -- ^ выходной поток
                                  -> IO ()
connectWithRemoveMetaAndBuffering Nothing _ buffSize is os = do
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
        
connectWithRemoveMetaAndBuffering (Just metaInt) saveMeta buffSize is os = do
    let strategy = allNewBuffersStrategy buffSize
    builder <- S.builderStreamWith strategy os
    loop builder metaInt metaInt
    where
    loop builder metaInt' whereNextMeta = do
        !m <- S.read is
        maybe (S.write Nothing builder) (writeChunks whereNextMeta) m
        where
        writeChunks :: Int -> ByteString -> IO ()
        writeChunks nextMeta bs = 
          let sendBS :: ByteString -> IO ()
              sendBS bs = S.write (Just $ Builder.fromByteString bs) builder
          in if nextMeta >= BS.length bs
             then do
                 sendBS bs
                 loop builder metaInt (nextMeta - BS.length bs)
             else do
                 let (from, to) = BS.splitAt nextMeta bs
                     metaSize = toLen $ BS.take 1 to
                     meta' = BS.take metaSize $ BS.tail to
                     to'  = BS.drop metaSize $ BS.tail to
                 sendBS from
                 when (metaSize /= 0) $ do
                     print "save meta"
                     print metaSize
                     saveMeta $ Just $ D.Meta (meta', metaSize)
                 writeChunks metaInt' to'
                 
{-# INLINE connectWithRemoveMetaAndBuffering #-}

-- | парсим мета информацию
getMetaInfo :: Int -> Int -> ByteString -> (ByteString, Int, ByteString, ByteString, Int)
getMetaInfo metaInt'' count bs =
  let (start, end) = BS.splitAt count bs
      metaSize = toLen $ BS.take 1 end
      meta' = BS.tail $ BS.take (metaSize + 1) end
      end' = BS.drop (metaSize + 1) end
      count' = metaInt'' - BS.length end'
  in (start, metaSize, meta', end', count')


toLen :: ByteString -> Int
toLen x = let [w] = BS.unpack x
          in 16 * fromIntegral w


connectWithAddMetaAndBuffering :: Maybe Int   -- ^ meta int
                               ->  IO (Maybe D.Meta) -- ^ получить мета информацию
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
            putStrLn ""
            case (nextMeta >= BS.length bs, meta') of
                 -- | чанк маленький, уходим выше за новым чанком
                 (True, _) -> do
                     let aaa = BS.take 1 bs
                     print $ "aaa in true  " ++ aaa
                     print $ show (nextMeta - BS.length bs)
                     sendBS bs
                     loop builder metaInt' (nextMeta - BS.length bs) oldMeta'
                 -- | чанк большой, meta info отсутствует, шлем zero каждый metaInt
--                 (False, Nothing) -> do
--                     let (from, to) = BS.splitAt nextMeta bs
--                     sendBS from
--                     sendBS zero
--                     writeChunks (metaInt' - 1) oldMeta' to
                 (False, Just (D.Meta (meta'', metaSize))) -> do
                     let (from, to) = BS.splitAt nextMeta bs
                         aaa = BS.take 1 from
                     print $ "aaa " ++ aaa
                     sendBS from
                     if meta'' /= oldMeta'
                        then do
                            print $ "insert meta with size " ++  show metaSize
                            print $ "meta " ++ meta''
                            writeChunks (metaInt' + 1) meta'' $ mconcat [fromLen metaSize, meta'', to]
                        else do
                            print "insert zero"
                            writeChunks (metaInt' + 1) oldMeta' $ mconcat [zero, to]
                     
{-# INLINE connectWithAddMetaAndBuffering #-}


bufferToOutput :: D.Buffer ByteString -> IO (OutputStream ByteString)
bufferToOutput buf' = makeOutputStream f
   where
   f Nothing = return $! ()
   f (Just x) = D.update x buf'
{-# INLINE bufferToOutput #-}

-- | создаем соединение до стрим сервера
makeConnect :: D.Radio -> D.Application (InputStream ByteString)
makeConnect (D.ById (D.RadioId "/test")) = do
    i <- liftIO $ fakeInputStream
    liftIO $ print "test radio stream"
    liftIO $ print "test radio stream"
    liftIO $ print "test radio stream"
    liftIO $ print "test radio stream"
    return i
makeConnect radio = do
   (i, o) <- openConnection radio
   D.Url u <- D.get radio
   let Right path = parseOnly parsePath u
       req = mconcat ["GET ", path, " HTTP/1.0\r\nicy-metadata: 1\r\n\r\n"]
   liftIO $ print "url from radio"
   liftIO $ print u
   liftIO $ print "request to server"
   liftIO $ print req
   getStream <- liftIO $ S.fromByteString req
   liftIO $ S.connect getStream o
   (response', headers') <- liftIO $ S.parseFromStream response i
   -- | @TODO обработать исключения
   D.set radio headers'
   liftIO $ print response'
   liftIO $ print headers'
   liftIO $ print "makeConnect end"
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
openConnection :: D.Radio -> D.Application (InputStream ByteString, OutputStream ByteString)
openConnection radio = do
    D.Url url' <- D.get radio
    let Right (hb, pb) = parseOnly parseUrl url'
        h = C.unpack hb
        p = C.unpack pb
    liftIO $ print h
    liftIO $ print p
    is <- liftIO $ getAddrInfo (Just hints) (Just h) (Just p)
    let addr = head is
    let a = addrAddress addr
    s <- liftIO $  socket (addrFamily addr) Stream defaultProtocol
    liftIO $ Network.Socket.connect s a
    (i,o) <- liftIO $ S.socketToStreams s
    return (i, o)
    where
       hints = defaultHints {addrFlags = [AI_ADDRCONFIG, AI_NUMERICSERV]}

instance Monoid a => D.RadioBuffer D.Buffer a where
    new n = do
        l <-  sequence $ replicate n (newIORef empty :: Monoid a => IO (IORef a))
        l' <- newIORef $ Collections.fromList l
        p <- newIORef $ Collections.fromList [1 .. n]
        s <- newIORef n
        return $ D.Buffer p l' s
    bufSize = readIORef . D.size
    current x = readIORef (D.active x) >>= return . getValue
    nextC   x = readIORef (D.active x) >>= return . rightValue
    lastBlock x = do
        position <- readIORef $ D.active x
        buf' <- readIORef $ D.buf x
        readIORef $ nthValue (getValue position) buf'
    update x y = do
        modifyIORef (D.active y) goRight
        position <- readIORef $ D.active y
        buf' <- readIORef $ D.buf y
        modifyIORef (nthValue (getValue position) buf') $ \_ -> x
        return ()
    getAll x = do
        s <- D.bufSize x
        position <- readIORef $ D.active x
        buf' <- readIORef $ D.buf x
        let res = takeLR s $ goLR (1 + getValue position) buf'
        mconcat <$> Prelude.mapM (\y -> readIORef y) res


instance D.Allowed m => D.Storable m D.Radio where
    member (D.ById (D.RadioId "/test")) = return True
    member r = do
        (D.Store x _) <- ask
        liftIO $ withMVar x $ \y -> return $ (D.rid r) `Map.member` y
    create r = do
        (D.Store x hp) <- ask
        let withPort = addHostPort hp r
        is <- D.member r
        if is
           then return (False, undefined)
           else do
               mv <- liftIO $ newMVar withPort
               liftIO $ modifyMVar_ x $ \mi -> return $ Map.insert (D.rid r) mv mi
               return (True, withPort)
    remove r = do
        (D.Store x _) <- ask
        is <- D.member r
        if is
           then do
               liftIO $ modifyMVar_ x $ \mi -> return $ Map.delete (D.rid r) mi
               return True
           else return False
    list = do
        (D.Store x _) <- ask
        liftIO $ withMVar x fromMVar
        where
          fromMVar :: Map D.RadioId (MVar D.Radio) -> IO [D.Radio]
          fromMVar y = Prelude.mapM (\(_, mv) -> withMVar mv return) $ Map.toList y
    info a = do
        (D.Store x _) <- ask
        liftIO $ withMVar x $ \y -> return $ fromJust $ Map.lookup (D.rid a) y
    -- | @TODO catch exception
    --



addHostPort::D.HostPort -> D.Radio -> D.Radio
addHostPort hp x = x { D.hostPort = hp }

-- | helpers
getter ::(D.Radio -> a) -> MVar D.Radio -> IO a
getter x y =  flip  withMVar (return . x)  y

setter :: (D.Radio -> D.Radio) -> MVar D.Radio -> IO ()
setter x y =  flip modifyMVar_ (return . x)  y

instance D.Allowed m => D.Detalization m D.Url where
    get radio = D.info radio >>= liftIO . getter D.url
    set radio a = D.info radio >>= liftIO . setter (\y -> y { D.url = a })

instance D.Allowed m => D.Detalization m D.Headers where
    get radio = D.info radio >>= liftIO . getter D.headers
    set radio a = D.info radio >>= liftIO . setter (\y -> y { D.headers = a })

instance D.Allowed m => D.Detalization m D.Channel where
    get radio = D.info radio >>= liftIO . getter D.channel
    set radio a = D.info radio >>= liftIO . setter (\y -> y { D.channel = a })

instance D.Allowed m => D.Detalization m (Maybe D.Meta) where
    get radio = D.info radio >>= liftIO . getter D.meta
    set radio a = D.info radio >>= liftIO . setter (\y -> y { D.meta = a })

instance D.Allowed m => D.Detalization m (Maybe (D.Buffer ByteString)) where
    get radio = D.info radio >>= liftIO . getter D.buff
    set radio a = D.info radio >>= liftIO . setter (\y -> y { D.buff = a})


