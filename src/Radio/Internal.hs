{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, FunctionalDependencies #-}
module Radio.Internal (module Radio.Data, makeChannel, load, save, setMeta) where

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
import Data.Attoparsec.RFC2616 (lookupHeader)

instance D.Allowed m => D.Storable m D.Radio where
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

save :: D.Allowed m => Prelude.FilePath -> m ()
save path = do
    l <- D.list :: D.Allowed m => m [D.Radio]
    liftIO $ LS.writeFile path $ encode l
    
load :: D.Allowed m => Prelude.FilePath -> m ()
load path = do
    l <- liftIO $ LS.readFile path
    R.mapM_ D.create $ (decode l :: [D.Radio])
    return ()        
        
          
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
    
-- | создаем канал
makeChannel::D.Radio -> D.Application ()
makeChannel radio = do
    radioStreamInput <- try $ makeConnect radio :: D.Application (Either SomeException (InputStream ByteString))
    either whenError whenGood radioStreamInput
    where 
      whenError x = do
          liftIO $ print $ "Error when connection: " ++ show x 
          D.set radio $ (Nothing :: Maybe (Chan (Maybe ByteString)))
      whenGood radioStreamInput' = do
          chan <- liftIO $ newChan
          chanStreamOutput <- liftIO $ S.chanToOutput chan
          chanStreamInput  <- liftIO $ S.chanToInput  chan
          devNull <- liftIO $ S.nullOutput
          liftIO $ forkIO $ S.connect radioStreamInput'  chanStreamOutput
          liftIO $ forkIO $ S.connect chanStreamInput devNull
          D.set radio $ (Just chan :: Maybe (Chan (Maybe ByteString)))
          -- | @TODO save pid
          return ()
    
-- | создаем соединение до стрим сервера
makeConnect :: D.Radio -> D.Application (InputStream ByteString)
makeConnect radio = do
   (i, o) <- openConnection radio
   getStream <- liftIO $ S.fromByteString "GET / HTTP/1.0\r\nIcy-MetaData: 1\r\n\r\n"
   liftIO $ S.connect getStream o
   (response, headers) <- liftIO $ S.parseFromStream response i
   -- | @TODO обработать исключения
   D.set radio headers
   resultStream <- getMeta radio i
   liftIO $ print response
   liftIO $ print headers
   return resultStream

-- | считываю metainfo с входного потока, сохраняю в состоянии
getMeta :: D.Radio -> InputStream ByteString -> D.Application (InputStream ByteString)
getMeta radio i = do
    metaHeader <- lookupHeader "icy-metaint" <$> D.get radio :: D.Application [ByteString]
    liftIO $ print $ "found meta" ++ show metaHeader 
    let metaInt = unpackMeta metaHeader
    maybe (return i) (getMetaFromStream i) metaInt
    where
    
        toLen :: ByteString -> Int
        toLen x = let [w] = BS.unpack x
                  in 16 * fromIntegral w
                  
        unpackMeta :: [ByteString] -> Maybe Int
        unpackMeta meta = do
            m <- listToMaybe meta
            (a,_) <- C.readInt m
            return a
            
        getMetaFromStream :: InputStream ByteString -> Int -> D.Application (InputStream ByteString)
        getMetaFromStream i mi = do
            from <- liftIO $ S.readExactly mi i
            len <- liftIO $ toLen <$> S.readExactly 1 i
            metaInfo <- liftIO $ S.readExactly len i
            liftIO $ print metaInfo
            D.set radio (Just $ D.Meta (metaInfo, len)) 
            predicate <- liftIO $ S.fromByteString from
            output <- liftIO $ S.appendInputStream predicate i 
            return output
            

-- | вставляю metainfo в выходной поток
setMeta :: D.Radio -> InputStream ByteString -> D.Application (InputStream ByteString)
setMeta radio i = do
    metaInfo <- D.get radio :: D.Application (Maybe D.Meta)
    maybe (return i) (setMetaToOutputStream i) metaInfo
    where
        fromLen :: Int -> ByteString
        fromLen x = (BS.singleton . fromIntegral) $ truncate $ (fromIntegral x / 16) 
    
        setMetaToOutputStream :: InputStream ByteString -> D.Meta -> D.Application (InputStream ByteString)
        setMetaToOutputStream i (D.Meta (mi,l)) = do
            let metaInt = 8192 
            from <- liftIO $ S.readExactly metaInt i
            from' <- liftIO $ S.fromByteString from
            size <- liftIO $ S.fromByteString $ fromLen l
            liftIO $ print $ "len " ++ show l
            liftIO $ print $ "size " ++ (show $ fromLen l)
            metaInfo <- liftIO $ S.fromByteString mi
            output <- liftIO $ S.concatInputStreams [from', size, metaInfo, i]
            return output
            
        
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



