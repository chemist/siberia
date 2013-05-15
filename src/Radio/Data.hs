{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TypeSynonymInstances   #-}

module Radio.Data where

import           BasicPrelude                 hiding (concat, mapM)
import           Prelude                      ()
import qualified Prelude

import           Control.Concurrent           (Chan, MVar, ThreadId, newMVar)
import           Data.Aeson                   (FromJSON (..), ToJSON (..),
                                               Value (..), object, (.:), (.=))
import           Data.Attoparsec.RFC2616      (Header (..))
import           Data.ByteString              (concat)
import qualified Data.ByteString              as BS
import           Data.ByteString.Char8        (pack)
import qualified Data.Map                     as Map
import           Network.Socket               (HostName)

import           Blaze.ByteString.Builder     (Builder)
import           Control.Monad.RWS.Lazy
import           Data.Binary                  (Binary, Get)
import qualified Data.Binary                  as B
import qualified Data.Collections             as Collections
import           Data.Cycle
import           Data.IORef
import qualified Data.Map                     as M
import           Snap.Core                    (Snap)
import           System.IO.Streams            as S
import           System.IO.Streams.Attoparsec as S
import           System.IO.Streams.Concurrent as S

tempDir = "./.music/"
musicDirectory = "./music/"

limitSizeForUpload :: Int64
limitSizeForUpload = 10000000

newtype RadioId = RadioId ByteString deriving (Show, Ord, Eq)
newtype Url = Url ByteString deriving (Show, Ord, Eq)
newtype Meta = Meta (ByteString, Int) deriving (Show, Ord, Eq)

type Headers = [Header]
type HostPort = Maybe (HostName, Int)
type Channel = Maybe (Chan (Maybe ByteString))

port :: Int
port = 2000

data RadioType = LocalFiles | Proxy | Id

data Status = Status { connections          :: Int
                     , connectProcess       :: Maybe ThreadId
                     , bufferProcess        :: Maybe ThreadId
                     , chanProcess          :: Maybe ThreadId
                     , connectionsProcesses :: [ThreadId]
                     } deriving (Eq)

defStatus :: Status
defStatus = Status 0 Nothing Nothing Nothing []

logFile = "log/siberia.log"

data RadioInfo x = RI { rid      :: x
                      , url      :: Url
                      , pid      :: Status
                      , headers  :: Headers
                      , meta     :: Maybe Meta
                      , channel  :: Channel
                      , hostPort :: HostPort
                      , buff     :: Maybe (Buffer ByteString)
                      }
                  | ById { rid :: x } deriving (Eq)

data Song = Song { sidi  :: Int
                 , spath :: String
                 } deriving (Eq, Show)

type Playlist = Cycle Song

instance Ord Song where
    compare x y = compare (sidi x) (sidi y)



type Radio = RadioInfo RadioId
type AllPlaylist = M.Map RadioId (MVar Playlist)

data Store a = Store (MVar (Map RadioId (MVar a))) HostPort (MVar AllPlaylist)

type State = AllPlaylist

type RadioStore = Store Radio

newtype Logger = Logger Text

instance Monoid Logger where
    mempty = Logger $ mempty
    mappend (Logger x) (Logger y) = Logger $ mappend x y

type Application = RWST RadioStore Logger State IO

type Web = RWST RadioStore Logger State Snap

data Buffer a = Buffer { active :: IORef (Cycle Int)
                       , buf    :: IORef (Cycle (IORef a))
                       , size   :: IORef Int
                       } deriving (Eq)

class Monoid a => RadioBuffer m a where
    -- ** создание буфера указанного размера
    new       :: Int -> IO (m a)
    bufSize   :: m a -> IO Int
    -- ** циклический счетчик, номер блока для следующей записи
    current   :: m a -> IO Int
    nextC     :: m a -> IO Int
    -- ** последний записанный блок
    lastBlock :: m a -> IO a
    -- ** запись очередного блока
    update    :: a -> m a -> IO ()
    -- ** вернуть весь буфер в упорядоченном состоянии
    getAll    :: m a -> IO a

runWeb :: Web a -> RadioStore -> State -> Snap a
runWeb mw r s = do (a, _, Logger w) <- runRWST mw r s
                   liftIO $ appendFile logFile w
                   return a


class (Monad m, MonadIO m, MonadReader RadioStore m, MonadWriter Logger m, MonadState State m) => Allowed m

instance Allowed Application
instance Allowed Web

class Storable m a where
    -- ** проверка наличия радиостанции
    member :: a -> m Bool
    -- ** создание радиостанции
    create :: a -> m (Bool, a)
    -- ** удаление радиостанции
    remove :: a -> m Bool
    -- ** список радиостанций
    list   :: m [a]
    -- ** возвращает MVar с RadioInfo по ById RadioId
    info   :: a -> m (MVar a)
    -- ** возвращает MVar Playlist если определенн
    playlist :: a -> m (Maybe (MVar Playlist))

class Detalization m a where
    getD :: Radio -> m a
    setD :: Radio -> a -> m ()

instance Show Radio where
    show (ById x) = Prelude.show x
    show x = Prelude.show (rid x) ++ Prelude.show (url x) ++ Prelude.show (hostPort x)

instance ToJSON Radio where
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

instance FromJSON Radio where
    parseJSON (Object x) = do
        rid' <- x .: "id"
        url' <- x .: "url"
        return $ RI (addSlash $ RadioId rid') (Url url') defStatus [] Nothing Nothing Nothing Nothing

instance ToJSON (Maybe Meta) where
    toJSON (Just (Meta (bs,_))) = object [ "meta" .=  (toJSON $ BS.takeWhile (/= toEnum 0) bs) ]
    toJSON Nothing = object [ "meta" .=  toJSON BS.empty ]
    

instance ToJSON Song where
    toJSON x = object [ "position" .= (toJSON . sidi) x
                      , "file"     .= (toJSON . spath) x
                      ]
                      
instance FromJSON Song where
    parseJSON (Object x) = Song <$> x .: "position" <*> x .: "file"
    

instance ToJSON Playlist where
    toJSON x = toJSON . Collections.toList $ x

instance ToJSON Status where
    toJSON (Status i (Just _) _ _ _) = object [ "connections" .= toJSON i
                                            , "status" .= toJSON True
                                            ]
    toJSON (Status i Nothing _ _ _) = object [ "connections" .= toJSON i
                                           , "status" .= toJSON False
                                           ]

addSlash::RadioId -> RadioId
addSlash (RadioId x) = RadioId $ concat ["/", x]



instance ToJSON RadioId where
    toJSON (RadioId x) = toJSON x

instance ToJSON Url where
    toJSON (Url x) = toJSON x

instance Binary Url where
    put (Url x) = B.put x
    get = Url <$> B.get

instance Binary RadioId where
    put (RadioId x) = B.put x
    get = RadioId <$> B.get

instance Binary Radio where
    put x = do
        B.put $ rid x
        B.put $ url x
    get = do
        r <- B.get :: Get RadioId
        u <- B.get :: Get Url
        return $ RI r u defStatus [] Nothing Nothing Nothing Nothing


