module Main where
import Control.Monad (unless, forever, when)
import Network.Socket
import Data.Hashable
import Data.Time
import Data.Maybe
import Data.List.Split
import Control.Exception
import System.IO
import System.Environment
import Control.Concurrent
import Data.List
import System.Exit

---- Summary:
-- Issues:
-- Dropping packets:
--    If don't receive an ack, resend
-- Duplicating packets:
--    Ignore packets w/ seqnums that you've received before
-- Damaged packets:
--    Hash the text perhaps
-- Delayed packets:
--    Timeout packets after acks, resend them
--    If too many retransmissions

---- Constants

splitter = "|"
mss = 500
segmentExpiryTime :: Float
segmentExpiryTime = 0.5 -- sec

---- Data

data Type = Data | Ack | Fin deriving (Read, Eq)

-- Is this even necessary? Ack isn't.
instance Show Type where
  show Data = "0"
  show Ack = "1"
  show Fin = "2"

data CState = Close | Established deriving (Show, Eq)

data Seg = Seg {
  stype :: Type,
  seqNum :: Int,
  dat :: String,
  shash :: String
}

instance Eq Seg where
  (==) (Seg a b c d) (Seg e f g h) = a == e && b == f && c == g && d == h

instance Show Seg where
  -- what if space is in the file??
  show (Seg t s a h) = intercalate splitter [(show t), (show s), a, h]

data Client = Client {
  cstate :: CState,
  unacked :: [(Seg, UTCTime)],
  unsent :: [Seg],
  toSend :: [Seg],
  lastRead :: Int, -- last seq number read from stdin
  lastAcked :: Int, -- last seq num acked. if delta between this and any unacked packets is high, just resend those packets (or decrease the timeout)
  timeoutM :: Float, -- modifier (multiplicative) (how long to wait before something times out), this may have to change if the delay is huge and things are timing out quickly. when something times out, increase this. when we get something back, decrease this (maybe)
  cwnd :: Int
} deriving Show

---- Parsing functions

parseType :: String -> Maybe Type
parseType "0" = Just Data
parseType "1" = Just Ack
parseType "2" = Just Fin
parseType _ = Nothing

---- Segment Functions

hashSeg :: Seg -> Seg
hashSeg s@(Seg a b c _) = s { shash = show $ hash $ (show a) ++ (show b) ++ (show c) }

checkCorruption :: Maybe Seg -> Maybe Seg
checkCorruption Nothing = Nothing -- smells like a Monad goes here!
checkCorruption (Just s@(Seg _ _ _ oldhash)) = if oldhash == (shash (hashSeg s)) then Just s else Nothing

parseSeg :: Maybe String -> Maybe Seg
parseSeg Nothing = Nothing
parseSeg (Just seg) -- = Seg (read (splitUp!!0)) (read (splitUp!!1)) (read (splitUp!!2)) ""
  | (length splitUp) /= 4 = Nothing
  | (isNothing parsedType) || (isNothing parsedSeq) = Nothing
  | otherwise = checkCorruption $ Just $ Seg (fromJust parsedType)
                                             (fromJust parsedSeq)
                                             (splitUp!!2)
                                             (splitUp!!3)
    where splitUp = splitOn splitter seg
          parsedType = parseType (splitUp!!0)
          parsedSeq = readMaybe (splitUp!!1)


---- Client Functions

stepClient :: Client -> UTCTime -> Maybe Seg -> Maybe String -> Client
stepClient c now fromServer fromStdin = (sendUnsent (addToUnsent (recAck c fromServer) fromStdin) now)

isClosed :: Client -> Bool
isClosed c = (cstate c) == Close

isExpired :: Float -> UTCTime -> (Seg, UTCTime) -> Bool
isExpired d now (_, old) = (segmentExpiryTime * d) > (realToFrac (abs $ diffUTCTime old now))

recAck :: Client -> Maybe Seg -> Client
recAck c Nothing = c
recAck c (Just (Seg _ num _ _)) = c { unacked = newUnacked, lastAcked = (max (lastAcked c) num) }
      where newUnacked = filter (\(s,t) -> (seqNum s) /= num) (unacked c)

sendUnsent :: Client -> UTCTime -> Client
sendUnsent c now = c { unsent = ((unsent c) \\ sendMe),
                   unacked = (unacked c) ++ withTime,
                   toSend = (toSend c) ++ sendMe }
    where toTake = length $ (unsent c) -- length (toSend c)
          sendMe = take toTake (unsent c) -- this may change later depending on cwnd decisions
          withTime = map (\x -> (x,now)) sendMe

-- unacked is sorted from
retry :: Client -> UTCTime -> Client
retry client@(Client _ uacked _ tosend _ _ delta _) now = client { unacked = update,
                                                                   toSend = (tosend ++ noTime) }
          where expired = filter (isExpired delta now) uacked
                update = map (\segt@(s,_) -> if isExpired delta now segt then (s,now) else segt) uacked
                noTime = map fst expired

addToUnsent :: Client -> Maybe String -> Client
addToUnsent c Nothing = c
addToUnsent c (Just s) = c { unsent = (unsent c) ++ [newSeg], lastRead = newlastread }
      where newlastread = (lastRead c) + 1
            newSeg = hashSeg $ Seg Data newlastread s "NOHASHYET"


---- Monads / Sockets

-- Helpers

readMaybe :: Read a => String -> Maybe a
readMaybe s = case reads s of
                  [(val, "")] -> Just val
                  _           -> Nothing

sendServer :: Socket -> Seg -> IO ()
sendServer socket seg =
  do
    -- splitting should occur
    send socket $ show seg
    timestamp "[send data] todo"

isDone :: Maybe String -> Bool
isDone (Just "#EOF#") = True
isDone _ = False

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
