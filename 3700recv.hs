module Main where
import TCP
import Control.Monad (unless, when, forever, void, replicateM_)
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
  sstate :: SState,      -- server state
  toPrint :: [Seg],      -- what to print on next IO cycle
  buffer :: [Seg],       -- stored segments (can't print because they're out of order)
  lastSeqPrinted :: Int, -- last sequence number printed
  sockaddr :: SockAddr   
}

-- it's a duplicate if it's smaller than the last thing we printed (already printed)
-- or if we have it in the buffer
isDup :: Server -> Seg -> Bool
isDup server seg = (seqNum seg) < (lastSeqPrinted server) || any ((== (seqNum seg)) . seqNum) (buffer server)

-- used for debug printing.
-- the lastSeq num is either the last received, last to print, or last printed
lastSeqNum :: Server -> Int
lastSeqNum (Server _ [] [] i _) = i
lastSeqNum (Server _ toP [] _ _) = last $ sort $ map seqNum toP
lastSeqNum (Server _ _ buff _ _) = last $ sort $ map seqNum buff

outOfOrder :: Server -> Seg -> String
outOfOrder server seg = if ((seqNum seg) - 1) == lsn then "(in-order)" else "(out-of-order)"
    where lsn = lastSeqNum server

-- pull consective (by seq num) segs out of buffer, into toPrint
whatToPrint :: Server -> Server
whatToPrint s@(Server ss toprint buff lastseq sa) = newS printMe
    where printMe = find ((== (lastseq + 1)) . seqNum) buff
          newS Nothing = s
          -- this is pretty gross, there's a fold here somewhere
          newS (Just a) = whatToPrint $ Server ss (toprint ++ [a]) (delete a buff) (lastseq + 1) sa

-- if it's a dup, don't add it
addToBuffer :: Server -> Maybe Seg -> Server
addToBuffer s Nothing = s
addToBuffer s (Just seg) = if isDup s seg
                           then s
                           else s { buffer = ((buffer s) ++ [seg]) }

stepServer :: Server -> Maybe Seg -> Server
-- if we receive a fin, let's finish up
stepServer s (Just (Seg Fin _ _ _)) = s { sstate = SClose }
-- else let's add to the buffer and add things to be printed
stepServer s mseg = whatToPrint $ addToBuffer s mseg

-- add our nacks to the Ack data
getAck :: Seg -> [String] -> String
getAck (Seg _ num _ _) nacks = show $ hashSeg $ Seg Ack num (intercalate nackSplitter nacks) ""

receiveFromClient :: Socket -> Chan (String, SockAddr) -> IO ()
receiveFromClient s segs = do
  forever $ do
    (msg,_,d) <- recvFrom s 32768
    writeChan segs (msg, d)

sendAck :: Socket -> SockAddr -> Maybe Seg -> [String] -> IO ()
sendAck _ _ Nothing _ = return ()
sendAck conn sa (Just seg) nacks = void $ sendTo conn (getAck seg nacks) sa

printRecv :: Maybe Seg -> Server -> IO ()
printRecv Nothing _ = timestamp "[recv corrupt packet]"
printRecv (Just seg@(Seg Data num dat _)) server =
  do
    let (off,len) = offsetLengthSeg seg
        pref = "[recv data] " ++ off ++ " (" ++ len ++ ") " ++ (show num)
    if (isDup server seg)
    then timestamp $ pref ++ "IGNORED"
    else timestamp $ pref ++ "ACCEPTED " ++ (outOfOrder server seg)
printRecv _ _ = return () -- don't print Fins

diff :: Server -> Maybe Seg -> [String]
diff _ Nothing = []
-- in the range from what we've printed to what we've received, what are we missing?
-- (what should we nack?)
diff s (Just seg) = map show $ [((lastSeqPrinted s) + 1)..((seqNum seg) - 1)] \\ (map seqNum (buffer s))

handler :: Server -> Chan (String, SockAddr) -> Socket -> IO ()
handler server fromClient conn =
  do
    msg <- tryGet fromClient
    let (fromC, sockAddr) = maybe (Nothing,(sockaddr server))
                                  (\ (x,y) -> (Just x,y))
                                  msg
        mSeg = parseSeg fromC -- returns Nothing is corrupt
        -- we update server's state, which may depend on the seg rec'd from client
        nextServer = stepServer server mSeg
    -- when we popped fromClient chan, fork print debug info (parsed seg)
    when (isJust fromC) $ void $ forkIO $ void $ printRecv mSeg server
    if (sstate nextServer) == SClose
    then do -- let's finish up
      mapM putStr $ map dat $ toPrint nextServer
      let finAck = show $ hashSeg $ Seg Fin (-1) "" ""
      -- send 4 fin acks
      replicateM_ 4 $ sendTo conn finAck sockAddr
      close conn
      timestamp $ "[completed]"
    else do -- ack the data packet we received
      -- print everything
      mapM putStr $ map dat $ toPrint nextServer
      let emptiedToPrint = nextServer { toPrint = [], sockaddr = sockAddr }
      -- sends ack to the server
      forkIO $ sendAck conn sockAddr mSeg $ diff nextServer mSeg 
      handler emptiedToPrint fromClient conn

initialize :: Socket -> IO ()
initialize conn =
  do
    receiving <- newChan
    -- fork off our socket-reading code
    rec <- forkIO $ receiveFromClient conn receiving
    let server = Server SEstablished [] [] 0 (SockAddrUnix "unimportantplaceholder")
    handler server receiving conn
    -- kill our socket-reading code once we're done
    killThread rec

connectMe :: String -> IO Socket
connectMe port =
  do
    (serveraddr:_) <- getAddrInfo
                      (Just (defaultHints {addrFlags = [AI_PASSIVE]}))
                      Nothing (Just port)
                      -- Datagram for UDP, Stream for TCP
    sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
    bindSocket sock (addrAddress serveraddr)
    return sock

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

