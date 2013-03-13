-- | Simple shoutcast server for streaming audio broadcast.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
    
module Main where

import BasicPrelude 
import Prelude ()
import qualified Prelude 

import Control.Concurrent hiding (yield)
import Control.Concurrent.Chan

import Data.ByteString (breakSubstring, split, spanEnd, breakByte)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Char8 as C

import Data.Maybe (fromJust)
import qualified Data.Map as Map
import Debug.Trace
import Data.Text (unpack)

import System.IO.Streams as S
import System.IO.Streams.Attoparsec as S
import System.IO.Streams.Concurrent as S
import Network.Socket 
import Network.BSD (getHostName)
import Network.URI

import qualified Snap.Core as Sn
import qualified Snap.Util.FileServe as Sn
import Snap.Core (Snap, Method(..))
import Snap.Http.Server
import Snap.Http.Server.Config

import Data.Aeson
import Data.Word (Word8)
import Control.Applicative
import Data.Attoparsec.RFC2616
import Data.Attoparsec (parseOnly)
import Data.Typeable (typeOf)



newtype RadioId = RadioId ByteString deriving (Show, Ord, Eq)
newtype Url = Url ByteString deriving (Show, Ord, Eq)
newtype Meta = Meta (ByteString, Int) deriving (Show, Ord, Eq)
type Headers = [Header]
type HostPort = Maybe (HostName, Int)

instance ToJSON RadioId where
    toJSON (RadioId x) = toJSON x

instance ToJSON Url where
    toJSON (Url x) = toJSON x

port :: Int
port = 2000

data RadioInfo = RI { rid :: RadioId
                    , url :: Url
                    , pid :: Maybe ThreadId
                    , headers :: Headers
                    , meta    :: Maybe Meta
                    , channel ::Maybe (Chan (Maybe ByteString))
                    , hostPort :: HostPort
                    } deriving (Eq)

instance ToJSON RadioInfo where
    toJSON x = object [ "id" .= (toJSON . rid) x
                      , "url" .= (toJSON . url) x
                      , "listenUrl" .= (toJSON . BS.concat) ["http://", C.pack host, ":", toBs port, "/", (fromRid . rid) x]
                      ]
               where 
                 (Just (host, port)) = hostPort x
                 toBs::Int -> ByteString
                 toBs  = C.pack . Prelude.show 
                 fromRid :: RadioId -> ByteString
                 fromRid (RadioId x ) = x

instance FromJSON RadioInfo where
    parseJSON (Object x) = do
        rid <- x .: "id"
        url <- x .: "url"
        return $ RI (RadioId rid) (Url url) Nothing [] Nothing Nothing Nothing

data Radio = Radio (MVar (Map RadioId (MVar RadioInfo))) HostPort

class SettingsById a where
    member   :: RadioId -> a -> IO Bool
    info     :: RadioId -> a -> IO (MVar RadioInfo)
    urlG     :: a -> RadioId -> IO Url
    urlS     :: Url -> a -> RadioId -> IO ()
    pidG     :: a -> RadioId -> IO (Maybe ThreadId)
    pidS     :: Maybe ThreadId -> a -> RadioId -> IO ()
    headersG :: a -> RadioId -> IO Headers
    headersS :: Headers -> a -> RadioId -> IO ()
    metaG    :: a -> RadioId -> IO (Maybe Meta)
    metaS    :: Maybe Meta -> a -> RadioId -> IO ()
    chanG    :: a -> RadioId -> IO (Maybe (Chan (Maybe ByteString)))
    chanS    :: Chan (Maybe ByteString) -> a -> RadioId -> IO ()
    hostG    :: a -> RadioId -> IO HostPort

class Api a where
    allStream:: a -> IO [RadioInfo]
    addStream:: a -> RadioInfo -> IO Bool
    rmStream :: a -> RadioId -> IO Bool

    
instance SettingsById Radio where
    member rid (Radio radio _) = withMVar radio $ \x -> return $ rid `Map.member` x
    info rid (Radio radio _) = withMVar radio $ \x -> return $ fromJust $ Map.lookup rid x
    urlG =  getter $ return . url
    urlS u = setter $ \x -> return $ x { url = u } 
    pidG = getter $ return . pid
    pidS p = setter $ \x -> return $ x { pid = p }
    headersG = getter $ return . headers
    headersS h = setter $ \x -> return $ x { headers = h }
    metaG = getter $ return . meta
    metaS m = setter $ \x -> return $ x { meta = m }
    chanG (Radio radio hp) rid = do
        chan <- getter (return . channel) (Radio radio hp) rid 
        case chan of
             Nothing -> do
                 Just chan' <- makeClient (Radio radio hp) rid
                 chanS chan' (Radio radio hp) rid
                 dup <- dupChan chan'
                 return $ Just dup
             Just chan' -> do
                 dup <- dupChan chan'
                 return $ Just dup
    chanS chan = setter $ \x -> return $ x { channel = Just chan }
    hostG =  getter $ return . hostPort

instance Api Radio where
    allStream (Radio x _) = withMVar x fromMVar
        where 
          fromMVar :: Map RadioId (MVar RadioInfo) -> IO [RadioInfo]
          fromMVar y = Prelude.mapM (\(i, mv) -> withMVar mv return) $ Map.toList y
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
        
        
getter:: (RadioInfo -> IO b) -> Radio -> RadioId -> IO b
getter f radio rid = do
    infoM <- info rid radio
    withMVar infoM f
    
setter:: (RadioInfo -> IO RadioInfo) -> Radio -> RadioId -> IO ()
setter f radio rid = do
    infoM <- info rid radio
    modifyMVar_ infoM f
        

main::IO ()
main = do
    host <- getHostName
    stations <- makeRadioStation $ Just (host, 2000)
    forkIO $ web stations
    sock <- socket AF_INET Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (SockAddrInet (toEnum port) 0)
    listen sock 100
    forever $ do
        (accepted, _) <- accept sock
        connected <- socketToStreams accepted
        forkIO $ connectHandler connected stations >> sClose accepted
    sClose sock
    return ()


web::Radio -> IO ()
web radio = quickHttpServe $ Sn.ifTop (Sn.serveFile "static/index.html") <|> 
                             Sn.method GET ( Sn.route [ ("server/stats", statsHandler radio)
                                                      , ("stream", getStreamHandler radio)
                                                      , ("stream/:sid", streamHandlerById radio)
                                                      , ("stream/:sid/metadata", streamMetaHandler radio)
                                                      ])                                                  <|>
                             Sn.method POST ( Sn.route [ ("stream/:sid", postStreamHandler radio) ] )     <|>
                             Sn.method DELETE ( Sn.route [ ("stream/:sid", deleteStreamHandler radio) ] ) <|>
                             Sn.dir "static" (Sn.serveDirectory "./static")


statsHandler radio = Sn.writeText "stats"

getStreamHandler ::Radio -> Snap ()
getStreamHandler radio = do
        s <- liftIO $ allStream radio
        Sn.writeLBS $ encode s

postStreamHandler::Radio -> Snap ()
postStreamHandler radio = do
        info <- decode <$> Sn.readRequestBody 1024  :: Snap (Maybe RadioInfo)
        case info of
             Nothing -> Sn.finishWith $ Sn.setResponseCode 400 Sn.emptyResponse
             Just i -> do
                 result <- liftIO $ addStream radio i
                 if result 
                    then Sn.writeLBS $ encode i
                    else Sn.finishWith $ Sn.setResponseCode 409 Sn.emptyResponse

deleteStreamHandler::Radio -> Snap ()
deleteStreamHandler radio = do
    param <- Sn.getParam "sid"
    maybe (Sn.finishWith $ Sn.setResponseCode 400 Sn.emptyResponse) rmSt param
    where
      rmSt i = do
          result <-  liftIO $ rmStream radio (RadioId i)
          Sn.finishWith $ Sn.setResponseCode (if result then 200 else 403) Sn.emptyResponse 
    


streamHandlerById::Radio -> Snap ()
streamHandlerById radio = Sn.method Sn.GET $ do
    param <- Sn.getParam "sid"
    maybe justGetStream withParam param
    where
      justGetStream :: Snap ()
      justGetStream = Sn.writeText "clean param"
      withParam sid = do
          Sn.writeBS sid
          Sn.writeText "with param"

streamMetaHandler = undefined



makeRadioStation ::HostPort -> IO Radio
makeRadioStation hp = do
    inf <- newMVar $ big hp
    r <- newMVar $ Map.singleton (RadioId "/big") inf 
    return $ Radio r hp

big::HostPort -> RadioInfo
big = RI (RadioId "/big") (Url "http://radio.bigblueswing.com:8002") Nothing [] Nothing Nothing

showType :: SomeException -> String
showType = Prelude.show . typeOf

connectHandler::(InputStream ByteString, OutputStream ByteString) -> Radio -> IO ()
connectHandler (inputS, outputS) radio = do
    sized <- S.throwIfProducesMoreThan 2048 inputS
    result <- try $ S.parseFromStream request sized ::IO (Either SomeException (Request, Headers))
    either badRequest goodRequest result
    where
        badRequest s | showType s == "TooManyBytesReadException" = S.write (Just "ICY 414 Request-URI Too Long\r\n") outputS
                     | otherwise                                = S.write (Just "ICY 400 Bad Request\r\n") outputS
                     
        goodRequest (request', headers) = do
            idInBase <- (RadioId $ requestUri request') `member` radio
            if idInBase 
               then do
                   !chan <- chanG radio (RadioId $ requestUri request')
                   threadDelay 1000000
                   print request'
                   print headers
                   start <- S.fromByteString successRespo
                   input <- S.chanToInput (fromJust chan)
                   S.supply start outputS
                   S.connect input outputS
                   return ()
               else do
                   -- | unknown radio id
                   print request'
                   print headers
                   S.write (Just "ICY 404 Not Found\r\n") outputS
                   

makeClient::Radio -> RadioId -> IO (Maybe (Chan (Maybe ByteString)))
makeClient radio rid = do
    radioStreamInput <- getConnect radio rid
    chan <- newChan 
    chanStreamOutput <- S.chanToOutput chan
    chanStreamInput  <- S.chanToInput  chan
    devNull <- S.nullOutput
    forkIO $ S.connect radioStreamInput  chanStreamOutput
    forkIO $ S.connect chanStreamInput devNull
    -- | @TODO save pid
    return $ Just chan
                   
getConnect::Radio -> RadioId -> IO (InputStream ByteString)
getConnect radio rid = do
    url <- urlG radio rid
    (i, o) <- openConnection url
    getStream <- S.fromByteString "GET / HTTP/1.0\r\nIcy-MetaData: 1\r\n\r\n"
    S.connect getStream o
    result <- S.parseFromStream response i
    print result
    return i
                   

openConnection :: Url -> IO (InputStream ByteString, OutputStream ByteString)
openConnection (Url url) = do
        let Right (hb, pb) = parseOnly parseUrl url
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
    
testUrl :: ByteString
testUrl = "http://bigblueswing.com:2002"

testUrl1 :: ByteString
testUrl1 = "http://bigblueswing.com"
                   
testUrl2 :: ByteString
testUrl2 = "http://bigblueswing.com:2002/asdf"

testUrl3 ::ByteString
testUrl3 = "http://bigblueswing.com/asdf"

successRespo :: ByteString
successRespo = BS.concat [ "ICY 200 OK\r\n"
                         , "icy-notice1: Haskell shoucast splitter\r\n"
                         , "icy-notice2: Good music here\r\n"
                         , "content-type: audio/mpeg\r\n"
                         , "icy-name: Good music for avery one \r\n"
                         , "icy-url: http://localhost:2000/big \r\n"
                         , "icy-genre: Swing  Big Band  Jazz  Blues\r\n"
                         , "icy-pub: 1\r\n"
                         , "icy-metaint: 0\n"
                         , "icy-br: 64\r\n\r\n"
                         ]

