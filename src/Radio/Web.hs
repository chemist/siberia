{-# LANGUAGE OverloadedStrings #-}
module Radio.Web where

import           BasicPrelude
import           Prelude             ()

import           Control.Applicative
import           Data.Aeson
import           Snap.Core           (Method (..), Snap, dir, emptyResponse,
                                      finishWith, getParam, ifTop, method,
                                      readRequestBody, route, setResponseCode,
                                      writeBS, writeLBS, writeLBS, writeText)
import           Snap.Http.Server    (quickHttpServe)
import           Snap.Util.FileServe (serveDirectory, serveFile)

import           Radio.Internal     

web :: Web ()
web =  ifTop (serveFile "static/index.html") 
       <|> method GET ( route [ ("server/stats", statsHandler )
                              , ("stream", getStreamHandler )
                              , ("stream/:sid", streamHandlerById )
                              , ("stream/:sid/metadata", streamMetaHandler )
                              , ("save", saveHandler)
                              ] )                                              
       <|> method POST ( route [ ("stream/:sid", postStreamHandler ) ] )     
       <|> method DELETE ( route [ ("stream/:sid", deleteStreamHandler ) ] )
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
        meta' <- get (ById (RadioId $ "/" <> i)) :: Web (Maybe Meta)
        (writeLBS . encode) meta'


errorWWW :: Int -> Web ()
errorWWW code = finishWith $ setResponseCode code emptyResponse

