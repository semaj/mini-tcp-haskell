module Main where
import TCP
import Control.Monad (unless, forever, when, void)
import Network.Socket
import Data.Time
import Data.Maybe
import Data.List.Split
import Data.List
import Control.Exception
import System.IO
import System.Environment
import Control.Concurrent
import System.Exit
import Debug.Trace

---- Client specific code

data CState = Finishing | Close | Established deriving (Show, Eq)

data Client = Client {
  cstate :: CState,
  unacked :: [(Seg, UTCTime)],
  unsent :: [Seg],
  toSend :: [Seg],
  lastRead :: Int, -- last seq number read from stdin
  lastAcked :: Int, -- last seq num acked. if delta between this and any unacked packets is high, just resend those packets (or decrease the timeout)
  timeout :: Float, --
  window :: Int -- unused
} deriving Show

---- Client Functions

isDoneSending :: Client -> Bool
isDoneSending c = finishing && emptyUnacked && emptyToSend
  where emptyUnacked = 0 == (length $ (unacked c))
        emptyToSend = 0 == (length $ (toSend c))
        finishing = (cstate c) == Finishing

stepClient :: Client -> UTCTime -> Maybe Seg -> Maybe String -> Client
stepClient c now fromServer fromStdin = sendUnsent now $ retry now $ addToUnsent fromStdin $ recAck fromServer now c

isClosed :: Client -> Bool
isClosed c = (cstate c) == Close

isExpired :: Float -> UTCTime -> (Seg, UTCTime) -> Bool
isExpired timeout now (_, old) = timeout < (realToFrac (abs $ diffUTCTime old now))

-- parse nacks and immediately send those
recAck :: Maybe Seg -> UTCTime -> Client -> Client
recAck Nothing _ c = c
recAck (Just (Seg Fin _ _ _)) _ c@(Client Finishing _ _ _ _ _ _ _) = c { cstate = Close }
recAck (Just s@(Seg _ num _ _)) now c = c { unacked = update,
                                            lastAcked = (max (lastAcked c) num),
                                            toSend = (toSend c) ++ withoutTime }
    where newUnacked = filter (\(s,t) -> (seqNum s) /= num) (unacked c)
          nacks = parseNacks s
          nacked = filter (\ (ss,_) -> elem (seqNum ss) nacks) newUnacked
          update = map (\ segt@(ss,_) -> if elem segt nacked then (ss,now) else segt) newUnacked
          withoutTime = map fst nacked


sendUnsent :: UTCTime -> Client -> Client
sendUnsent now c = c { unsent = ((unsent c) \\ sendMe),
                       unacked = (unacked c) ++ withTime,
                       toSend = (toSend c) ++ sendMe }
    where toTake = (window c) --length $ (unsent c)
          sendMe = take toTake (unsent c)
          withTime = map (\ x -> (x,now)) sendMe

retry :: UTCTime -> Client -> Client
--retry now client@(Client _ uacked _ [] _ _ _) = client { toSend = uacked }
retry now client@(Client _ uacked _ tosend _ _ timeOut _) =
    client { unacked = update,
             toSend = (tosend ++ noTime),
             timeout = newTimeout}
    where expired = filter (isExpired timeOut now) uacked
          update = map (\ segt@(s,_) -> if elem segt expired then (s,now) else segt) uacked
          noTime = map fst expired
          newTimeout = timeOut

addToUnsent :: Maybe String -> Client  -> Client
addToUnsent Nothing c = c
addToUnsent (Just s) c
  | s == "#EOF#" = c { cstate = Finishing }
  | otherwise = c { unsent = (unsent c) ++ [newSeg], lastRead = newlastread }
      where newlastread = (lastRead c) + 1
            newSeg = hashSeg $ Seg Data newlastread s "NOHASHYET"

-- Helpers

sendServer :: Socket  -> Seg -> IO ()
sendServer socket seg =
  do
    let (start, len) = offsetLengthSeg seg
    when ((stype seg) == Data) $ timestamp $ "[send data] " ++ start ++ " (" ++ len ++ ") " ++ (show $ seqNum seg)
    void $ send socket $ show seg

getSocket :: String -> String -> IO Socket
getSocket host port =
  do
    (serveraddr:_) <- getAddrInfo Nothing (Just host) (Just port)
    s <- socket (addrFamily serveraddr) Datagram defaultProtocol
    connect s (addrAddress serveraddr)
    return s

printAck :: Maybe Seg -> IO ()
printAck Nothing = return ()
printAck (Just (Seg Fin _ _ _)) = return ()
printAck (Just s@(Seg Ack num dat _)) = timestamp $ "[recv ack] " ++ dat
  where (end,_) = offsetLengthSeg s

-- Forked IO functions, continuously running

receiveFromServer :: Socket -> Chan String -> IO ()
receiveFromServer s fromServer = do
  forever $ do
    message <- recv s 1024
    writeChan fromServer message

clientLoop :: Client -> Socket -> Chan String -> Chan String -> IO ()
clientLoop c s fromServer fromStdin =
  do
    -- get Maybe String from server/stdin. If nothing to read -> Nothing
    serverMessage <- tryGet fromServer
    stdinMessage <- tryGet fromStdin
    now <- getCurrentTime
    let parsedSeg = parseSeg serverMessage
        nextClient = stepClient c now parsedSeg stdinMessage
    printAck parsedSeg
    --putStrLn $ show $ map (seqNum . fst) $ unacked nextClient
    -- send to server concurrently
    forkIO $ void $ mapM (sendServer s) $ nub $ toSend nextClient
    let emptiedToSend = nextClient { toSend = [] }
    if (isDoneSending emptiedToSend)
    then do
      let fin = hashSeg $ Seg Fin (-1) "" ""
      finishUp (emptiedToSend { unsent = [fin] }) s fromServer
      timestamp "[completed]"
    else clientLoop emptiedToSend s fromServer fromStdin

finishUp :: Client -> Socket -> Chan String -> IO ()
finishUp c s fromServer =
  do
    serverMessage <- tryGet fromServer
    now <- getCurrentTime
    let nextClient = stepClient c now (parseSeg serverMessage) Nothing
    unless ((cstate nextClient) == Close) $ do
      mapM (sendServer s) $ toSend nextClient
      mapM (sendServer s) $ toSend nextClient
      mapM (sendServer s) $ toSend nextClient
      let emptiedToSend = nextClient { toSend = [] }
      close s
      --finishUp emptiedToSend s fromServer

readStdin :: Socket -> Chan String -> IO ()
readStdin s fromStdin =
  do
    -- lazy languages ftw.
    -- gets entire STDIN as a lazy string - map it into chunks
    -- and write it to our channel
    lines <- getContents
    mapM (writeChan fromStdin) $ chunksOf readInSize lines
    -- this EOF flag is for client use only
    writeChan fromStdin "#EOF#"

---- Initialization

-- Initial run function.
-- initiates channels, starts reading/writing loops, starts client loop

start :: Socket -> IO ()
start s =
  do
    -- concurrent channels (Go-like)
    fromServer <- newChan
    fromStdin <- newChan
    -- read from server/stdin concurrently, push to above channels
    receiving <- forkIO $ receiveFromServer s fromServer
    reading <- forkIO $ readStdin s fromStdin
    let client = Client Established [] [] [] 0 0 2.0 1000000
    clientLoop client s fromServer fromStdin
    -- stop the reading threads
    killThread receiving
    killThread reading
    close s

-- Build the socket, run start

main :: IO ()
main = do
    args <- getArgs
    let
      splitMe = splitOn ":" (args!!0)
      host = (splitMe!!0)
      port = (splitMe!!1)
    withSocketsDo $ bracket (getSocket host port) sClose start
