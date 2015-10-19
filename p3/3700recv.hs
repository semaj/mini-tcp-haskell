module Main where
import Control.Monad (unless)
import System.IO
import Network.Socket
import Control.Exception
import System.Random
import Data.Time.Clock

connectMe :: String -> IO Socket
connectMe port =
  do
    (serveraddr:_) <- getAddrInfo
                      (Just (defaultHints {addrFlags = [AI_PASSIVE]}))
                      Nothing (Just port)
    sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
    bindSocket sock (addrAddress serveraddr)
    return sock

timestamp :: String -> IO ()
timestamp s =
  do
    t <- getCurrentTime
    hPutStrLn stderr $ "<" ++ (show t) ++ "> " ++ s

main :: IO ()
main =
  do
    r <- getStdRandom $ randomR (1024, 65535)
    let rS = show (r :: Int)
    timestamp $ "[bound] " ++ rS
    withSocketsDo $ bracket (connectMe rS) sClose handler

handler :: Socket -> IO ()
handler conn = do
    (msg,n,d) <- recvFrom conn 1024
    timestamp $ "[recv data] " ++ msg
    unless (null msg) $ sendTo conn "ACK" d >> handler conn
