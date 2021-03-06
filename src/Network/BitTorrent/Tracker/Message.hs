-- |
--   Copyright   :  (c) Sam Truzjan 2013
--                  (c) Daniel Gröber 2013
--   License     :  BSD3
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  experimental
--   Portability :  portable
--
--   Every tracker should support announce query. This query is used
--   to discover peers within a swarm and have two-fold effect:
--
--     * peer doing announce discover other peers using peer list from
--     the response to the announce query.
--
--     * tracker store peer information and use it in the succeeding
--     requests made by other peers, until the peer info expires.
--
--   By convention most trackers support another form of request —
--   scrape query — which queries the state of a given torrent (or
--   a list of torrents) that the tracker is managing.
--
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# OPTIONS -fno-warn-orphans           #-}
module Network.BitTorrent.Tracker.Message
       ( -- * Announce
         -- ** Query
         AnnounceEvent (..)
       , AnnounceQuery (..)
       , renderAnnounceQuery
       , ParamParseFailure
       , parseAnnounceQuery

         -- ** Info
       , PeerList (..)
       , getPeerList
       , AnnounceInfo(..)
       , defaultNumWant
       , defaultMaxNumWant
       , defaultReannounceInterval

         -- * Scrape
         -- ** Query
       , ScrapeQuery
       , renderScrapeQuery
       , parseScrapeQuery

         -- ** Info
       , ScrapeEntry (..)
       , ScrapeInfo

         -- * HTTP specific
         -- ** Routes
       , PathPiece
       , defaultAnnouncePath
       , defaultScrapePath

         -- ** Preferences
       , AnnouncePrefs (..)
       , renderAnnouncePrefs
       , parseAnnouncePrefs

         -- ** Request
       , AnnounceRequest  (..)
       , parseAnnounceRequest
       , renderAnnounceRequest

         -- ** Response
       , announceType
       , scrapeType
       , parseFailureStatus

         -- ** Extra
       , queryToSimpleQuery

         -- * UDP specific
         -- ** Connection
       , ConnectionId
       , initialConnectionId

         -- ** Messages
       , Request (..)
       , Response (..)
       , responseName

         -- ** Transaction
       , genTransactionId
       , TransactionId
       , Transaction  (..)
       )
       where

import Control.Applicative
import Control.Monad
import Data.BEncode as BE hiding (Result)
import Data.BEncode.BDict as BE
import Data.ByteString as BS
import Data.ByteString.Char8 as BC
import Data.Char as Char
import Data.Convertible
import Data.Default
import Data.Either
import Data.List as L
import Data.Maybe
import Data.Serialize as S hiding (Result)
import Data.String
import Data.Text (Text)
import Data.Text.Encoding
import Data.Typeable
import Data.Word
import Data.IP
import Network.HTTP.Types.QueryLike
import Network.HTTP.Types.URI hiding (urlEncode)
import Network.HTTP.Types.Status
import Network.Socket hiding (Connected)
import Numeric
import System.Entropy
import Text.Read (readMaybe)

import Data.Torrent
import Network.BitTorrent.Address
import Network.BitTorrent.Internal.Progress

{-----------------------------------------------------------------------
--  Events
-----------------------------------------------------------------------}

-- | Events are used to specify which kind of announce query is performed.
data AnnounceEvent
    -- | For the first request: when download first begins.
  = Started

    -- | This peer stopped downloading /and/ uploading the torrent or
    -- just shutting down.
  | Stopped

    -- | This peer completed downloading the torrent. This only happen
    -- right after last piece have been verified. No 'Completed' is
    -- sent if the file was completed when 'Started'.
  | Completed
    deriving (Show, Read, Eq, Ord, Enum, Bounded, Typeable)

-- | HTTP tracker protocol compatible encoding.
instance QueryValueLike AnnounceEvent where
  toQueryValue e = toQueryValue (Char.toLower x : xs)
    where
      (x : xs) = show e -- INVARIANT: this is always nonempty list

type EventId = Word32

-- | UDP tracker encoding event codes.
eventId :: AnnounceEvent -> EventId
eventId Completed = 1
eventId Started   = 2
eventId Stopped   = 3

-- TODO add Regular event
putEvent :: Putter (Maybe AnnounceEvent)
putEvent Nothing  = putWord32be 0
putEvent (Just e) = putWord32be (eventId e)

getEvent :: S.Get (Maybe AnnounceEvent)
getEvent = do
  eid <- getWord32be
  case eid of
    0 -> return Nothing
    1 -> return $ Just Completed
    2 -> return $ Just Started
    3 -> return $ Just Stopped
    _ -> fail "unknown event id"

{-----------------------------------------------------------------------
  Announce query
-----------------------------------------------------------------------}
-- TODO add &ipv6= and &ipv4= params to AnnounceQuery
-- http://www.bittorrent.org/beps/bep_0007.html#announce-parameter

-- | A tracker request is HTTP GET request; used to include metrics
--   from clients that help the tracker keep overall statistics about
--   the torrent. The most important, requests are used by the tracker
--   to keep track lists of active peer for a particular torrent.
--
data AnnounceQuery = AnnounceQuery
   {
     -- | Hash of info part of the torrent usually obtained from
     -- 'Torrent' or 'Magnet'.
     reqInfoHash   :: !InfoHash

     -- | ID of the peer doing request.
   , reqPeerId     :: !PeerId

     -- | Port to listen to for connections from other
     -- peers. Tracker should respond with this port when
     -- some /other/ peer request the tracker with the same info hash.
     -- Normally, this port is choosed from 'defaultPorts'.
   , reqPort       :: !PortNumber

     -- | Current progress of peer doing request.
   , reqProgress   :: !Progress

     -- | The peer IP. Needed only when client communicated with
     -- tracker throught a proxy.
   , reqIP         :: Maybe HostAddress

     -- | Number of peers that the peers wants to receive from. It is
     -- optional for trackers to honor this limit. See note for
     -- 'defaultNumWant'.
   , reqNumWant    :: Maybe Int

     -- | If not specified, the request is regular periodic
     -- request. Regular request should be sent
   , reqEvent      :: Maybe AnnounceEvent
   } deriving (Show, Eq, Typeable)

-- | UDP tracker protocol compatible encoding.
instance Serialize AnnounceQuery where
  put AnnounceQuery {..} = do
    put           reqInfoHash
    put           reqPeerId
    put           reqProgress
    putEvent      reqEvent
    putWord32host $ fromMaybe 0 reqIP
    putWord32be   $ 0 -- TODO what the fuck is "key"?
    putWord32be   $ fromIntegral $ fromMaybe (-1) reqNumWant

    put           reqPort

  get = do
    ih   <- get
    pid  <- get

    progress <- get

    ev   <- getEvent
    ip   <- getWord32be
--    key  <- getWord32be -- TODO
    want <- getWord32be

    port <- get

    return $ AnnounceQuery {
        reqInfoHash   = ih
      , reqPeerId     = pid
      , reqPort       = port
      , reqProgress   = progress
      , reqIP         = if ip == 0 then Nothing else Just ip
      , reqNumWant    = if want == -1 then Nothing
                        else Just (fromIntegral want)
      , reqEvent      = ev
      }

instance QueryValueLike PortNumber where
  toQueryValue = toQueryValue . show . fromEnum

instance QueryValueLike Word32 where
  toQueryValue = toQueryValue . show

instance QueryValueLike Int where
  toQueryValue = toQueryValue . show

-- | HTTP tracker protocol compatible encoding.
instance QueryLike AnnounceQuery where
  toQuery AnnounceQuery {..} =
      toQuery reqProgress ++
      [ ("info_hash", toQueryValue reqInfoHash) -- TODO use 'paramName'
      , ("peer_id"  , toQueryValue reqPeerId)
      , ("port"     , toQueryValue reqPort)
      , ("ip"       , toQueryValue reqIP)
      , ("numwant"  , toQueryValue reqNumWant)
      , ("event"    , toQueryValue reqEvent)
      ]

-- | Filter @param=value@ pairs with the unset value.
queryToSimpleQuery :: Query -> SimpleQuery
queryToSimpleQuery = catMaybes . L.map f
  where
    f (_, Nothing) = Nothing
    f (a, Just b ) = Just (a, b)

-- | Encode announce query to query string.
renderAnnounceQuery :: AnnounceQuery -> SimpleQuery
renderAnnounceQuery = queryToSimpleQuery . toQuery

data QueryParam
    -- announce query
  = ParamInfoHash
  | ParamPeerId
  | ParamPort
  | ParamUploaded
  | ParamLeft
  | ParamDownloaded
  | ParamIP
  | ParamNumWant
  | ParamEvent
    -- announce query ext
  | ParamCompact
  | ParamNoPeerId
    deriving (Show, Eq, Ord, Enum)

paramName :: QueryParam -> BS.ByteString
paramName ParamInfoHash   = "info_hash"
paramName ParamPeerId     = "peer_id"
paramName ParamPort       = "port"
paramName ParamUploaded   = "uploaded"
paramName ParamLeft       = "left"
paramName ParamDownloaded = "downloaded"
paramName ParamIP         = "ip"
paramName ParamNumWant    = "numwant"
paramName ParamEvent      = "event"
paramName ParamCompact    = "compact"
paramName ParamNoPeerId   = "no_peer_id"
{-# INLINE paramName #-}

class FromParam a where
  fromParam :: BS.ByteString -> Maybe a

instance FromParam Bool where
  fromParam "0" = Just False
  fromParam "1" = Just True
  fromParam _   = Nothing

instance FromParam InfoHash where
  fromParam = either (const Nothing) pure . safeConvert

instance FromParam PeerId where
  fromParam = either (const Nothing) pure . safeConvert

instance FromParam Word32 where
  fromParam = readMaybe . BC.unpack

instance FromParam Word64 where
  fromParam = readMaybe . BC.unpack

instance FromParam Int where
  fromParam = readMaybe . BC.unpack

instance FromParam PortNumber where
  fromParam bs = fromIntegral <$> (fromParam bs :: Maybe Word32)

instance FromParam AnnounceEvent where
  fromParam bs = do
    (x, xs) <- BC.uncons bs
    readMaybe $ BC.unpack $ BC.cons (Char.toUpper x) xs

-- | 'ParamParseFailure' represent errors can occur while parsing HTTP
-- tracker requests. In case of failure, this can be used to provide
-- more informative 'statusCode' and 'statusMessage' in tracker
-- responses.
--
data ParamParseFailure
  = Missing QueryParam               -- ^ param not found in query string;
  | Invalid QueryParam BS.ByteString -- ^ param present but not valid.
    deriving (Show, Eq)

type ParseResult = Either ParamParseFailure

withError :: ParamParseFailure -> Maybe a -> ParseResult a
withError e = maybe (Left e) Right

reqParam :: FromParam a => QueryParam -> SimpleQuery -> ParseResult a
reqParam param xs = do
  val <- withError (Missing param) $ L.lookup (paramName param) xs
  withError (Invalid param val) (fromParam val)

optParam :: FromParam a => QueryParam -> SimpleQuery -> ParseResult (Maybe a)
optParam param ps
  | Just x <- L.lookup (paramName param) ps
  = pure <$> withError (Invalid param x) (fromParam x)
  | otherwise = pure Nothing

parseProgress :: SimpleQuery -> ParseResult Progress
parseProgress params = Progress
  <$> reqParam ParamDownloaded params
  <*> reqParam ParamLeft       params
  <*> reqParam ParamUploaded   params

-- | Parse announce request from a query string.
parseAnnounceQuery :: SimpleQuery -> ParseResult AnnounceQuery
parseAnnounceQuery params = AnnounceQuery
  <$> reqParam ParamInfoHash params
  <*> reqParam ParamPeerId   params
  <*> reqParam ParamPort     params
  <*> parseProgress params
  <*> optParam ParamIP       params
  <*> optParam ParamNumWant  params
  <*> optParam ParamEvent    params

{-----------------------------------------------------------------------
--  Announce Info
-----------------------------------------------------------------------}
-- TODO check if announceinterval/complete/incomplete is positive ints

-- | Tracker can return peer list in either compact(BEP23) or not
-- compact form.
--
--   For more info see: <http://www.bittorrent.org/beps/bep_0023.html>
--
data PeerList ip
  = PeerList        [PeerAddr IP]
  | CompactPeerList [PeerAddr ip]
    deriving (Show, Eq, Typeable, Functor)

-- | The empty non-compact peer list.
instance Default (PeerList IP) where
  def = PeerList []
  {-# INLINE def #-}

getPeerList :: PeerList IP -> [PeerAddr IP]
getPeerList (PeerList        xs) = xs
getPeerList (CompactPeerList xs) = xs

instance Serialize a => BEncode (PeerList a) where
  toBEncode (PeerList        xs) = toBEncode xs
  toBEncode (CompactPeerList xs) = toBEncode $ runPut (mapM_ put xs)

  fromBEncode (BList    l ) = PeerList        <$> fromBEncode (BList l)
  fromBEncode (BString  s ) = CompactPeerList <$> runGet (many get) s
  fromBEncode  _ = decodingError "PeerList: should be a BString or BList"

-- | The tracker response includes a peer list that helps the client
--   participate in the torrent. The most important is 'respPeer' list
--   used to join the swarm.
--
data AnnounceInfo =
     Failure !Text -- ^ Failure reason in human readable form.
   | AnnounceInfo {
       -- | Number of peers completed the torrent. (seeders)
       respComplete    :: !(Maybe Int)

       -- | Number of peers downloading the torrent. (leechers)
     , respIncomplete  :: !(Maybe Int)

       -- | Recommended interval to wait between requests, in seconds.
     , respInterval    :: !Int

       -- | Minimal amount of time between requests, in seconds. A
       -- peer /should/ make timeout with at least 'respMinInterval'
       -- value, otherwise tracker might not respond. If not specified
       -- the same applies to 'respInterval'.
     , respMinInterval :: !(Maybe Int)

       -- | Peers that must be contacted.
     , respPeers       :: !(PeerList IP)

       -- | Human readable warning.
     , respWarning     :: !(Maybe Text)
     } deriving (Show, Eq, Typeable)

-- | Empty peer list with default reannounce interval.
instance Default AnnounceInfo where
  def = AnnounceInfo
    { respComplete    = Nothing
    , respIncomplete  = Nothing
    , respInterval    = defaultReannounceInterval
    , respMinInterval = Nothing
    , respPeers       = def
    , respWarning     = Nothing
    }

-- | HTTP tracker protocol compatible encoding.
instance BEncode AnnounceInfo where
  toBEncode (Failure t)        = toDict $
       "failure reason" .=! t
    .: endDict

  toBEncode  AnnounceInfo {..} = toDict $
       "complete"        .=? respComplete
    .: "incomplete"      .=? respIncomplete
    .: "interval"        .=! respInterval
    .: "min interval"    .=? respMinInterval
    .: "peers"           .=! peers
    .: "peers6"          .=? peers6
    .: "warning message" .=? respWarning
    .: endDict
    where
      (peers, peers6) = prttn respPeers

      prttn :: PeerList IP -> (PeerList IPv4, Maybe (PeerList IPv6))
      prttn (PeerList        xs) = (PeerList xs, Nothing)
      prttn (CompactPeerList xs) = mk $ partitionEithers $ toEither <$> xs
        where
          mk (v4s, v6s)
            | L.null v6s = (CompactPeerList v4s, Nothing)
            | otherwise  = (CompactPeerList v4s, Just (CompactPeerList v6s))

          toEither :: PeerAddr IP -> Either (PeerAddr IPv4) (PeerAddr IPv6)
          toEither PeerAddr {..} = case peerHost of
            IPv4 ipv4 -> Left  $ PeerAddr peerId ipv4 peerPort
            IPv6 ipv6 -> Right $ PeerAddr peerId ipv6 peerPort

  fromBEncode (BDict d)
    | Just t <- BE.lookup "failure reason" d = Failure <$> fromBEncode t
    | otherwise = (`fromDict` (BDict d)) $
       AnnounceInfo
        <$>? "complete"
        <*>? "incomplete"
        <*>! "interval"
        <*>? "min interval"
        <*>  (uncurry merge =<< (,) <$>! "peers" <*>? "peers6")
        <*>? "warning message"
    where
      merge :: PeerList IPv4 -> Maybe (PeerList IPv6) -> BE.Get (PeerList IP)
      merge (PeerList ips)          Nothing  = pure (PeerList ips)
      merge (PeerList _  )          (Just _)
        = fail "PeerList: non-compact peer list provided, \
                         \but the `peers6' field present"

      merge (CompactPeerList ipv4s) Nothing
        = pure $ CompactPeerList (fmap IPv4 <$> ipv4s)

      merge (CompactPeerList _    ) (Just (PeerList _))
        = fail "PeerList: the `peers6' field value \
                         \should contain *compact* peer list"

      merge (CompactPeerList ipv4s) (Just (CompactPeerList ipv6s))
        = pure $ CompactPeerList $
                 (fmap IPv4 <$> ipv4s) <> (fmap IPv6 <$> ipv6s)

  fromBEncode _ = decodingError "Announce info"

-- | UDP tracker protocol compatible encoding.
instance Serialize AnnounceInfo where
  put (Failure msg) = put $ encodeUtf8 msg
  put  AnnounceInfo {..} = do
    putWord32be $ fromIntegral respInterval
    putWord32be $ fromIntegral $ fromMaybe 0 respIncomplete
    putWord32be $ fromIntegral $ fromMaybe 0 respComplete
    forM_ (fmap ipv4 <$> getPeerList respPeers) put

  get = do
    interval <- getWord32be
    leechers <- getWord32be
    seeders  <- getWord32be
    peers    <- many $ fmap IPv4 <$> get

    return $ AnnounceInfo {
        respWarning     = Nothing
      , respInterval    = fromIntegral interval
      , respMinInterval = Nothing
      , respIncomplete  = Just $ fromIntegral leechers
      , respComplete    = Just $ fromIntegral seeders
      , respPeers       = PeerList peers
      }

-- | Decodes announce response from bencoded string, for debugging only.
instance IsString AnnounceInfo where
  fromString str = either (error . format) id $ BE.decode (fromString str)
    where
      format msg = "fromString: unable to decode AnnounceInfo: " ++ msg

-- | Above 25, new peers are highly unlikely to increase download
--   speed.  Even 30 peers is /plenty/, the official client version 3
--   in fact only actively forms new connections if it has less than
--   30 peers and will refuse connections if it has 55.
--
--   <https://wiki.theory.org/BitTorrent_Tracker_Protocol#Basic_Tracker_Announce_Request>
--
defaultNumWant :: Int
defaultNumWant = 50

-- | Reasonable upper bound of numwant parameter.
defaultMaxNumWant :: Int
defaultMaxNumWant = 200

-- | Widely used reannounce interval. Note: tracker clients should not
-- use this value!
defaultReannounceInterval :: Int
defaultReannounceInterval = 30 * 60

{-----------------------------------------------------------------------
  Scrape message
-----------------------------------------------------------------------}

-- | Scrape query used to specify a set of torrent to scrape.
-- If list is empty then tracker should return scrape info about each
-- torrent.
type ScrapeQuery = [InfoHash]

-- TODO
-- data ScrapeQuery
--  = ScrapeAll
--  | ScrapeSingle InfoHash
--  | ScrapeMulti (HashSet InfoHash)
--    deriving (Show)
--
--  data ScrapeInfo
--    = ScrapeAll   (HashMap InfoHash ScrapeEntry)
--    | ScrapeSingle InfoHash ScrapeEntry
--    | ScrapeMulti (HashMap InfoHash ScrapeEntry)
--

scrapeParam :: BS.ByteString
scrapeParam = "info_hash"

isScrapeParam :: BS.ByteString -> Bool
isScrapeParam = (==) scrapeParam

-- | Parse scrape query to query string.
parseScrapeQuery :: SimpleQuery -> ScrapeQuery
parseScrapeQuery
  = catMaybes . L.map (fromParam . snd) . L.filter (isScrapeParam . fst)

-- | Render scrape query to query string.
renderScrapeQuery :: ScrapeQuery -> SimpleQuery
renderScrapeQuery = queryToSimpleQuery . L.map mkPair
  where
    mkPair ih = (scrapeParam, toQueryValue ih)

-- | Overall information about particular torrent.
data ScrapeEntry = ScrapeEntry {
    -- | Number of seeders - peers with the entire file.
    siComplete   :: {-# UNPACK #-} !Int

    -- | Total number of times the tracker has registered a completion.
  , siDownloaded :: {-# UNPACK #-} !Int

    -- | Number of leechers.
  , siIncomplete :: {-# UNPACK #-} !Int

    -- | Name of the torrent file, as specified by the "name"
    --   file in the info section of the .torrent file.
  , siName       :: !(Maybe Text)
  } deriving (Show, Eq, Typeable)

-- | HTTP tracker protocol compatible encoding.
instance BEncode ScrapeEntry where
  toBEncode ScrapeEntry {..} = toDict $
       "complete"   .=! siComplete
    .: "downloaded" .=! siDownloaded
    .: "incomplete" .=! siIncomplete
    .: "name"       .=? siName
    .: endDict

  fromBEncode = fromDict $ ScrapeEntry
    <$>! "complete"
    <*>! "downloaded"
    <*>! "incomplete"
    <*>? "name"

-- | UDP tracker protocol compatible encoding.
instance Serialize ScrapeEntry where
  put ScrapeEntry {..} = do
    putWord32be $ fromIntegral siComplete
    putWord32be $ fromIntegral siDownloaded
    putWord32be $ fromIntegral siIncomplete

  get = ScrapeEntry
    <$> (fromIntegral <$> getWord32be)
    <*> (fromIntegral <$> getWord32be)
    <*> (fromIntegral <$> getWord32be)
    <*> pure Nothing

-- | Scrape info about a set of torrents.
type ScrapeInfo = [(InfoHash, ScrapeEntry)]

{-----------------------------------------------------------------------
--  HTTP specific
-----------------------------------------------------------------------}

-- | Some HTTP trackers allow to choose prefered representation of the
-- 'AnnounceInfo'. It's optional for trackers to honor any of this
-- options.
data AnnouncePrefs = AnnouncePrefs
  { -- | If specified, "compact" parameter is used to advise the
    --   tracker to send peer id list as:
    --
    --   * bencoded list                 (extCompact = Just False);
    --   * or more compact binary string (extCompact = Just True).
    --
    --   The later is prefered since compact peer list will reduce the
    --   size of tracker responses. Hovewer, if tracker do not support
    --   this extension then it can return peer list in either form.
    --
    --   For more info see: <http://www.bittorrent.org/beps/bep_0023.html>
    --
    extCompact  :: !(Maybe Bool)

    -- | If specified, "no_peer_id" parameter is used advise tracker
    --   to either send or not to send peer id in tracker response.
    --   Tracker may not support this extension as well.
    --
    --   For more info see:
    --  <http://permalink.gmane.org/gmane.network.bit-torrent.general/4030>
    --
  , extNoPeerId :: !(Maybe Bool)
  } deriving (Show, Eq, Typeable)

instance Default AnnouncePrefs where
  def = AnnouncePrefs Nothing Nothing

instance QueryLike AnnouncePrefs where
  toQuery AnnouncePrefs {..} =
      [ ("compact",    toQueryFlag <$> extCompact) -- TODO use 'paramName'
      , ("no_peer_id", toQueryFlag <$> extNoPeerId)
      ]
    where
      toQueryFlag False = "0"
      toQueryFlag True  = "1"

-- | Parse announce query extended part from query string.
parseAnnouncePrefs :: SimpleQuery -> AnnouncePrefs
parseAnnouncePrefs params = either (const def) id $
  AnnouncePrefs
    <$> optParam ParamCompact  params
    <*> optParam ParamNoPeerId params

-- | Render announce preferences to query string.
renderAnnouncePrefs :: AnnouncePrefs -> SimpleQuery
renderAnnouncePrefs = queryToSimpleQuery . toQuery

-- | HTTP tracker request with preferences.
data AnnounceRequest = AnnounceRequest
  { announceQuery :: AnnounceQuery -- ^ Request query params.
  , announcePrefs :: AnnouncePrefs -- ^ Optional advises to the tracker.
  } deriving (Show, Eq, Typeable)

instance QueryLike AnnounceRequest where
  toQuery AnnounceRequest{..} =
    toQuery announcePrefs <>
    toQuery announceQuery

-- | Parse announce request from query string.
parseAnnounceRequest :: SimpleQuery -> ParseResult AnnounceRequest
parseAnnounceRequest params = AnnounceRequest
  <$> parseAnnounceQuery params
  <*> pure (parseAnnouncePrefs params)

-- | Render announce request to query string.
renderAnnounceRequest :: AnnounceRequest -> SimpleQuery
renderAnnounceRequest = queryToSimpleQuery . toQuery

type PathPiece = BS.ByteString

defaultAnnouncePath :: PathPiece
defaultAnnouncePath = "announce"

defaultScrapePath :: PathPiece
defaultScrapePath = "scrape"

missingOffset :: Int
missingOffset = 101

invalidOffset :: Int
invalidOffset = 150

parseFailureCode :: ParamParseFailure -> Int
parseFailureCode (Missing param  ) = missingOffset + fromEnum param
parseFailureCode (Invalid param _) = invalidOffset + fromEnum param

parseFailureMessage :: ParamParseFailure -> BS.ByteString
parseFailureMessage e = BS.concat $ case e of
  Missing p   -> ["Missing parameter: ", paramName p]
  Invalid p v -> ["Invalid parameter: ", paramName p, " = ", v]

-- | HTTP response /content type/ for announce info.
announceType :: ByteString
announceType = "text/plain"

-- | HTTP response /content type/ for scrape info.
scrapeType :: ByteString
scrapeType = "text/plain"

-- | Get HTTP response status from a announce params parse failure.
--
--   For more info see:
--   <https://wiki.theory.org/BitTorrent_Tracker_Protocol#Response_Codes>
--
parseFailureStatus :: ParamParseFailure -> Status
parseFailureStatus = mkStatus <$> parseFailureCode <*> parseFailureMessage

{-----------------------------------------------------------------------
--  UDP specific message types
-----------------------------------------------------------------------}

genToken :: IO Word64
genToken = do
    bs <- getEntropy 8
    either err return $ runGet getWord64be bs
  where
    err = error "genToken: impossible happen"

-- | Connection Id is used for entire tracker session.
newtype ConnectionId  = ConnectionId Word64
  deriving (Eq, Serialize)

instance Show ConnectionId where
  showsPrec _ (ConnectionId cid) = showString "0x" <> showHex cid

initialConnectionId :: ConnectionId
initialConnectionId =  ConnectionId 0x41727101980

-- | Transaction Id is used within a UDP RPC.
newtype TransactionId = TransactionId Word32
  deriving (Eq, Ord, Enum, Bounded, Serialize)

instance Show TransactionId where
  showsPrec _ (TransactionId tid) = showString "0x" <> showHex tid

genTransactionId :: IO TransactionId
genTransactionId = (TransactionId . fromIntegral) <$> genToken

data Request
  = Connect
  | Announce  AnnounceQuery
  | Scrape    ScrapeQuery
    deriving Show

data Response
  = Connected ConnectionId
  | Announced AnnounceInfo
  | Scraped   [ScrapeEntry]
  | Failed    Text
    deriving Show

responseName :: Response -> String
responseName (Connected _) = "connected"
responseName (Announced _) = "announced"
responseName (Scraped   _) = "scraped"
responseName (Failed    _) = "failed"

data family Transaction a
data instance Transaction Request  = TransactionQ
    { connIdQ  :: {-# UNPACK #-} !ConnectionId
    , transIdQ :: {-# UNPACK #-} !TransactionId
    , request  :: !Request
    } deriving Show
data instance Transaction Response = TransactionR
    { transIdR :: {-# UNPACK #-} !TransactionId
    , response :: !Response
    } deriving Show

-- TODO newtype
newtype MessageId = MessageId Word32
                    deriving (Show, Eq, Num, Serialize)

connectId, announceId, scrapeId, errorId :: MessageId
connectId  = 0
announceId = 1
scrapeId   = 2
errorId    = 3

instance Serialize (Transaction Request) where
  put TransactionQ {..} = do
    case request of
      Connect        -> do
        put initialConnectionId
        put connectId
        put transIdQ

      Announce ann -> do
        put connIdQ
        put announceId
        put transIdQ
        put ann

      Scrape   hashes -> do
        put connIdQ
        put scrapeId
        put transIdQ
        forM_ hashes put

  get = do
      cid <- get
      mid <- get
      TransactionQ cid <$> S.get <*> getBody mid
    where
      getBody :: MessageId -> S.Get Request
      getBody msgId
        | msgId == connectId  = pure Connect
        | msgId == announceId = Announce <$> get
        | msgId == scrapeId   = Scrape   <$> many get
        |       otherwise     = fail errMsg
        where
          errMsg = "unknown request: " ++ show msgId

instance Serialize (Transaction Response) where
  put TransactionR {..} = do
    case response of
      Connected conn -> do
        put connectId
        put transIdR
        put conn

      Announced info -> do
        put announceId
        put transIdR
        put info

      Scraped infos -> do
        put scrapeId
        put transIdR
        forM_ infos put

      Failed info -> do
        put errorId
        put transIdR
        put (encodeUtf8 info)


  get = do
      mid <- get
      TransactionR <$> get <*> getBody mid
    where
      getBody :: MessageId -> S.Get Response
      getBody msgId
        | msgId == connectId  = Connected <$> get
        | msgId == announceId = Announced <$> get
        | msgId == scrapeId   = Scraped   <$> many get
        | msgId == errorId    = (Failed . decodeUtf8) <$> get
        |       otherwise     = fail msg
        where
          msg = "unknown response: " ++ show msgId
