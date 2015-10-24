module Main where
import TCP
import Control.Monad (unless, when, forever)
import System.Exit
import System.IO
import Network.Socket
import Control.Exception
import System.Random
import Data.Time.Clock
import Data.List
import Control.Concurrent
import Data.Maybe
import System.Exit
import Data.List.Split

data SState = SEstablished | SClose deriving (Eq)

data Server = Server {
  sstate :: SState,
  toPrint :: [Seg],
  buffer :: [Seg],
  lastSeqPrinted :: Int,
  sockaddr :: SockAddr
}

whatToPrint :: Server -> Server
whatToPrint s@(Server ss toprint buff lastseq sa) = newS printMe
    where printMe = find (\x -> (seqNum x) == (lastseq + 1)) buff
          newS Nothing = s
          newS (Just a) = whatToPrint $ Server ss (toprint ++ [a]) (delete a buff) (lastseq + 1) sa

addToBuffer :: Server -> Maybe Seg -> Server
addToBuffer s Nothing = s
addToBuffer s@(Server _ _ buff _ _) (Just seg@(Seg _ n _ _)) = if (any (\x -> (seqNum x) == n) buff)
                                                             then s
                                                             else s { buffer = (buff ++ [seg]) }

stepServer :: Server -> Maybe Seg -> Server
stepServer s (Just (Seg Fin _ _ _)) = s { sstate = SClose }
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

receiveFromClient :: Socket -> Chan (String, SockAddr) -> IO ()
receiveFromClient s segs = do
  forever $ do
    (msg,_,d) <- recvFrom s 32768
    --timestamp $ "[recv data] " ++ msg
    writeChan segs (msg, d)


main :: IO ()
main =
  do
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering
    r <- getStdRandom $ randomR (1024, 65535)
    let rS = show (r :: Int)
    timestamp $ "[bound] " ++ rS
    withSocketsDo $ bracket (connectMe rS) sClose initialize

initialize :: Socket -> IO ()
initialize conn = do
  receiving <- newChan
  forkIO $ receiveFromClient conn receiving
  let server = Server SEstablished [] [] 0 (SockAddrUnix "unimportantplaceholder")
  handler server receiving conn

sendAck :: Socket -> SockAddr -> Maybe Seg -> IO ()
sendAck _ _ Nothing = return ()
sendAck conn sa (Just seg) =
  do
    sendTo conn (getAck seg) sa
    return ()

handler :: Server -> Chan (String, SockAddr) -> Socket -> IO ()
handler server fromClient conn =
  do
    msg <- tryGet fromClient

    -- gross
    let (fromC,sa) = if (isNothing msg) then (Nothing,(sockaddr server)) else (Just (fst $ fromJust msg),(snd $ fromJust msg))
    let mSegs = map parseSeg $ splitSegs fromC
        nextServer = foldl stepServer server mSegs

    when ((sstate nextServer) == SClose) $ do
      mapM putStr $ map dat $ toPrint nextServer
      let ack = show $ hashSeg $ Seg Fin (-1) "" ""
      sendTo conn ack sa
      sendTo conn ack sa
      sendTo conn ack sa
      sendTo conn ack sa
      sendTo conn ack sa
      close conn
      exitSuccess

    mapM putStr $ map dat $ toPrint nextServer
    let emptiedToPrint = nextServer { toPrint = [], sockaddr = sa }
    mapM (sendAck conn sa) mSegs
    handler emptiedToPrint fromClient conn
    --unless (null msg) $ sendTo conn "ACK" d >> handler conn
