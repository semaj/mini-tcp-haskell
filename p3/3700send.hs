module Main where
import TCP
import Control.Monad (unless, forever, when)
import Network.Socket
import Data.Time
import Data.Maybe
import Data.List.Split
import Control.Exception
import System.IO
import System.Environment
import Control.Concurrent
import System.Exit

---- Client specific code

-- Helpers

sendServer :: Socket -> Seg -> IO ()
sendServer socket seg =
  do
    -- splitting should occur
    send socket $ show seg
    timestamp "[send data] todo"

isDone :: Maybe String -> Bool
isDone (Just "#EOF#") = True
isDone _ = False

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
    putStrLn message
    timestamp "[recv ack] offset goes here"
    writeChan fromServer message

-- sendToServer :: Socket -> Chan Seg -> IO ()
-- sendToServer s toServer = do
--   forever $ do
--     segment <- readChan toServer
--     -- pulling offset
--     send s $ dat segment
--     timestamp "[send data] todo"

clientLoop :: Client -> Socket -> Chan String -> Chan String -> IO ()
clientLoop c s fromServer fromStdin =
  do
    serverMessage <- tryGet fromServer
    stdinMessage <- tryGet fromStdin
    now <- getCurrentTime
    let stdinIsDone = isDone stdinMessage
        nextClient = stepClient c now (parseSeg serverMessage) stdinMessage
    -- the isDone message should trigger closing of the client
    mapM (sendServer s) $ toSend nextClient
    let emptiedToSend = nextClient { toSend = [] }
    putStrLn $ show emptiedToSend
    when (isClosed nextClient) $ exitSuccess
    clientLoop emptiedToSend s fromServer fromStdin

readStdin :: Socket -> Chan String -> IO ()
readStdin s fromStdin =
  do
    eof <- isEOF
    if eof then
      writeChan fromStdin "#EOF#"
      else do
        line <- getLine
        writeChan fromStdin line
        -- let pieces = chunksOf mss line
        -- mapM (writeChan fromStdin) pieces
        readStdin s fromStdin

---- Initialization

-- Initial run function. Sends syn (for now),
-- initiates channels, starts reading/writing loops, starts client loop

startAndSyn :: Socket -> IO ()
startAndSyn s =
  do
    fromServer <- newChan
    fromStdin <- newChan
    -- toServer <- newChan
    receiving <- forkIO $ receiveFromServer s fromServer
    -- sending <- forkIO $ sendToServer s toServer
    reading <- forkIO $ readStdin s fromStdin
    let client = Client Established [] [] [] 0 0 1.0 500
    -- send s init
    -- timestamp $ "[send syn] "
    clientLoop client s fromServer fromStdin

-- Build the socket, run startAndSyn

main :: IO ()
main = do
    args <- getArgs
    let
      splitMe = splitOn ":" (args!!0)
      host = (splitMe!!0)
      port = (splitMe!!1)
    withSocketsDo $ bracket (getSocket host port) sClose startAndSyn
