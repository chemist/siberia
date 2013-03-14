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
import           Radio.Internal      ()

web::Radio -> IO ()
web radio = quickHttpServe $ ifTop (serveFile "static/index.html") <|>
                             method GET ( route [ ("server/stats", statsHandler radio)
                                                      , ("stream", getStreamHandler radio)
                                                      , ("stream/:sid", streamHandlerById radio)
                                                      , ("stream/:sid/metadata", streamMetaHandler radio)
                                                      ])                                                  <|>
                             method POST ( route [ ("stream/:sid", postStreamHandler radio) ] )     <|>
                             method DELETE ( route [ ("stream/:sid", deleteStreamHandler radio) ] ) <|>
                             dir "static" (serveDirectory "./static")

statsHandler radio = writeText "stats"

getStreamHandler ::Radio -> Snap ()
getStreamHandler radio = do
        s <- liftIO $ allStream radio
        writeLBS $ encode s

postStreamHandler::Radio -> Snap ()
postStreamHandler radio = do
        info' <- decode <$> readRequestBody 1024  :: Snap (Maybe RadioInfo)
        case info' of
             Nothing -> finishWith $ setResponseCode 400 emptyResponse
             Just i -> do
                 result <- liftIO $ addStream radio i
                 if result
                    then writeLBS $ encode i
                    else finishWith $ setResponseCode 409 emptyResponse

deleteStreamHandler::Radio -> Snap ()
deleteStreamHandler radio = do
    param <- getParam "sid"
    maybe (finishWith $ setResponseCode 400 emptyResponse) rmSt param
    where
      rmSt i = do
          result <-  liftIO $ rmStream radio (RadioId i)
          finishWith $ setResponseCode (if result then 200 else 403) emptyResponse



streamHandlerById::Radio -> Snap ()
streamHandlerById radio = method GET $ do
    param <- getParam "sid"
    maybe justGetStream withParam param
    where
      justGetStream :: Snap ()
      justGetStream = writeText "clean param"
      withParam sid = do
          writeBS sid
          writeText "with param"

streamMetaHandler = undefined


