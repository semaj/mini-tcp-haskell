module Main where
import TCP
import Control.Monad (unless, when, forever, void)
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

isDup :: Server -> Seg -> Bool
isDup server seg = (seqNum seg) < (lastSeqPrinted server) || any ((== (seqNum seg)) . seqNum) (buffer server)

lastSeqNum :: Server -> Int
lastSeqNum (Server _ [] [] i _) = i
lastSeqNum (Server _ toP [] _ _) = last $ sort $ map seqNum toP
lastSeqNum (Server _ _ buff _ _) = last $ sort $ map seqNum buff

outOfOrder :: Server -> Seg -> String
outOfOrder server seg = if ((seqNum seg) - 1) == lsn then "(in-order)" else "(out-of-order)"
    where lsn = lastSeqNum server

whatToPrint :: Server -> Server
whatToPrint s@(Server ss toprint buff lastseq sa) = newS printMe
    where printMe = find (\ x -> (seqNum x) == (lastseq + 1)) buff
          newS Nothing = s
          newS (Just a) = whatToPrint $ Server ss (toprint ++ [a]) (delete a buff) (lastseq + 1) sa

addToBuffer :: Server -> Maybe Seg -> Server
addToBuffer s Nothing = s
addToBuffer s (Just seg) = if isDup s seg
                           then s
                           else s { buffer = ((buffer s) ++ [seg]) }

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

receiveFromClient :: Socket -> Chan (String, SockAddr) -> IO ()
receiveFromClient s segs = do
  forever $ do
    (msg,_,d) <- recvFrom s 32768
    writeChan segs (msg, d)

main :: IO ()
main =
  do
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering
    r <- getStdRandom $ randomR (1024, 65535)
    let rS = show (r :: Int)
    timestamp $ "[bound] " ++ rS
    -- the "bracket" pattern (bracket a b c) basically
    -- runs a first, c in between, finally b (in this case with a socket)
    withSocketsDo $ bracket (connectMe rS) sClose initialize

initialize :: Socket -> IO ()
initialize conn = do
  receiving <- newChan
  -- fork off our socket-reading code
  rec <- forkIO $ receiveFromClient conn receiving
  let server = Server SEstablished [] [] 0 (SockAddrUnix "unimportantplaceholder")
  handler server receiving conn
  killThread rec


sendAck :: Socket -> SockAddr -> Maybe Seg -> IO ()
sendAck _ _ Nothing = return ()
sendAck conn sa (Just seg) = void $ sendTo conn (getAck seg) sa

printRecv :: Maybe Seg -> Server -> IO ()
printRecv Nothing _ = timestamp "[recv corrupt packet]"
printRecv (Just seg@(Seg Data num dat _)) server =
  do
    let (off,len) = offsetLengthSeg seg
        pref = "[recv data] " ++ off ++ " (" ++ len ++ ") "
    if (isDup server seg)
    then timestamp $ pref ++ "IGNORED"
    else timestamp $ pref ++ "ACCEPTED " ++ (outOfOrder server seg)
printRecv _ _ = return ()


handler :: Server -> Chan (String, SockAddr) -> Socket -> IO ()
handler server fromClient conn =
  do
    msg <- tryGet fromClient
    let (fromC, sockAddr) = maybe (Nothing,(sockaddr server))
                                  (\ (x,y) -> (Just x,y))
                                  msg
        mSeg = parseSeg fromC
        -- we update server's state, which may depend on the seg rec'd from client
        nextServer = stepServer server mSeg
    when (isJust fromC) $ printRecv mSeg server
    if (sstate nextServer) == SClose
    then do -- let's finish up
      mapM putStr $ map dat $ toPrint nextServer
      let ack = show $ hashSeg $ Seg Fin (-1) "" ""
      sendTo conn ack sockAddr
      sendTo conn ack sockAddr
      sendTo conn ack sockAddr
      sendTo conn ack sockAddr
      close conn
      timestamp $ "[completed]"
    else do -- ack the data packet we received
      mapM putStr $ map dat $ toPrint nextServer
      let emptiedToPrint = nextServer { toPrint = [], sockaddr = sockAddr }
      sendAck conn sockAddr mSeg
      handler emptiedToPrint fromClient conn
