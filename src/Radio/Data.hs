{-# LANGUAGE OverloadedStrings #-}
module Radio.Data where

import           BasicPrelude            hiding (concat)
import           Prelude                 ()
import qualified Prelude

import           Control.Concurrent      (Chan, MVar, ThreadId)
import           Data.Aeson              (FromJSON (..), ToJSON (..),
                                          Value (..), object, (.:), (.=))
import           Data.Attoparsec.RFC2616 (Header (..))
import           Data.ByteString         (concat)
import           Data.ByteString.Char8   (pack)
import           Network.Socket          (HostName)


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


