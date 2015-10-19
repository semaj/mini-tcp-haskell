module Main where
import Control.Monad (unless, forever)
import Network.Socket
import Data.Time
import Data.Maybe
import Data.List.Split
import Control.Exception
import System.IO
import System.Environment
import Control.Concurrent

---- Constants

segmentSize = 50

---- Data

data Type = Syn | SynAck | Data | Ack | Fin deriving (Show, Read)

data CState = Close | Listen | SynSent | SynReceived | Established deriving (Show, Eq)

data Seg = Empty | Seg {
  segtype :: Type,
  segseqnum :: Int,
  segacknum :: Int,
  dat :: String
}

instance Show Seg where
  show (Seg t s a d) = unwords [(show t), (show s), (show a), d]

data Client = Client {
  buffer :: [(Seg, UTCTime)],
  cstate :: CState,
  lastSeq :: Int,
  lastAck :: Int,
  messages :: [Seg]
} deriving Show

---- Segment Functions

parseSeg :: String -> Seg
parseSeg seg = Seg (read (splitUp!!0)) (read (splitUp!!1)) (read (splitUp!!2)) ""
    where splitUp = words seg

---- Client Functions

stepClient :: Client -> Maybe String -> Maybe (String, UTCTime) -> Client
stepClient c mServer (Just (mStdin, _)) = c { messages = [Seg Data 0 0 mStdin] }
stepClient c _ _ = c { messages = [] }

isClosed :: Client -> Bool
isClosed (Client _ Close _ _ _) = True
isClosed _ = False

-- prepend the segment to our buffer, with a timestamp
addToBuffer :: Client -> String -> UTCTime -> Client
addToBuffer (Client buffer state lastSeq lastAck messages) s time =
    Client ((newSeg, time):buffer) state newSeq newAck messages
        where newSeq = lastSeq + 1
              newAck = lastAck + 1
              newSeg = Seg Data newSeq newAck s

---- Monads / Sockets

-- Helpers

tryGet :: Chan a -> IO (Maybe a)
tryGet chan = do
  empty <- isEmptyChan chan
  if empty then
     return Nothing
   else do
     response <- readChan chan
     return $ Just response

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

-- Forked IO functions, continuously running

receiveFromServer :: Socket -> Chan String -> IO ()
receiveFromServer s fromServer = do
  forever $ do
    message <- recv s 1024
    -- parsing the message should occur here
    timestamp "[recv ack] offset goes here"
    writeChan fromServer message

sendToServer :: Socket -> Chan Seg -> IO ()
sendToServer s toServer = do
  forever $ do
    segment <- readChan toServer
    -- pulling offset
    send s $ dat segment
    timestamp "[send data] todo"

clientLoop :: Client
              -> Chan String
              -> Chan (String, UTCTime)
              -> Chan Seg
              -> IO ()
clientLoop c fromServer fromStdin toServer =
  do
    serverMessage <- tryGet fromServer
    stdinMessage <- tryGet fromStdin
    let nextClient = stepClient c serverMessage stdinMessage
    mapM (writeChan toServer) $ messages nextClient
    unless (isClosed nextClient) $ clientLoop nextClient fromServer fromStdin toServer

readStdin :: Socket -> Chan (String, UTCTime) -> IO ()
readStdin s fromStdin =
  forever $ do
    eof <- isEOF
    time <- getCurrentTime
    if eof then
      writeChan fromStdin ("#EOF#", time)
      else do
        line <- getLine
        let pieces = map (\ x -> (x, time)) $ chunksOf segmentSize line
        mapM (writeChan fromStdin) pieces
        return ()

---- Initialization

-- Initial run function. Sends syn (for now),
-- initiates channels, starts reading/writing loops, starts client loop

startAndSyn :: Socket -> IO ()
startAndSyn s =
  do
    fromServer <- newChan
    fromStdin <- newChan
    toServer <- newChan
    receiving <- forkIO $ receiveFromServer s fromServer
    sending <- forkIO $ sendToServer s toServer
    reading <- forkIO $ readStdin s fromStdin
    let init = show $ Seg Syn 0 0 ""
        client = Client [] SynSent 0 0 []
    send s init
    timestamp $ "[send syn] "
    clientLoop client fromServer fromStdin toServer

-- Build the socket, run startAndSyn

main :: IO ()
main = do
    args <- getArgs
    let
      splitMe = splitOn ":" (args!!0)
      host = (splitMe!!0)
      port = (splitMe!!1)
    withSocketsDo $ bracket (getSocket host port) sClose startAndSyn
