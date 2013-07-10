{-# LANGUAGE OverloadedStrings #-}
module Siberia.YandexDisk where
import Data.ByteString

main = print "hello"


idYandex, passYandex :: ByteString
idYandex = ""
passYandex = ""


oauthUrlYandex :: ByteString
oauthUrlYandex = "oauth.yandex.ru"

oauthPathYandex :: ByteString
oauthPathYandex = "/token"

oauthUrl :: ByteString 
oauthUrl = "https://oauth.yandex.ru/token"
