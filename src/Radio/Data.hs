{-# LANGUAGE OverloadedStrings #-}
module Radio.Data where

import           BasicPrelude                 hiding (concat)
import           Prelude                      ()
import qualified Prelude

import           Control.Concurrent           (Chan, MVar, ThreadId)
import           Data.Aeson                   (FromJSON (..), ToJSON (..),
                                               Value (..), object, (.:), (.=))
import           Data.Attoparsec.RFC2616      (Header (..))
import           Data.ByteString              (concat)
import           Data.ByteString.Char8        (pack)
import           Network.Socket               (HostName)

import           System.IO.Streams            as S
import           System.IO.Streams.Attoparsec as S
import           System.IO.Streams.Concurrent as S

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

data RadioInfo = RI { rid      :: RadioId
                    , url      :: Url
                    , pid      :: Maybe ThreadId
                    , headers  :: Headers
                    , meta     :: Maybe Meta
                    , channel  ::Maybe (Chan (Maybe ByteString))
                    , hostPort :: HostPort
                    } deriving (Eq)

instance Show RadioInfo where
    show x = Prelude.show (rid x) ++ Prelude.show (url x) ++ Prelude.show (hostPort x)

instance ToJSON RadioInfo where
    toJSON x = object [ "id" .= (toJSON . rid) x
                      , "url" .= (toJSON . url) x
                      , "listenUrl" .= (toJSON . concat) ["http://", pack host', ":", toBs port', "/", (fromRid . rid) x]
                      ]
               where
                 (Just (host', port')) = hostPort x
                 toBs::Int -> ByteString
                 toBs  = pack . Prelude.show
                 fromRid :: RadioId -> ByteString
                 fromRid (RadioId y ) = y

instance FromJSON RadioInfo where
    parseJSON (Object x) = do
        rid' <- x .: "id"
        url' <- x .: "url"
        return $ RI (RadioId rid') (Url url') Nothing [] Nothing Nothing Nothing

data Radio = Radio (MVar (Map RadioId (MVar RadioInfo))) HostPort

data WebApi a = WebApi {
    allStream :: IO [RadioInfo]
  , addStream :: RadioInfo -> IO (Bool, RadioInfo)
  , rmStream  :: RadioId -> IO Bool
  }


data StreamApi = StreamApi {
    makeClient  :: IO (Maybe (Chan (Maybe ByteString)))
  , makeConnect :: IO (InputStream ByteString)
  }

data DataApi = DataApi {
    urlG     :: IO Url
  , urlS     :: Url -> IO ()
  , pidG     :: IO (Maybe ThreadId)
  , pidS     :: Maybe ThreadId -> IO ()
  , headersG :: IO Headers
  , headersS :: Headers -> IO ()
  , metaG    :: IO (Maybe Meta)
  , metaS    :: Maybe Meta -> IO ()
  , chanG    :: IO (Maybe (Chan (Maybe ByteString)))
  , chanS    :: Chan (Maybe ByteString) -> IO ()
  , hostG    :: IO HostPort
  }

data OneStream = OneStream {
    member :: IO Bool
  , info   :: IO (MVar RadioInfo)
  }

