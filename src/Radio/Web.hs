{-# LANGUAGE OverloadedStrings #-}
module Radio.Web where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.RWS.Lazy (liftIO, tell)
import           Data.Aeson
import           Data.ByteString        (ByteString)
import           Data.ByteString.Char8  (unpack, pack)
import           Data.Monoid            ((<>))
import           Snap.Core              (Method (..), Snap, dir, emptyResponse,
                                         finishWith, getParam, ifTop, method,
                                         readRequestBody, route,
                                         setResponseCode, writeBS, writeLBS,
                                         writeLBS, writeText)
import           Snap.Http.Server       (quickHttpServe)
import           Snap.Util.FileServe    (serveDirectory, serveFile)

import           Data.Cycle
import qualified Data.Collections as Collections
import           Debug.Trace
import           Radio.Internal
import           Snap.Util.FileUploads
import           System.Directory
import qualified Data.Text as T
import Data.Maybe (isJust, fromJust)
import Data.List (sort)


web :: Web ()
web =  ifTop (serveFile "static/index.html")
       <|> method GET ( route [ ("server/stats", statsHandler )
                              , ("stream", getStreamHandler )
                              , ("stream/:sid", streamHandlerById )
                              , ("stream/:sid/metadata", streamMetaHandler )
                              , ("stream/:sid/stats", streamStatsHandler )
                              , ("song/:sid",         getSongList)
                              , ("save", saveHandler)
                              ] )
       <|> method POST ( route [ ("stream/:sid", postStreamHandler )
                               , ("song/:sid"  , postSongAdd)
                               ] )
       <|> method DELETE ( route [ ("stream/:sid", deleteStreamHandler ) 
                                 , ("song/:sid" , deleteSong)
                                 ] )
       <|> dir "static" (serveDirectory "./static")

statsHandler = writeText "stats"

saveHandler::Web ()
saveHandler = save "radiobase"

getStreamHandler :: Web ()
getStreamHandler = do
        s <- list :: Web [Radio]
        writeLBS $ encode s

postStreamHandler::Web ()
postStreamHandler = do
        info' <- decode <$> readRequestBody 1024  :: Web (Maybe Radio)
        case info' of
             Nothing -> errorWWW 400
             Just i -> do
                 (result, infoWithHostPort) <- create i
                 if result
                    then writeLBS $ encode infoWithHostPort
                    else errorWWW 400

getSongList :: Web ()
getSongList = do
    sid <- getParam "sid"
    maybe (errorWWW 400) listSong sid
    where
      listSong :: ByteString -> Web ()
      listSong i = do
          isInBase <- member (ById (RadioId $ "/" <> i))
          unless isInBase $ errorWWW 403
          list <- getD (ById (RadioId $ "/" <> i)) :: Web Playlist
          writeLBS . encode $ list


uploadPolicy :: UploadPolicy
uploadPolicy = setMaximumFormInputSize 10000000 defaultUploadPolicy

-- upload
-- curl -F name=test -F filedata=@music.mp3  http://localhost:8000/song/local -v

postSongAdd :: Web ()
postSongAdd = do
    sid <- getParam "sid"
    maybe (errorWWW 400) makePath sid
    liftIO $ createDirectoryIfMissing True tempDir
    let Just channelFolder = unpack <$> sid
    handleFileUploads tempDir uploadPolicy perPartUploadPolicy $ handlerUploads channelFolder
    errorWWW 200
    where
      makePath :: ByteString -> Web ()
      makePath i = do
          isInBase <- member (ById (RadioId $ "/" <> i))
          unless isInBase $ errorWWW 403
          liftIO $ createDirectoryIfMissing True $ musicDirectory <> unpack i
      perPartUploadPolicy :: PartInfo -> PartUploadPolicy
      perPartUploadPolicy part = trace (show part) $ allowWithMaximumSize 10000000
      handlerUploads :: String -> [(PartInfo, Either PolicyViolationException FilePath)] -> Web ()
      handlerUploads channelFolder x = do
          mapM_ fun x
          where fun :: (PartInfo, Either PolicyViolationException FilePath) -> Web ()
                fun (p, Left e) = say . T.pack $ "\nerror when upload file \n\t" ++ show p ++ "\t" ++ show e 
                fun (p, Right path) = do
                    let Just filename = unpack <$> partFileName p
                    say . T.pack $ "\nupload file " ++ filename
                    liftIO $ renameFile path $ musicDirectory <> channelFolder <> "/" <> filename
                    setD (ById (RadioId $ "/" <> (pack channelFolder))) $ Song 0 filename

deleteSong :: Web ()
deleteSong = do
    sid <- getParam "sid"
    song <- decode <$> readRequestBody 1024  :: Web (Maybe Song)
    unless (isJust song) $ errorWWW 400
    maybe (errorWWW 400) (rmSong $ fromJust song) sid
    where 
      rmSong :: Song -> ByteString -> Web ()
      rmSong song i = do
          isInBase <- member (ById (RadioId $ "/" <> i))
          unless isInBase $ errorWWW 403
          list <- getD (ById (RadioId $ "/" <> i)) :: Web Playlist
          setD (ById (RadioId $ "/" <> i)) $ removeSongFromPlaylist song list
          errorWWW 200
          

removeSongFromPlaylist :: Song -> Playlist -> Playlist
removeSongFromPlaylist s p = let list = Collections.filter (/= s) p
                                 sortedPair = zip (sort $ Collections.toList list) [0 .. ]
                             in Collections.fromList $ map (\(Song _ x, y) -> Song y x) sortedPair



deleteStreamHandler::Web ()
deleteStreamHandler = do
    param <- getParam "sid"
    maybe (errorWWW 400) rmSt param
    where
      rmSt i = do
          result <-  remove $ ById (RadioId i)
          errorWWW (if result then 200 else 403)



streamHandlerById::Web ()
streamHandlerById = do
    param <- getParam "sid"
    maybe justGetStream withParam param
    where
      justGetStream :: Web ()
      justGetStream = writeText "clean param"
      withParam sid = do
          writeBS sid
          writeText "with param"

streamMetaHandler :: Web ()
streamMetaHandler = do
    sid <- getParam "sid"
    maybe (errorWWW 400) sendMeta  sid
    where
    sendMeta :: ByteString -> Web ()
    sendMeta i = do
        isInBase <- member (ById (RadioId $ "/" <> i))
        unless isInBase $ errorWWW 403
        meta' <- getD (ById (RadioId $ "/" <> i)) :: Web (Maybe Meta)
        (writeLBS . encode) meta'

streamStatsHandler :: Web ()
streamStatsHandler = do
    sid <- getParam "sid"
    maybe (errorWWW 400) sendStatus sid
    where
    sendStatus :: ByteString -> Web ()
    sendStatus i = do
        isInBase <- member (ById (RadioId $ "/" <> i))
        unless isInBase $ errorWWW 403
        st <- getD (ById (RadioId $ "/" <> i)):: Web Status
        (writeLBS . encode) st


errorWWW :: Int -> Web ()
errorWWW code = finishWith $ setResponseCode code emptyResponse

