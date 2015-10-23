module TCP where
import Data.Hashable
import Control.Concurrent
import Data.Time
import Data.Maybe
import Data.List.Split
import Data.List

---- Constants

splitter = "|"
-- mss = 500
segmentExpiryTime :: Float
segmentExpiryTime = 0.5 -- sec

---- Data

data Type = Data | Ack | Fin deriving (Read, Eq)

instance Show Type where
  show Data = "0"
  show Ack = "1"
  show Fin = "2"

data CState = Finishing | Close | Established deriving (Show, Eq)

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

isDoneSending :: Client -> Bool
isDoneSending c = finishing && emptyUnacked && emptyToSend
      where emptyUnacked = 0 == (length $ (unacked c))
            emptyToSend = 0 == (length $ (toSend c))
            finishing = (cstate c) == Finishing

stepClient :: Client -> UTCTime -> Maybe Seg -> Maybe String -> Client
stepClient c now fromServer fromStdin = (sendUnsent (retry (addToUnsent (recAck c fromServer) fromStdin) now) now)

isClosed :: Client -> Bool
isClosed c = (cstate c) == Close

isExpired :: Float -> UTCTime -> (Seg, UTCTime) -> Bool
isExpired d now (_, old) = (segmentExpiryTime * d) > (realToFrac (abs $ diffUTCTime old now))

recAck :: Client -> Maybe Seg -> Client
recAck c Nothing = c
recAck c@(Client Finishing _ _ _ _ _ _ _) (Just (Seg Fin _ _ _)) = c { cstate = Close }
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
addToUnsent c (Just s)
  | s == "#EOF#" = c { cstate = Finishing }
  | otherwise = c { unsent = (unsent c) ++ [newSeg], lastRead = newlastread }
    where newlastread = (lastRead c) + 1
          newSeg = hashSeg $ Seg Data newlastread s "NOHASHYET"

-- Monady stuff

readMaybe :: Read a => String -> Maybe a
readMaybe s = case reads s of
                  [(val, "")] -> Just val
                  _           -> Nothing

tryGet :: Chan a -> IO (Maybe a)
tryGet chan = do
  empty <- isEmptyChan chan
  if empty then
    return Nothing
  else do
    response <- readChan chan
    return $ Just response
