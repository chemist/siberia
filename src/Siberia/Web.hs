{-# LANGUAGE OverloadedStrings #-}
module Siberia.Web where

import           Control.Applicative
import           Control.Monad
import Control.Monad.IO.Class
import           Control.Monad.RWS.Lazy (liftIO)
import           Data.Aeson
import           Data.ByteString        (ByteString)
import           Data.ByteString.Char8  (pack, unpack)
import Data.ByteString.Lazy (fromStrict)
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString as B
import           Data.Monoid            ((<>))
import           Snap.Core              (Method (..), dir, redirect, emptyResponse,
                                         finishWith, getParam, ifTop, method, getRequest,
                                         readRequestBody, route, routeLocal,
                                         setResponseCode, writeLBS, writeBS,
                                         writeText)
import qualified Snap.Core as SC
import qualified Snap.Internal.Http.Types as SC
import           Snap.Util.FileServe    (serveDirectory, serveFile)

import qualified Data.Collections       as Collections
import           Data.List              (sort)
import           Data.Maybe             (fromJust, isJust, isNothing)
import qualified Data.Text              as T
import           Debug.Trace
import           Paths_siberia
import           Siberia.Internal
import           Siberia.YandexDisk
import           Snap.Util.FileUploads
import           System.Directory
import qualified Network.Http.Client as H
import qualified System.IO.Streams as S
import OpenSSL (withOpenSSL)
import Network.HTTP.Base (urlEncode)
import Network.URI


web :: Web ()
web =  liftIO getDataDir >>= \dataDir -> ifTop (serveFile $ dataDir <> "/static/index.html")
       <|> method GET    ( routeLocal [ ("server/stats", statsHandler )
                                      , ("play", (serveFile $ dataDir <> "/static/pl.html"))
                                      , ("stream", getStreamHandler )
                                      , ("stream/:sid", streamHandlerById )
                                      , ("stream/:sid/metadata", streamMetaHandler )
                                      , ("stream/:sid/stats", streamStatsHandler )
                                      , ("playlist/:sid",         getPlaylist)
                                      , ("save", saveHandler)
                                      , ("ya/:sid" , yandexHandler)
                                      , ("verification_code", yandexOauth)
                                      ] )
       <|> method POST   ( routeLocal [ ("stream/:sid", postStreamHandler )
                                      , ("playlist/:sid", changePlaylist)
                                      , ("audio/:sid"  , postSongAdd)
                                      , ("audio/link/:sid" , postLinkSongAdd)
                                      ] )
       <|> method DELETE ( routeLocal [ ("stream/:sid", deleteStreamHandler )
                                      , ("audio/:sid/:fid" , deleteSong)
                                      ] )
       <|> dir "static" (serveDirectory (dataDir <> "/static"))

yandexHandler :: Web ()
yandexHandler = do
    sid <- getParam "sid"
    maybe (errorWWW 400) codeRequest sid
    where 
    codeRequest st = redirect $ "https://oauth.yandex.ru/authorize?response_type=token&client_id=" <> idYandex <> "&state=" <> st

{-
 POST /token HTTP/1.1
 Host: oauth.yandex.ru
 Content-type: application/x-www-form-urlencoded
 Content-Length: <length>

grant_type=authorization_code&code=<code>&client_id=<client_id>&client_secret=<client_secret>
-}
yandexOauth :: Web ()
yandexOauth = do
    r <- getRequest
    liftIO $ print $ SC.rqPathInfo r
    liftIO $ print $ SC.rqQueryString r
    liftIO $ print $ SC.rqContextPath r
    token <- getParam "access_token"
    tokenType <- getParam "token_type"
    st <- getParam "state"
    liftIO $ print token
    liftIO $ print tokenType
    liftIO $ print st
        
    
    

statsHandler :: Web ()
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

-- | get playlist
-- curl http://localhost:8000/playlist/local
-- [{"file":"music4.mp3","position":4},{"file":"music3.mp3","position":3},{"file":"music2.mp3","position":2}]
getPlaylist :: Web ()
getPlaylist = do
    sid <- getParam "sid"
    maybe (errorWWW 400) listSong sid
    where
      listSong :: ByteString -> Web ()
      listSong i = do
          isInBase <- member (toById i)
          unless isInBase $ errorWWW 403
          list <- getD (toById i) :: Web (Maybe Playlist)
          maybe (errorWWW 412) (writeLBS . encode) list

-- add downloader here, afther add link
postLinkSongAdd :: Web ()
postLinkSongAdd = undefined

uploadPolicy :: UploadPolicy
uploadPolicy = setMaximumFormInputSize limitSizeForUpload defaultUploadPolicy

-- | upload file to server
-- | curl -F name=test -F filedata=@music.mp3  http://localhost:8000/song/local -v
postSongAdd :: Web ()
postSongAdd = do
    sid <- getParam "sid"
    maybe (errorWWW 400) makePath sid
    dataDir <- liftIO getDataDir
    liftIO $ createDirectoryIfMissing True $ dataDir <> tempDir
    let Just channelFolder = unpack <$> sid
    handleFileUploads (dataDir <> tempDir) uploadPolicy perPartUploadPolicy $ handlerUploads channelFolder
    errorWWW 200
    where
      makePath :: ByteString -> Web ()
      makePath i = do
          isInBase <- member (toById i)
          unless isInBase $ errorWWW 403
          dataDir <- liftIO getDataDir
          liftIO $ createDirectoryIfMissing True $ dataDir <> musicDirectory <> unpack i
      perPartUploadPolicy :: PartInfo -> PartUploadPolicy
      perPartUploadPolicy _ = allowWithMaximumSize limitSizeForUpload

      handlerUploads :: String -> [(PartInfo, Either PolicyViolationException FilePath)] -> Web ()
      handlerUploads channelFolder = mapM_ fun
          where fun :: (PartInfo, Either PolicyViolationException FilePath) -> Web ()
                fun (p, Left e) = say . T.pack $ "\nerror when upload file \n\t" ++ show p ++ "\t" ++ show e
                fun (p, Right path) = do
                    let Just filename = unpack <$> partFileName p
                    say . T.pack $ "\nupload file " ++ filename
                    dataDir <- liftIO getDataDir
                    liftIO $ renameFile path $ dataDir <> musicDirectory <> channelFolder <> "/" <> filename
                    pl <- getD (toById (pack channelFolder)) :: Web (Maybe Playlist)
                    let uri = nullURI { uriScheme = "file:", uriPath = filename }
                    case pl :: Maybe Playlist of
                         Nothing -> setD (toById (pack channelFolder)) $ Just (Collections.singleton $ Song 0 uri Nothing Nothing Nothing :: Playlist)
                         Just pl' -> do
                             let Song n _ _ _ _ = Collections.maximum pl'
                             setD (toById (pack channelFolder)) $ Just $ Collections.insert (Song (n + 1) uri Nothing Nothing Nothing) pl'

-- | delete song from playlist
-- dont remove file from filesystem
--  DELETE request like http://localhost:8000/song/local/3
deleteSong :: Web ()
deleteSong = do
    sid <- getParam "sid"
    fid <- getParam "fid"
    trace (show fid) $ case (sid, fid) of
         (Just i, Just n) -> do
             isInBase <- member (toById i)
             unless isInBase $ errorWWW 403
             case reads $ unpack n of
                  [] -> errorWWW 400
                  [(n', _)] -> rmSong (Song n' nullURI Nothing Nothing Nothing ) i
                  _ -> errorWWW 400
         _ -> errorWWW 400
    where
      rmSong :: Song -> ByteString -> Web ()
      rmSong song i = do
          list <- getD (toById i) :: Web (Maybe Playlist)
          let isLast = 1 > (Collections.size $ removeSongFromPlaylist song <$> list)
          case isLast of
               False -> setD (toById i) $ removeSongFromPlaylist song <$> list
               True  -> setD (toById i) (Nothing :: Maybe Playlist)
          errorWWW 200

-- | mv song in playlist
-- curl http://localhost:8000/playlist/local -d '{"file":"music1.mp3","position":0}'
-- return new playlist
changePlaylist :: Web ()
changePlaylist = do
    sid <- getParam "sid"
    song <- decode <$> readRequestBody 1024 :: Web (Maybe Song)
    unless (isJust song) $ errorWWW 400
    maybe (errorWWW 400) (mv $ fromJust song) sid
    where
      mv :: Song -> ByteString -> Web ()
      mv song i = do
          isInBase <- member (toById i)
          unless isInBase $ errorWWW 403
          list <- getD (toById i) :: Web (Maybe Playlist)
          when (isNothing list) $ errorWWW 403
          setD (toById i) $ moveSongInPlaylist song <$> list
          writeLBS . encode $ moveSongInPlaylist song <$> list




removeSongFromPlaylist :: Song -> Playlist -> Playlist
removeSongFromPlaylist s p = let list = Collections.filter (\(Song x _ _ _ _) -> x /= idi s) p
                                 sortedPair = zip (sort $ Collections.toList list) [0 .. ]
                             in Collections.fromAscList $ map (\(Song _ x a b c, y) -> Song y x a b c) sortedPair


moveSongInPlaylist :: Song -> Playlist -> Playlist
moveSongInPlaylist s@(Song position filename _ _ _) p = 
  let list = sort $ Collections.toList $ Collections.filter (\(Song _ f _ _ _) -> f /= filename) p
      h = take position list
      t = drop position list
  in Collections.fromAscList $ map (\(Song _ x a b c, y) -> Song y x a b c) $ zip (h ++ [s] ++ t) [0 .. ]

toById :: ByteString -> Radio
toById x = ById . RadioId $ "/" <> x

deleteStreamHandler::Web ()
deleteStreamHandler = do
    param <- getParam "sid"
    maybe (errorWWW 400) rmSt param
    where
      rmSt i = do
          result <-  remove (toById i)
          errorWWW (if result then 200 else 403)



streamHandlerById::Web ()
streamHandlerById = do
    param <- getParam "sid"
    maybe (errorWWW 400) getStream param
    where
      getStream i = do
          isInBase <- member (toById i)
          unless isInBase $ errorWWW 403
          st <- getD (toById i) :: Web Radio
          (writeLBS . encode) st

streamMetaHandler :: Web ()
streamMetaHandler = do
    sid <- getParam "sid"
    maybe (errorWWW 400) sendMeta  sid
    where
    sendMeta :: ByteString -> Web ()
    sendMeta i = do
        isInBase <- member (toById i)
        unless isInBase $ errorWWW 403
        meta' <- getD (toById i) :: Web (Maybe Meta)
        (writeLBS . encode) meta'

streamStatsHandler :: Web ()
streamStatsHandler = do
    sid <- getParam "sid"
    maybe (errorWWW 400) sendStatus sid
    where
    sendStatus :: ByteString -> Web ()
    sendStatus i = do
        isInBase <- member (toById i)
        unless isInBase $ errorWWW 403
        st <- getD (toById i):: Web Status
        (writeLBS . encode) st


errorWWW :: Int -> Web ()
errorWWW code = finishWith $ setResponseCode code emptyResponse

