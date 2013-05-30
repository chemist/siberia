module Siberia.Streamer where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Char8 (pack)
import Control.Applicative

import Audio.TagLib.TagLib


data Audio = Audio 
  { bitRate  :: Int
  , duration :: Int
  , sampleRate :: Int
  , channels   :: Int
  } deriving (Show)
  
data ATag = ATag
  { album :: String
  , artist :: String
  , comment :: String
  , genre :: String
  , title :: String
  , track :: Int
  , year :: Int
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
        
                      

