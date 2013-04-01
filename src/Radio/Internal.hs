{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, FunctionalDependencies #-}
module Radio.Internal (module Radio.Data, getMetaInfo, makeChannel, load, save, connectWithRemoveMetaAndBuffering, connectWithAddMetaAndBuffering) where

import           BasicPrelude
import           Control.Concurrent           hiding (yield)
import qualified Data.Map                     as Map
import           Prelude                      ()
import qualified Prelude

import           Control.Category
import           Data.Attoparsec              (parseOnly)
import           Data.Attoparsec.RFC2616
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Lazy         as LS
import qualified Data.ByteString.Char8        as C
import           Data.Maybe                   (fromJust)
import           Network.Socket
import           System.IO.Streams            as S
import           System.IO.Streams.Attoparsec as S
import           System.IO.Streams.Concurrent as S

import Control.Monad.Reader
import qualified Control.Monad.Reader as R

import  Radio.Data ()
import qualified Radio.Data as D
import Data.Binary
import Blaze.ByteString.Builder (flush, fromByteString)
import qualified Blaze.ByteString.Builder as Builder
import Blaze.ByteString.Builder.Internal.Buffer (allNewBuffersStrategy)
import Data.IORef
import Data.Cycle
import qualified Data.Collections as Collections
import Data.Text.Encoding as E

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
          liftIO $ forkIO $ connectWithRemoveMetaAndBuffering metaInt saveMeta  4096 radioStreamInput'  chanStreamOutput
          liftIO $ forkIO $ S.connect chanStreamInput outputBuffer
          D.set radio $ (Just chan :: Maybe (Chan (Maybe ByteString)))
          -- | @TODO save pid
          return ()
      unpackMeta :: [ByteString] -> Maybe Int
      unpackMeta meta = do
          m <- listToMaybe meta
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
    loop1 builder 
    where 
    loop1 builder = do
        !m <- S.read is
        maybe (S.write Nothing builder)
              (\x -> do
                 S.write (Just $ Builder.fromByteString x) builder 
                 loop1 builder)
              m
connectWithRemoveMetaAndBuffering (Just metaInt) saveMeta buffSize is os = do
    let strategy = allNewBuffersStrategy buffSize
    builder <- S.builderStreamWith strategy os
    loop1 builder metaInt metaInt
    where 
    loop1 builder metaInt' whereNextMetaInt = do
        !m <- S.read is
        maybe (S.write Nothing builder)
              (\x -> do
                 let chunkSize = BS.length x
                 if chunkSize <= whereNextMetaInt 
                    then do
                        S.write (Just $ Builder.fromByteString x) builder 
                        loop1 builder metaInt' (whereNextMetaInt - chunkSize)
                    else do
                        let (start, metaSize, meta', end, nextMetaInt) = getMetaInfo metaInt' whereNextMetaInt x
                        S.write (Just $ Builder.fromByteString start) builder
                        S.write (Just $ Builder.fromByteString end) builder
                        when (metaSize /= 0) $ saveMeta $ Just $ D.Meta (meta', metaSize)
                        loop1 builder metaInt' nextMetaInt
                        )
              m
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
    loop2 builder 
    where 
    loop2 builder = do
        !m <- S.read is
        maybe (S.write Nothing builder)
              (\x -> do
                 S.write (Just $ Builder.fromByteString x) builder 
                 loop2 builder)
              m
connectWithAddMetaAndBuffering (Just metaInt) getMeta buffSize is os = do
    let strategy = allNewBuffersStrategy buffSize
    builder <- S.builderStreamWith strategy os
    loop2 builder metaInt metaInt ""
    where 
    fromLen :: Int -> ByteString
    fromLen x = (BS.singleton . fromIntegral) $ truncate $ (fromIntegral x / 16) 
    
    loop2 builder metaInt' whereNextMetaInt oldMeta = do
        !m <- S.read is
        maybe (S.write Nothing builder)
              (\x -> do
                 let chunkSize = BS.length x
                 print "size"
                 print $ show whereNextMetaInt ++ "next"
                 print $ show chunkSize ++ "chunk"
                 meta' <- getMeta
                 case (whereNextMetaInt >= chunkSize, meta') of
                      (True, _) -> do
                          print "first"
                          S.write (Just $ Builder.fromByteString x) builder 
                          loop2 builder metaInt' (whereNextMetaInt - chunkSize) oldMeta
                -- @TODO неправильно, переписать
                      (False, Nothing) -> do
                          print "second"
                          let (start, end) = BS.splitAt whereNextMetaInt x
                              endSize = BS.length end
                          S.write (Just $ Builder.fromByteString start) builder
                          S.write (Just $ Builder.fromByteString $ BS.pack $ [toEnum 0]) builder
                          S.write (Just $ Builder.fromByteString end) builder
                          loop2 builder metaInt' (metaInt' - (endSize - 1 )) ""
                      (False, Just (D.Meta (meta'', metaSize))) -> do
                          print "third"
                          let (start, end) = BS.splitAt whereNextMetaInt x
                              endSize = BS.length end
                          S.write (Just $ Builder.fromByteString start) builder
                          if meta'' /= oldMeta 
                             then do
                                 print "third 1"
                                 S.write (Just $ Builder.fromByteString $ fromLen metaSize) builder
                                 S.write (Just $ Builder.fromByteString meta'') builder
                                 S.write (Just $ Builder.fromByteString end) builder
                                 loop2 builder metaInt' (metaInt' - (endSize + metaSize + 1)) meta''
                             else do
                                 print "third 2"
                                 S.write (Just $ Builder.fromByteString $ BS.pack $ [toEnum 0]) builder
                                 S.write (Just $ Builder.fromByteString end) builder
                                 loop2 builder metaInt' (metaInt' - (endSize + 1)) meta''
                        )
              m

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
   (response, headers) <- liftIO $ S.parseFromStream response i
   -- | @TODO обработать исключения
   D.set radio headers
   liftIO $ print response
   liftIO $ print headers
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
 

