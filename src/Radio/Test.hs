{-# LANGUAGE OverloadedStrings #-}
module Main where

import Radio.Data hiding (get)
import Radio.Internal

import           BasicPrelude hiding (take)
import qualified Prelude 
import qualified System.IO.Streams as S
import qualified System.IO.Streams.ByteString as S
import qualified System.IO.Streams.Handle as S
import qualified System.IO.Streams.Attoparsec as S
import Control.Monad
import Data.Text.Encoding as E
import Control.Concurrent
import Data.ByteString (take)
import System.IO 
import qualified Data.ByteString.Char8 as C
import           Data.Attoparsec              (parseOnly)
import           Data.Attoparsec.RFC2616
import           Network.Socket
import Control.Monad.State
import Data.IORef
import Data.Attoparsec.ByteString.Char8
import Control.Applicative




main = do
    is' <- makeConnect
    is <- S.parserToInputStream parserStream is' 
    state <- newIORef 0
    out <- checkStream state
    S.connect is out
        
checkStream :: IORef Integer -> IO (S.OutputStream Integer)
checkStream state = S.makeOutputStream $ fun state
    
fun :: IORef Integer -> Maybe Integer -> IO ()
fun _  Nothing = return $! ()
fun state (Just x) = do
    a <- readIORef state
    if a == 0
       then do
           modifyIORef state (\_ -> x) 
       else do
           if a + 1 == x
             then do 
               modifyIORef state (+1)
               return ()
             else do 
               print x
               modifyIORef state (\_ -> x)
  
parserStream :: Parser (Maybe Integer)
parserStream = (endOfInput >> pure Nothing ) <|> (Just <$> ( decimal <* space))


openConnection :: IO (S.InputStream ByteString, S.OutputStream ByteString)
openConnection = do
    is <- liftIO $ getAddrInfo (Just hints) (Just "127.0.0.1") (Just "2000")
    let addr = head is
    let a = addrAddress addr
    s <- liftIO $  socket (addrFamily addr) Stream defaultProtocol
    liftIO $ Network.Socket.connect s a
    (i,o) <- liftIO $ S.socketToStreams s
    return (i, o)
    where
       hints = defaultHints {addrFlags = [AI_ADDRCONFIG, AI_NUMERICSERV]}

makeConnect ::  IO (S.InputStream ByteString)
makeConnect = do
   (i, o) <- openConnection 
   getStream <- liftIO $ S.fromByteString "GET /test HTTP/1.0\r\nIcy-MetaData: 1\r\n\r\n"
   liftIO $ S.connect getStream o
   (response, headers) <- liftIO $ S.parseFromStream response i
   -- | @TODO обработать исключения
   liftIO $ print response
   liftIO $ print headers
   return i
 
