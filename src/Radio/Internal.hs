{-# LANGUAGE OverloadedStrings #-}
module Radio.Internal where

import           BasicPrelude
import           Control.Concurrent           hiding (yield)
import qualified Data.Map                     as Map
import           Prelude                      ()
import qualified Prelude

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

instance SettingsById Radio where
    member rid' (Radio radio _) = withMVar radio $ \x -> return $ rid' `Map.member` x
    info rid' (Radio radio _) = withMVar radio $ \x -> return $ fromJust $ Map.lookup rid' x
    urlG =  getter $ return . url
    urlS u = setter $ \x -> return $ x { url = u }
    pidG = getter $ return . pid
    pidS p = setter $ \x -> return $ x { pid = p }
    headersG = getter $ return . headers
    headersS h = setter $ \x -> return $ x { headers = h }
    metaG = getter $ return . meta
    metaS m = setter $ \x -> return $ x { meta = m }
    chanG (Radio radio hp) rid' = do
        chan <- getter (return . channel) (Radio radio hp) rid'
        case chan of
             Nothing -> do
                 Just chan' <- makeClient (Radio radio hp) rid'
                 chanS chan' (Radio radio hp) rid'
                 dup <- dupChan chan'
                 return $ Just dup
             Just chan' -> do
                 dup <- dupChan chan'
                 return $ Just dup
    chanS chan = setter $ \x -> return $ x { channel = Just chan }
    hostG =  getter $ return . hostPort

getter:: (RadioInfo -> IO b) -> Radio -> RadioId -> IO b
getter f radio rid' = do
    infoM <- info rid' radio
    withMVar infoM f

setter:: (RadioInfo -> IO RadioInfo) -> Radio -> RadioId -> IO ()
setter f radio rid' = do
    infoM <- info rid' radio
    modifyMVar_ infoM f



instance Api Radio where
    allStream (Radio x _) = withMVar x fromMVar
        where
          fromMVar :: Map RadioId (MVar RadioInfo) -> IO [RadioInfo]
          fromMVar y = Prelude.mapM (\(_, mv) -> withMVar mv return) $ Map.toList y
    addStream (Radio x hp) radioInfo = do
        is <- rid radioInfo `member` Radio x hp
        if is
           then return False
           else do
               mv <- newMVar $ addHostPort hp radioInfo
               modifyMVar_ x $ \mi -> return $ Map.insert (addSlash $ rid radioInfo) mv mi
               return True
    rmStream (Radio x hp) rid' = do
       is <- rid' `member` Radio x hp
       if is
          then do
              modifyMVar_ x $ \mi -> return $ Map.delete rid' mi
              return True
          else return False


addSlash::RadioId -> RadioId
addSlash (RadioId x) = RadioId $ BS.concat ["/", x]

addHostPort::HostPort -> RadioInfo -> RadioInfo
addHostPort hp x = x { hostPort = hp }


makeClient::Radio -> RadioId -> IO (Maybe (Chan (Maybe ByteString)))
makeClient radio rid' = do
    radioStreamInput <- getConnect radio rid'
    chan <- newChan
    chanStreamOutput <- S.chanToOutput chan
    chanStreamInput  <- S.chanToInput  chan
    devNull <- S.nullOutput
    forkIO $ S.connect radioStreamInput  chanStreamOutput
    forkIO $ S.connect chanStreamInput devNull
    -- | @TODO save pid
    return $ Just chan


getConnect::Radio -> RadioId -> IO (InputStream ByteString)
getConnect radio rid' = do
    url' <- urlG radio rid'
    (i, o) <- openConnection url'
    getStream <- S.fromByteString "GET / HTTP/1.0\r\nIcy-MetaData: 1\r\n\r\n"
    S.connect getStream o
    result <- S.parseFromStream response i
    print result
    return i


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

