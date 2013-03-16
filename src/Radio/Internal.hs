{-# LANGUAGE OverloadedStrings #-}
module Radio.Internal (dataApi, streamApi, oneStream,  webApi) where

import           BasicPrelude
import           Control.Concurrent           hiding (yield)
import qualified Data.Map                     as Map
import           Prelude                      ()
import qualified Prelude

import           Control.Category
import           Data.Attoparsec              (parseOnly)
import           Data.Attoparsec.RFC2616
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Char8        as C
import           Data.Maybe                   (fromJust)
import           Network.Socket
import           System.IO.Streams            as S
import           System.IO.Streams.Attoparsec as S
import           System.IO.Streams.Concurrent as S


import           Radio.Data

webApi :: Radio -> WebApi Radio
webApi x = WebApi {
    allStream = wallStream x
  , addStream = waddStream x
  , rmStream = wrmStream x
  }


streamApi :: OneStream -> StreamApi
streamApi x = StreamApi {
  makeConnect = do
    url' <- urlG $ dataApi x
    (i, o) <- openConnection url'
    getStream <- S.fromByteString "GET / HTTP/1.0\r\nIcy-MetaData: 1\r\n\r\n"
    S.connect getStream o
    result <- S.parseFromStream response i
    print result
    return i
  , makeClient = do
     radioStreamInput <- makeConnect $ streamApi x
     chan <- newChan
     chanStreamOutput <- S.chanToOutput chan
     chanStreamInput  <- S.chanToInput  chan
     devNull <- S.nullOutput
     forkIO $ S.connect radioStreamInput  chanStreamOutput
     forkIO $ S.connect chanStreamInput devNull
     -- | @TODO save pid
     return $ Just chan
  }

openConnection :: Url -> IO (InputStream ByteString, OutputStream ByteString)
openConnection (Url url') = do
        let Right (hb, pb) = parseOnly parseUrl url'
            h = C.unpack hb
            p = C.unpack pb
        print h
        print p
        is <- getAddrInfo (Just hints) (Just h) (Just p)
        let addr = head is
        let a = addrAddress addr
        s <- socket (addrFamily addr) Stream defaultProtocol
        Network.Socket.connect s a
        (i,o) <- S.socketToStreams s
        return (i, o)
        where
           hints = defaultHints {addrFlags = [AI_ADDRCONFIG, AI_NUMERICSERV]}


oneStream :: Radio -> RadioId -> OneStream
oneStream radio rid' = OneStream {
  member = dmember rid' radio
  , info = dinfo rid' radio
  }

dmember rid' (Radio radio _) = withMVar radio $ \x -> return $ rid' `Map.member` x
dinfo rid' (Radio radio _) = withMVar radio $ \x -> return $ fromJust $ Map.lookup rid' x

dataApi :: OneStream -> DataApi
dataApi stream = DataApi {
    urlG = getter' url $ info stream
  , pidG = getter' pid $ info stream
  , metaG = getter' meta $ info stream
  , hostG = getter' hostPort $ info stream
  , urlS = \x -> setter' (\y -> y { url = x}) $ info stream
  , pidS = \x -> setter' (\y -> y { pid = x}) $ info stream
  , headersS = \x -> setter' (\y -> y { headers = x}) $ info stream
  , metaS = \x -> setter' (\y -> y { meta = x}) $ info stream
  , headersG = getter' headers $ info stream
  , chanS = \x -> setter' (\y -> y { channel = Just x }) $ info stream
  , chanG = do
    chan <- getter' channel $ info stream
    case chan of
      Nothing -> do
        Just chan' <- makeClient $ streamApi stream
        chanS (dataApi stream) chan'
        dup <- dupChan chan'
        return $ Just dup
      Just chan' -> do
        dup <- dupChan chan'
        return $ Just dup
  }

getter' :: (RadioInfo -> a) -> IO (MVar RadioInfo) -> IO a
getter' x y = join $ flip  withMVar (return . x) <$> y

setter' :: (RadioInfo -> RadioInfo) -> IO (MVar RadioInfo) -> IO ()
setter' x y = join $ flip modifyMVar_ (return . x) <$> y



wallStream (Radio x _) = withMVar x fromMVar
    where
      fromMVar :: Map RadioId (MVar RadioInfo) -> IO [RadioInfo]
      fromMVar y = Prelude.mapM (\(_, mv) -> withMVar mv return) $ Map.toList y

waddStream (Radio x hp) radioInfo = do
    is <- rid radioInfo `dmember` Radio x hp
    if is
       then return (False, undefined)
       else do
           mv <- newMVar withPort
           modifyMVar_ x $ \mi -> return $ Map.insert (rid radioInfo) mv mi
           return (True, withPort)
    where withPort = addHostPort hp radioInfo

wrmStream (Radio x hp) rid' = do
   is <- rid' `dmember` Radio x hp
   if is
      then do
          modifyMVar_ x $ \mi -> return $ Map.delete rid' mi
          return True
      else return False


addSlash::RadioId -> RadioId
addSlash (RadioId x) = RadioId $ BS.concat ["/", x]

addHostPort::HostPort -> RadioInfo -> RadioInfo
addHostPort hp x = x { hostPort = hp }
