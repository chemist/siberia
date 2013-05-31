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
  } deriving (Show)

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
         (Just audio, Just tag) -> ratedStream' (bitRate audio) fn
         _ -> S.makeInputStream (pure Nothing)
    where
    ratedStream' :: Int -> String -> IO (S.InputStream ByteString)
    ratedStream' bit fn = do
        handle <- openBinaryFile fn ReadMode
        handleToInputStream bit handle

handleToInputStream :: Int -> Handle -> IO (S.InputStream ByteString)
handleToInputStream rate h = do
    let rate' = toDouble $ 1024 * rate 
    size <- newIORef 0
    time <- getCurrentTime
    S.makeInputStream (f rate' size time)
  where
  toDouble :: Real a => a -> Double
  toDouble = fromRational . toRational
  
  f :: Double -> (IORef Int) -> UTCTime -> IO (Maybe ByteString)
  f rate size time = do
      x <- BS.hGetSome h bUFSIZ
      s <- atomicModifyIORef size $ \x -> (x + bUFSIZ, x + bUFSIZ)
      pause $ toDouble $ s * 8
      if BS.null x 
         then do
             hClose h 
             return $! Nothing 
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
      
bUFSIZ = 32752

