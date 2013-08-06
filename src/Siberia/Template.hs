{-# LANGUAGE OverloadedStrings #-}
module Siberia.Template where

import Text.Blaze.Html5
import Text.Blaze.Html5.Attributes
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Text.Blaze.Renderer.Pretty
import Control.Monad
import Siberia.Data


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
                    H.li $ a ! href "/streams" $ "All streams"
                    H.li $ a ! href "/saves" $ "Save all"
                

bodyPage HomePage = do
    p "home page"
bodyPage (StreamsPage x) = do
    H.div ! A.class_ "streams" $ do
        H.table ! A.class_ "table table-striped" $ do
            H.tbody $ forM_ x radioToHtml
    where
    radioToHtml :: Radio -> Html
    radioToHtml y = do
        H.tr $ do
            H.td $ H.unsafeByteString $ unpackRid $ rid y
            
bodyPage _ = undefined

unpackRid (RadioId x) = x
    
footer' :: Html
footer' = do
    p "footer here"

