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

import           Radio.Data
import           Radio.Internal     

web :: Web ()
web =  ifTop (serveFile "static/index.html") 
       <|> method GET ( route [ ("server/stats", statsHandler )
                              , ("stream", getStreamHandler )
                              , ("stream/:sid", streamHandlerById )
                              , ("stream/:sid/metadata", streamMetaHandler )
                              ] )                                              
       <|> method POST ( route [ ("stream/:sid", postStreamHandler ) ] )     
       <|> method DELETE ( route [ ("stream/:sid", deleteStreamHandler ) ] )
       <|> dir "static" (serveDirectory "./static")

statsHandler = writeText "stats"

getStreamHandler :: Web ()
getStreamHandler = do
        s <- list :: Web [Radio]
        writeLBS $ encode s

postStreamHandler::Web ()
postStreamHandler = do
        info' <- decode <$> readRequestBody 1024  :: Web (Maybe Radio)
        case info' of
             Nothing -> finishWith $ setResponseCode 400 emptyResponse
             Just i -> do
                 (result, infoWithHostPort) <- create i
                 if result
                    then do
                        writeLBS $ encode infoWithHostPort
                    else finishWith $ setResponseCode 409 emptyResponse

deleteStreamHandler::Web ()
deleteStreamHandler = do
    param <- getParam "sid"
    maybe (finishWith $ setResponseCode 400 emptyResponse) rmSt param
    where
      rmSt i = do
          result <-  remove $ ById (RadioId i)
          finishWith $ setResponseCode (if result then 200 else 403) emptyResponse



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

streamMetaHandler = undefined


