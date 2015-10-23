module Main where
import Control.Monad (unless, when)
import Data.List
import System.Exit
import System.IO
import Network.Socket
import Control.Exception
import System.Random
import Data.Time.Clock
import Data.Hashable
import Data.Maybe
import Data.List.Split

readMaybe :: Read a => String -> Maybe a
readMaybe s = case reads s of
                    [(val, "")] -> Just val
                    _           -> Nothing

splitter = "|"

data Type = Data | Ack | Fin deriving (Read, Eq)

  -- Is this even necessary? Ack isn't.
instance Show Type where
  show Data = "0"
  show Ack = "1"
  show Fin = "2"

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


data Server = Server {
  toPrint :: [Seg],
  buffer :: [Seg],
  lastSeqPrinted :: Int
}

parseType :: String -> Maybe Type
parseType "0" = Just Data
parseType "1" = Just Ack
parseType "2" = Just Fin
parseType _ = Nothing

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
          parsedSeq = readMaybe (splitUp!!1) :: Maybe Int

whatToPrint :: Server -> Server
whatToPrint s@(Server toprint buff lastseq) = newS printMe
    where printMe = find (\x -> (seqNum x) == (lastseq + 1)) buff
          newS Nothing = s
          newS (Just a) = Server (toprint ++ [a]) (delete a buff) (lastseq + 1)

addToBuffer :: Server -> Maybe Seg -> Server
addToBuffer s Nothing = s
addToBuffer s@(Server _ buff _) (Just seg@(Seg _ n _ _)) = if (any (\x -> (seqNum x) == n) buff)
                                                           then s
                                                           else s { buffer = (buff ++ [seg]) }

stepServer :: Server -> Maybe Seg -> Server
stepServer s mseg = whatToPrint $ addToBuffer s mseg

getAck :: Seg -> String
getAck (Seg _ num _ _) = show $ hashSeg $ Seg Ack num "" ""

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
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering
    r <- getStdRandom $ randomR (1024, 65535)
    let rS = show (r :: Int)
        server = Server [] [] 0
    timestamp $ "[bound] " ++ rS
    withSocketsDo $ bracket (connectMe rS) sClose (handler server)

handler :: Server -> Socket -> IO ()
handler server conn = do
    (msg,n,d) <- recvFrom conn 1024
    timestamp $ "[recv data] " ++ msg
    --when (msg == "#EOF") $ exitSuccess
    let mSeg = parseSeg (Just msg)
        nextServer = stepServer server mSeg
    -- putStrLn $ msg
    -- putStrLn $ show mSeg
    unless (isNothing mSeg) $ do
      let ack = getAck $ fromJust mSeg
      putStrLn $ show ack
      sendTo conn ack d
      return ()
    handler nextServer conn
    --unless (null msg) $ sendTo conn "ACK" d >> handler conn
