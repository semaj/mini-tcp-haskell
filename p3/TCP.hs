module TCP where
import Data.Hashable
import Control.Concurrent
import Data.Time
import Data.Maybe
import Data.List.Split
import Data.List

---- Constants

splitter = "|"
packetSplitter = "*"
-- mss = 500
segmentExpiryTime :: Float
segmentExpiryTime = 0.5 -- sec

---- Data

data Type = Data | Ack | Fin deriving (Read, Eq)

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

---- Helpers

group2 :: [String] -> [String]
group2 [] = []
group2 l@(x:[]) = l
group2 (x:y:rest) = ((x ++ packetSplitter ++ y):(group2 rest))

combine :: Int -> [String] -> [String]
combine i s = map (intercalate packetSplitter) $ chunksOf i s

---- Parsing functions

parseType :: String -> Maybe Type
parseType "0" = Just Data
parseType "1" = Just Ack
parseType "2" = Just Fin
parseType _ = Nothing

---- Segment Functions

splitSegs :: Maybe String -> [Maybe String]
splitSegs Nothing = []
splitSegs (Just s) = map Just $ splitOn packetSplitter s

hashSeg :: Seg -> Seg
hashSeg s@(Seg a b c _) = s { shash = take 5 $ show $ hash $ (show a) ++ (show b) ++ (show c) }

checkCorruption :: Maybe Seg -> Maybe Seg
checkCorruption Nothing = Nothing -- smells like a Monad goes here!
checkCorruption (Just s@(Seg _ _ _ oldhash)) = if oldhash == (shash (hashSeg s)) then Just s else Nothing

parseSeg :: Maybe String -> Maybe Seg
parseSeg Nothing = Nothing
parseSeg (Just seg)
  | (length splitUp) /= 4 = Nothing
  | (isNothing parsedType) || (isNothing parsedSeq) = Nothing
  | otherwise = checkCorruption $ Just $ Seg (fromJust parsedType)
                                             (fromJust parsedSeq)
                                             (splitUp!!2)
                                             (splitUp!!3)
    where splitUp = splitOn splitter seg
          parsedType = parseType (splitUp!!0)
          parsedSeq = readMaybe (splitUp!!1)



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
