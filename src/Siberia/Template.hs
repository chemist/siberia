{-# LANGUAGE OverloadedStrings #-}
module Siberia.Template where

import Text.Blaze.Html5
import Text.Blaze.Html5.Attributes
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Text.Blaze.Renderer.Pretty
import Control.Monad
import Siberia.Data
import Data.ByteString.Char8 (unpack)


index :: Site -> Html
index x = do
    H.head $ do
        H.title "Siberia streaming server"
        link ! href "static/css/bootstrap.css" ! rel "stylesheet"
    body $ do
        navbar
        bodyPage x
        footer'
        
navbar :: Html
navbar = do
    H.div ! A.class_ "navbar" $ do
        H.div ! A.class_ "navbar-inner" $ do
            H.div ! A.class_ "container" $ do
                a ! A.class_ "brand" ! href "/" ! target "_self" $ "Siberia"
                H.ul ! A.class_ "nav" $ do
                    H.li $ a ! href "/" $ "Home"
                    H.li $ a ! href "/status" $ "Status"
                    H.li $ a ! href "/stream" $ "All streams"
                    H.li $ a ! href "/save" $ "Save all"
                

bodyPage :: Site -> Html
bodyPage HomePage = do
    p "home page"
bodyPage (StreamsPage x) = do
    H.div ! A.class_ "streams" $ do
        H.h5 "Stream from local files"
        H.div ! A.class_ "local" $ do
            H.table ! A.class_ "table table-striped" $ do
                H.tbody $ forM_ (filter onlyLocal x) radioToHtml
        H.h5 "Proxy stream"
        H.div ! A.class_ "proxy" $ do
            H.table ! A.class_ "table table-striped" $ do
                H.tbody $ forM_ (filter onlyProxy x) radioToHtml
    where
    onlyLocal Local{} = True
    onlyLocal _ = False
    onlyProxy Proxy{} = True
    onlyProxy _ = False
    localUrl y = concat ["http://", host' y, ":", port' y, unpack $ unpackRid $ rid y]
    host' y = let Just (h,_) = hostPort y
              in h
    port' y = let Just (_,p) = hostPort y
              in show p
    radioToHtml :: Radio -> Html
    radioToHtml y@Proxy{} = do
        H.tr $ do
            H.td $ H.unsafeByteString $ unpackRid $ rid y
            H.td $ H.toHtml $ show $ url y
            H.td $ do
                a ! href (H.toValue $ localUrl y) $ H.unsafeByteString $ unpackRid $ rid y
            H.td $ H.toHtml $ show $ connections $ pid y
    radioToHtml y@Local{} = do
        H.tr $ do
            H.td $ H.unsafeByteString $ unpackRid $ rid y
            
bodyPage _ = undefined

unpackRid (RadioId x) = x
    
footer' :: Html
footer' = do
    p "footer here"

