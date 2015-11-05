module Main where
import Control.Monad (unless, forever)
import Network.Socket
import Data.Time
import Control.Exception
import System.IO
import System.Environment
import Control.Concurrent

data SType = Syn | SynAck | Ack | Fin deriving (Show, Read)

data CState = Closed | Listen | SynSent | SynReceived | Established

data Seg = Empty | Full {
  stype :: SType,
  seqnum :: Int,
  acknum :: Int,
  dat :: String
} deriving Show

instance Show Seg where
  show Empty = ""
  show (Seg t s a d) = unwords [(show t), (show s), (show a), d]

data Client = Client {
  buffer :: [(Seg, UTCTime)],
  cstate :: CState
}

-- whatToSend :: CState -> String -> Segment
-- whatToSend Closed _ = Empty
-- whatToSend Listen _ = Empty
-- whatToSend

-- Messy monad stuffs

timestamp :: String -> IO ()
timestamp s =
  do
    t <- getCurrentTime
    hPutStrLn stderr $ "<" ++ (show t) ++ "> " ++ s

getSocket :: String -> String -> IO Socket
getSocket host port =
  do
    (serveraddr:_) <- getAddrInfo Nothing (Just host) (Just port)
    s <- socket (addrFamily serveraddr) Datagram defaultProtocol
    connect s (addrAddress serveraddr)
    return s

receive :: Socket -> Chan String -> IO ()
receive s received =
  do
    fromServer <- recv s 1024
    timestamp "[revc SOMETHING] todo"
    writeChan received fromServer

talk :: Client -> Socket -> Chan String -> IO ()
talk client s received =
  do
    line <- getLine
    let client = addToBuffer client line
    -- sendMe <- whatToSend (cstate client) line
    timestamp $ "[send data] " ++ line
    send s line
    isEmpty <- isEmptyChan received
    unless isEmpty $ do
      response <- readChan received
      timestamp "[revc ack] todo"
    eof <- isEOF
    unless eof $ talk s received

gogo :: Socket -> IO ()
gogo s =
  do
    let client = Client [] Closed
    received <- newChan
    receiving <- forkIO $ receive s received
    let init = serializeSeg $ Seg Syn 0 0 ""
    send s line
    timestamp $ "[send syn] "
    talk client s received

main :: IO ()
main = do
    args <- getArgs
    let
      splitMe = words $ map (\ x -> if x == ':' then ' ' else x) (args!!0)
      host = (splitMe!!0)
      port = (splitMe!!1)
    withSocketsDo $ bracket (getSocket host port) sClose gogo
