module Main where
import TCP
import Control.Monad (unless, when)
import System.Exit
import System.IO
import Network.Socket
import Control.Exception
import System.Random
import Data.Time.Clock
import Data.List
import Data.Maybe

data Server = Server {
  toPrint :: [Seg],
  buffer :: [Seg],
  lastSeqPrinted :: Int
}

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
