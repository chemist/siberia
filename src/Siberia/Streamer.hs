{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
module Siberia.Streamer where

import           Control.Applicative
import           Data.ByteString          (ByteString)
import qualified Data.ByteString          as BS
import           Data.ByteString.Char8    (pack)

import           Audio.TagLib.TagLib
import           System.IO
import qualified System.IO.Streams        as S
import qualified System.IO.Streams.Handle as S
import Data.Time
import Data.IORef
import Control.Concurrent
import Data.Maybe
import Control.Monad
import Data.Aeson
import qualified Data.Aeson.Generic as G
import Data.Typeable 
import Data.Data
import Data.Binary
import GHC.Generics


data Audio = Audio
  { bitRate    :: Int
  , duration   :: Int
  , sampleRate :: Int
  , channels   :: Int
  } deriving (Show)

data ATag = ATag
  { album   :: String
  , artist  :: String
  , comment :: String
  , genre   :: String
  , title   :: String
  , track   :: Int
  , year    :: Int
  } deriving (Eq, Show, Data, Typeable, Generic)
  
instance ToJSON ATag 
instance FromJSON ATag 
instance Binary ATag

getAudio :: String -> IO (Maybe Audio, Maybe ATag)
getAudio filename = do
    tagFile <- tagFileOpen $ pack filename
    x <- getAudio tagFile
    y <- getATag tagFile
    return (x, y)
    where

    getAudio Nothing = return Nothing
    getAudio (Just tagFile') = tagFileGetAudioProperties tagFile' >>= getProp

    getProp Nothing = return Nothing
    getProp (Just prop') = return . Just =<< Audio <$> audioPropertiesGetBitRate prop'
                                                   <*> audioPropertiesGetDuration prop'
                                                   <*> audioPropertiesGetSampleRate prop'
                                                   <*> audioPropertiesGetChannels prop'

    getATag Nothing = return Nothing
    getATag (Just tagFile') = tagFileGetTag tagFile' >>= getTP

    getTP Nothing = return Nothing
    getTP (Just tag) =  return . Just =<< ATag <$> tagGetAlbum tag
                                               <*> tagGetArtist tag
                                               <*> tagGetComment tag
                                               <*> tagGetGenre tag
                                               <*> tagGetTitle tag
                                               <*> tagGetTrack tag
                                               <*> tagGetYear tag

ratedStream :: String -> IO (S.InputStream ByteString)
ratedStream fn = do
    properties <- getAudio fn
    case properties of
         (Just audio, _) -> ratedStream' (duration audio) (bitRate audio) fn
         _ -> S.nullInput
    where
    ratedStream' :: Int -> Int -> String -> IO (S.InputStream ByteString)
    ratedStream' songTime bit fn = do
        handle <- openBinaryFile fn ReadMode
        S.atEndOfInput (hClose handle) =<< handleToInputStream songTime bit handle

handleToInputStream :: Int -> Int -> Handle -> IO (S.InputStream ByteString)
handleToInputStream songTime rate h = do
    let rate' = toDouble $ 1024 * rate 
    lock <- newEmptyMVar 
    forkIO $ threadDelay (songTime * 1000000) >> putMVar lock ()
    size <- newIORef 0
    time <- getCurrentTime
    S.makeInputStream (f lock rate' size time)
  where
  toDouble :: Real a => a -> Double
  toDouble = fromRational . toRational
  
  f :: MVar () -> Double -> (IORef Int) -> UTCTime -> IO (Maybe ByteString)
  f lock rate size time = do
      x <- BS.hGetSome h bUFSIZ
      s <- atomicModifyIORef size $ \x -> (x + bUFSIZ, x + bUFSIZ)
      void . pause $ toDouble $ s * 8
      if BS.null x
         then readMVar lock >> return Nothing
         else return $! Just x
      where 
      pause :: Double -> IO ()
      pause s = do
          currentTime <- getCurrentTime
          let diff = toDouble $ diffUTCTime currentTime time 
              currentRate = s / diff
          when (currentRate > rate) $ do
              threadDelay 10000
              pause s
          return ()
      
bUFSIZ = 32768
